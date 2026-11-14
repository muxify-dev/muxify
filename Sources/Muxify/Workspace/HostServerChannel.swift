import Foundation
import MuxifyCore

/// The byte stream of one `muxify server`: in the app, a `-T` channel of the attachment's SSH master; in a test, a
/// pair of pipes to a server in the test process. The protocol client reads `input` and writes `output`.
final class HostServerChannel: @unchecked Sendable {
    /// What the server writes.
    let input: FileHandle
    /// What the server reads.
    let output: FileHandle
    /// The server's stderr, plain-text lines that are never parsed; nil for a channel that has none.
    let errors: FileHandle?
    private let status: @Sendable () -> Int32?
    private let stop: @Sendable () -> Void

    init(input: FileHandle, output: FileHandle, errors: FileHandle? = nil,
         status: @escaping @Sendable () -> Int32? = { nil }, stop: @escaping @Sendable () -> Void) {
        self.input = input
        self.output = output
        self.errors = errors
        self.status = status
        self.stop = stop
    }

    /// The exit status of the channel's process once it ended, waiting up to `timeout`; nil while it runs, or for a
    /// channel with no process. Blocks, so call it off the main thread.
    func exitStatus(waiting timeout: TimeInterval) -> Int32? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let status = status() { return status }
            guard Date() < deadline else { return nil }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    /// Ends the channel: the server reads EOF and exits.
    func close() { stop() }

    /// Runs `invocation`, an `ssh -T` over the master, with the server's stdin, stdout and stderr on pipes.
    static func process(_ invocation: CommandInvocation) throws -> HostServerChannel {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: invocation.executable)
        process.arguments = invocation.arguments
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let writer = stdin.fileHandleForWriting
        return HostServerChannel(input: stdout.fileHandleForReading, output: writer, errors: stderr.fileHandleForReading,
                                 status: { process.isRunning ? nil : process.terminationStatus },
                                 stop: {
                                     try? writer.close()
                                     if process.isRunning { process.terminate() }
                                 })
    }
}

/// The last lines a Host Server wrote to stderr. The link logs them only when the channel fails.
final class HostServerErrors: @unchecked Sendable {
    static let limit = 50
    private let lock = NSLock()
    private var kept: [String] = []
    private var partial = Data()

    /// Reads `handle` until its end, keeping the last `limit` lines.
    func read(_ handle: FileHandle?) {
        handle?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                self?.finish()
                return
            }
            self?.append(data)
        }
    }

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return kept
    }

    var last: String? { lines.last }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        partial.append(data)
        while let newline = partial.firstIndex(of: UInt8(ascii: "\n")) {
            keep(String(decoding: partial[partial.startIndex..<newline], as: UTF8.self))
            partial.removeSubrange(partial.startIndex...newline)
        }
    }

    private func finish() {
        lock.lock()
        defer { lock.unlock() }
        if !partial.isEmpty { keep(String(decoding: partial, as: UTF8.self)) }
        partial.removeAll()
    }

    /// Under `lock`.
    private func keep(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        kept.append(trimmed)
        if kept.count > Self.limit { kept.removeFirst(kept.count - Self.limit) }
    }
}
