import Foundation
import Darwin
import MuxifyCore

/// A command run in a pseudo-terminal, as in lazygit, so that git and ssh ask their questions, such as a password,
/// there. Its output is watched for them (`GitCredentialPrompt`); each goes to `onPrompt`, and `answer` writes the
/// reply and a newline into the terminal. The timeout doesn't run while a question waits. `cancel` stops it.
/// Callbacks come on the main queue; the completion once, with what it wrote, or `TmuxError.failed` with git's
/// message and no progress, `TmuxError.timedOut` or `TmuxError.cancelled`.
final class TerminalCommand: @unchecked Sendable {
    /// The C locale, so git's and ssh's prompts are in English.
    static let locale = ["LANG": "C", "LC_ALL": "C", "LC_MESSAGES": "C"]

    /// The output kept: its end, where git's message is.
    private static let outputLimit = 1 << 20
    private let queue = DispatchQueue(label: "muxify.terminal-command", qos: .userInitiated)
    private let onPrompt: (GitCredentialPrompt) -> Void
    private let completion: (Result<String, Error>) -> Void
    // Only touched on `queue`.
    private var pid: pid_t = -1
    private var master: Int32 = -1
    private var reader: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private var output = Data()
    /// The text since the last line break, or since the last question.
    private var line: [UInt8] = []
    /// The last lines, which say what a question is about.
    private var recentLines: [String] = []
    private var isWaiting = false
    private var remaining: TimeInterval
    private var runningSince = Date()
    private var deadline: DispatchWorkItem?
    private var status: Int32?
    private var isReadingDone = false
    private var isFinished = false
    private var isCancelled = false
    private var isTimedOut = false
    /// Itself, until it completes, so that whoever started it needn't hold it.
    private var running: TerminalCommand?

    /// Starts `invocation` in its own terminal, with `environment` added to Muxify's.
    init(_ invocation: CommandInvocation, environment: [String: String] = [:], timeout: TimeInterval,
         onPrompt: @escaping (GitCredentialPrompt) -> Void, completion: @escaping (Result<String, Error>) -> Void) throws {
        self.onPrompt = onPrompt
        self.completion = completion
        remaining = timeout
        let variables = ProcessInfo.processInfo.environment.merging(Self.locale) { $1 }.merging(environment) { $1 }
        let argv = ([invocation.executable] + invocation.arguments).map { strdup($0) } + [nil]
        let envp = variables.map { strdup("\($0)=\($1)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var master: Int32 = -1
        let pid = muxify_forkpty_terminal_exec(invocation.executable, argv, envp, &master)
        guard pid > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        queue.sync { start(pid: pid, master: master) }
    }

    /// Writes the answer to the question waiting, and a newline, and the timeout runs again.
    func answer(_ text: String) {
        queue.async { [self] in
            guard isWaiting, !isFinished else { return }
            isWaiting = false
            let bytes = Array((text + "\n").utf8)
            var offset = 0
            while offset < bytes.count {
                let count = bytes[offset...].withUnsafeBufferPointer { write(master, $0.baseAddress, $0.count) }
                if count > 0 { offset += count } else if count < 0, errno != EAGAIN, errno != EINTR { break }
            }
            startDeadline()
        }
    }

    /// Stops the command; it completes with `TmuxError.cancelled`.
    func cancel() {
        queue.async { [self] in
            guard !isFinished else { return }
            isCancelled = true
            terminate()
        }
    }

    private func start(pid: pid_t, master: Int32) {
        self.pid = pid
        self.master = master
        running = self
        let reader = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        reader.setEventHandler { [weak self] in self?.read() }
        reader.setCancelHandler { close(master) }
        self.reader = reader
        reader.resume()
        let exitSource = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        exitSource.setEventHandler { [weak self] in self?.reap() }
        self.exitSource = exitSource
        exitSource.resume()
        // A command that exited before the source was watching gets no event.
        reap()
        startDeadline()
    }

    private func read() {
        var chunk = [UInt8](repeating: 0, count: 16384)
        let count = Darwin.read(master, &chunk, chunk.count)
        guard count > 0 else {
            // A pty whose command has gone reads as EIO, not as end of file.
            if count == 0 || (errno != EAGAIN && errno != EINTR) { readingEnded() }
            return
        }
        output.append(contentsOf: chunk[..<count])
        if output.count > Self.outputLimit { output.removeFirst(output.count - Self.outputLimit) }
        // Byte by byte, as lazygit does: a prompt is asked once its last character is written.
        for byte in chunk[..<count] {
            if byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r") {
                let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { recentLines = Array((recentLines + [text]).suffix(3)) }
                line.removeAll()
                continue
            }
            line.append(byte)
            guard !isWaiting, var prompt = GitCredentialPrompt.match(String(decoding: line, as: UTF8.self)) else { continue }
            line.removeAll()
            prompt.context = prompt.kind == .hostKey ? recentLines : []
            recentLines.removeAll()
            isWaiting = true
            pauseDeadline()
            DispatchQueue.main.async { [onPrompt] in onPrompt(prompt) }
        }
    }

    private func reap() {
        guard status == nil else { return }
        var value: Int32 = 0
        guard waitpid(pid, &value, WNOHANG) == pid else { return }
        status = value
        exitSource?.cancel()
        deadline?.cancel()
        // The last output may still be in the pty; a descendant that keeps it open gets a second.
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.readingEnded() }
        finishIfDone()
    }

    private func readingEnded() {
        guard !isReadingDone else { return }
        isReadingDone = true
        reader?.cancel()
        finishIfDone()
    }

    private func finishIfDone() {
        guard let status, isReadingDone, !isFinished else { return }
        isFinished = true
        deadline?.cancel()
        let text = String(decoding: output, as: UTF8.self)
        let result: Result<String, Error>
        if isCancelled {
            result = .failure(TmuxError.cancelled)
        } else if isTimedOut {
            result = .failure(TmuxError.timedOut)
        } else if (status & 0x7f) == 0, (status >> 8) & 0xff == 0 {
            result = .success(text)
        } else {
            let code = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
            result = .failure(TmuxError.failed(status: code, stderr: GitTerminalOutput.message(text)))
        }
        running = nil
        DispatchQueue.main.async { [completion] in completion(result) }
    }

    private func startDeadline() {
        deadline?.cancel()
        runningSince = Date()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isFinished, !self.isWaiting else { return }
            self.isTimedOut = true
            self.terminate()
        }
        deadline = work
        queue.asyncAfter(deadline: .now() + max(remaining, 0), execute: work)
    }

    private func pauseDeadline() {
        deadline?.cancel()
        deadline = nil
        remaining -= Date().timeIntervalSince(runningSince)
    }

    /// The command leads its own session, so its group is it and what it started, such as ssh.
    private func terminate() {
        guard status == nil else { return }
        kill(-pid, SIGTERM)
        kill(pid, SIGTERM)
        queue.asyncAfter(deadline: .now() + 0.5) { [self] in
            guard status == nil else { return }
            kill(-pid, SIGKILL)
            kill(pid, SIGKILL)
        }
    }
}
