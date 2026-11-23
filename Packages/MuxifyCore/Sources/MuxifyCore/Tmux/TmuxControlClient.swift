#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

/// A running `tmux -C` client: its output comes out as lines, and `send` gives it one command line.
public protocol TmuxControlClient: AnyObject {
    /// Writes one command line to the client. A client that has gone takes nothing.
    func send(_ command: String)
    /// Ends the client. Its exit handler still runs.
    func stop()
}

/// Starts a control client for `invocation` in `environment`. `onLines` gets each chunk of complete output lines and
/// `onExit` runs once when the client's process has ended, both on any thread.
public typealias TmuxControlClientStart = (
    _ invocation: CommandInvocation, _ environment: [String: String],
    _ onLines: @escaping ([String]) -> Void, _ onExit: @escaping () -> Void
) throws -> TmuxControlClient

/// A control client on pipes. The client ends when its input closes, so it ends with the process that started it.
/// The app starts its own on a pty instead (`ControlClient`), whose hangup also ends a client that tmux 3.7c keeps.
public final class PipeControlClient: TmuxControlClient {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var closed = false

    public static let start: TmuxControlClientStart = { invocation, environment, onLines, onExit in
        try PipeControlClient(invocation: invocation, environment: environment, onLines: onLines, onExit: onExit)
    }

    public init(invocation: CommandInvocation, environment: [String: String],
                onLines: @escaping ([String]) -> Void, onExit: @escaping () -> Void) throws {
        process.executableURL = URL(fileURLWithPath: invocation.executable)
        process.arguments = invocation.arguments
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        ignoreBrokenPipes(on: input.fileHandleForWriting.fileDescriptor)
        let exit = try process.start()
        var buffer = Data()
        let reading = OutputEnd()
        output.fileHandleForReading.readabilityHandler = { handle in
            guard let chunk = reading.read(handle), !chunk.isEmpty else { return }
            buffer.append(chunk)
            var lines: [String] = []
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                var line = buffer[buffer.startIndex..<newline]
                if line.last == UInt8(ascii: "\r") { line = line.dropLast() }
                lines.append(String(decoding: line, as: UTF8.self))
                buffer.removeSubrange(buffer.startIndex...newline)
            }
            if !lines.isEmpty { onLines(lines) }
        }
        let output = output
        Thread.detachNewThread { [weak self] in
            exit.wait()
            self?.closeInput()
            reading.close(output.fileHandleForReading)
            onExit()
        }
    }

    public func send(_ command: String) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        _ = writeAll(Data((command + "\n").utf8), to: input.fileHandleForWriting.fileDescriptor)
    }

    /// Closes the client's input, which ends it; one that is still there a second later is terminated.
    public func stop() {
        closeInput()
        let process = process
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            if process.isRunning { process.terminate() }
        }
    }

    private func closeInput() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        try? input.fileHandleForWriting.close()
    }

    /// The read end of the client's output, which the client closes when its process exits, not at deinit: on Linux
    /// Foundation's Process and its run loop source retain each other until `waitUntilExit()`, so the Process, and the
    /// Pipe with it, is never freed, and each client left its descriptor open. A read never meets a closed handle:
    /// the close marks the end first, and a read that began before it finishes first.
    private final class OutputEnd: @unchecked Sendable {
        private let lock = NSLock()
        private var closed = false

        /// What the handle has, or nil once it is closed. At the end of the output the handle stops being read.
        func read(_ handle: FileHandle) -> Data? {
            lock.lock()
            defer { lock.unlock() }
            guard !closed else { return nil }
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil }
            return chunk
        }

        func close(_ handle: FileHandle) {
            lock.lock()
            guard !closed else { lock.unlock(); return }
            closed = true
            lock.unlock()
            // Not under the lock: on Linux `close()` waits for the handle's queue, where a read may wait for the lock.
            handle.readabilityHandler = nil
            try? handle.close()
        }
    }
}
