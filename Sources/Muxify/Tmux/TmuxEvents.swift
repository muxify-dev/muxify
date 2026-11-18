import Foundation
import Darwin
import MuxifyCore

/// Hears about tmux changes as they happen through a control-mode client
/// (`tmux -C`), so the sidebar doesn't wait for the next poll when a Window is
/// switched, added, closed or renamed. The client only listens: it gets no
/// pane output and doesn't count towards window sizes. It is not read-only:
/// tmux gives a command from outside tmux the client with the newest
/// activity, which is often this one, and a read-only client refuses commands
/// such as `send-keys` for everybody.
final class TmuxEvents {
    enum Event {
        /// A Session's current Window changed (select-window, prefix+n, …).
        case sessionWindowChanged(sessionID: String, windowID: String)
        /// Anything else that may change what the sidebar shows.
        case other
    }

    /// Called on the main thread.
    var onEvent: ((Event) -> Void)?

    private var client: ControlClient?
    /// Tells the current client's callbacks from those of one already replaced.
    private var clientToken = UUID()
    private var nextStart = Date.distantPast

    /// Read on the main thread.
    var isRunning: Bool { client?.isRunning == true }

    /// Attaches to the Watch Session, and makes it first when it is not there.
    /// Notifications cover every Session, so the client hears the user's
    /// Sessions from there, and their Panes never share a Session with it.
    /// The Session runs `cat`, not a shell, so no shell startup file runs in it.
    /// Call on the main thread.
    func start(invocation: ([String]) throws -> CommandInvocation) {
        guard !isRunning, Date() >= nextStart,
              let invocation = try? invocation(Tmux.watchClientArguments)
        else { return }
        stop()
        let token = UUID()
        clientToken = token
        do {
            client = try ControlClient(binary: invocation.executable, arguments: invocation.arguments, onLines: { [weak self] lines in
                let events = lines.compactMap(Self.event(from:))
                guard !events.isEmpty else { return }
                DispatchQueue.main.async {
                    guard let self, self.clientToken == token else { return }
                    events.forEach { self.onEvent?($0) }
                }
            }, onExit: { [weak self] in
                // A client that ends on its own (server gone, SSH dropped) waits before the next start.
                guard let self, self.clientToken == token else { return }
                self.client = nil
                self.nextStart = Date().addingTimeInterval(2)
            })
        } catch {
            Diagnostics.report("tmux control client failed to start: \(error)")
        }
    }

    func stop() {
        clientToken = UUID()
        client?.stop()
        client = nil
    }

    deinit { client?.stop() }

    private static func event(from line: String) -> Event? {
        let words = line.split(separator: " ")
        guard let kind = words.first, kind.hasPrefix("%") else { return nil }
        switch kind {
        case "%begin", "%end", "%error", "%output", "%extended-output", "%exit":
            return nil
        case "%session-window-changed" where words.count >= 3:
            return .sessionWindowChanged(sessionID: String(words[1]), windowID: String(words[2]))
        default:
            return .other
        }
    }
}

/// A `tmux -C` client whose controlling terminal is a pty that only Muxify
/// holds. A control client can outlive a dead parent that only closed its
/// input; the pty hangup when Muxify ends, however it ends, stops it.
final class ControlClient: TmuxControlClient {
    private let pid: pid_t
    private let master: Int32
    private let reader: DispatchSourceRead
    private let exitSource: DispatchSourceProcess
    private let state = State()

    /// Whether the client was reaped, and whether its pty master was closed.
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        // `lock` guards these.
        var exited = false
        var closed = false
    }

    /// Starts a client for the Local Environment's publisher.
    static let start: TmuxControlClientStart = { invocation, environment, onLines, onExit in
        try ControlClient(binary: invocation.executable, arguments: invocation.arguments, environment: environment,
                          onLines: onLines, onExit: onExit)
    }

    /// Starts the client. `onLines` gets each chunk of complete output lines on a background queue, and `onExit`
    /// runs once on the main thread after the client has been reaped. Without `environment`, the client gets the
    /// app's own.
    init(binary: String, arguments: [String], environment: [String: String]? = nil,
         onLines: @escaping ([String]) -> Void, onExit: @escaping () -> Void) throws {
        let argv = ([binary] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let envp = environment.map { $0.map { strdup("\($0.key)=\($0.value)") } + [nil] }
        defer { envp?.forEach { free($0) } }
        var master: Int32 = -1
        let pid = envp.map { muxify_forkpty_exec(binary, argv, $0, &master) } ?? muxify_forkpty_exec(binary, argv, environ, &master)
        guard pid > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        self.pid = pid
        self.master = master
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)

        reader = DispatchSource.makeReadSource(fileDescriptor: master, queue: DispatchQueue(label: "muxify.tmux-events"))
        var buffer = Data()
        reader.setEventHandler { [reader] in
            var chunk = [UInt8](repeating: 0, count: 16384)
            let count = read(master, &chunk, chunk.count)
            guard count > 0 else {
                // A pty whose client has gone reads as EIO, not as end of file.
                if count == 0 || (errno != EAGAIN && errno != EINTR) { reader.cancel() }
                return
            }
            buffer.append(contentsOf: chunk[..<count])
            var lines: [String] = []
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                var line = buffer[buffer.startIndex..<newline]
                if line.last == UInt8(ascii: "\r") { line = line.dropLast() }
                lines.append(String(decoding: line, as: UTF8.self))
                buffer.removeSubrange(buffer.startIndex...newline)
            }
            if !lines.isEmpty { onLines(lines) }
        }
        let state = state
        reader.setCancelHandler {
            state.lock.lock()
            state.closed = true
            close(master)
            state.lock.unlock()
        }
        reader.resume()

        // The exit source keeps this client alive until it has reaped tmux.
        exitSource = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        exitSource.setEventHandler { [self] in
            if reap() { onExit() }
        }
        exitSource.resume()
        // A client that exited before the source was watching gets no event.
        if waitpid(pid, nil, WNOHANG) == pid {
            state.lock.lock()
            state.exited = true
            state.lock.unlock()
            exitSource.cancel()
            reader.cancel()
            DispatchQueue.main.async(execute: onExit)
        }
    }

    var isRunning: Bool {
        state.lock.lock()
        defer { state.lock.unlock() }
        return !state.exited
    }

    /// Writes one command line to the client through the pty.
    func send(_ command: String) {
        state.lock.lock()
        defer { state.lock.unlock() }
        guard !state.closed, !state.exited else { return }
        let line = Array((command + "\n").utf8)
        var offset = 0
        while offset < line.count {
            let written = line[offset...].withUnsafeBytes { write(master, $0.baseAddress, $0.count) }
            if written < 0, errno == EINTR { continue }
            guard written > 0 else { return }
            offset += written
        }
    }

    /// Closing the master hangs the client up; the exit source then reaps it.
    func stop() { reader.cancel() }

    /// True when this call reaped the client.
    private func reap() -> Bool {
        exitSource.cancel()
        state.lock.lock()
        guard !state.exited else { state.lock.unlock(); return false }
        state.exited = true
        state.lock.unlock()
        _ = waitpid(pid, nil, 0)
        return true
    }
}
