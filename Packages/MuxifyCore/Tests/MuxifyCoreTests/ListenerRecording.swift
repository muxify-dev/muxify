import Foundation
@testable import MuxifyCore

/// What a publisher sent its Listener, line by line, and each of its connections: a test that starts the publisher's
/// control Clients through `recording()` sees what tmux wrote each connection, and can send a command behind
/// everything the publisher sent.
final class SentLines: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    private var connections: [ListenerConnection] = []
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return log }
    func add(_ line: String) { lock.lock(); log.append(line); lock.unlock() }
    func clear() { lock.lock(); log = []; lock.unlock() }
    /// The connection that the publisher started last.
    var latest: ListenerConnection? { lock.lock(); defer { lock.unlock() }; return connections.last }
    func started(_ connection: ListenerConnection) { lock.lock(); connections.append(connection); lock.unlock() }

    /// Starts control Clients as `start` does, and records each connection here and every line sent on it.
    func recording(_ start: @escaping TmuxControlClientStart = PipeControlClient.start) -> TmuxControlClientStart {
        { [self] invocation, environment, onLines, onExit in
            let connection = ListenerConnection(arguments: invocation.arguments)
            // After the publisher's own handler, so a test that saw a line can wait for the publisher's queue behind it.
            let client = try start(invocation, environment, { lines in
                onLines(lines)
                connection.hear(lines)
            }, onExit)
            connection.connect(client)
            started(connection)
            return RecordingControlClient(client, sent: self)
        }
    }
}

/// One control connection of the Listener: how the publisher attached it, and every line that tmux wrote it.
final class ListenerConnection: @unchecked Sendable {
    let arguments: [String]
    private let lock = NSLock()
    private var log: [String] = []
    private var client: TmuxControlClient?

    init(arguments: [String]) { self.arguments = arguments }

    var heard: [String] { lock.lock(); defer { lock.unlock() }; return log }
    func hear(_ lines: [String]) { lock.lock(); log += lines; lock.unlock() }
    func connect(_ client: TmuxControlClient) { lock.lock(); self.client = client; lock.unlock() }

    /// Whether the publisher attached it to the Terminal's Session, which it does once it knows the Terminal's
    /// Client: a Listener that follows the Terminal from its start does not start again.
    var followsTheTerminal: Bool { arguments.drop(while: { $0 != "attach-session" }).contains("-t") }
    /// Whether tmux attached it to a Session.
    var attached: Bool { heard.contains { $0.hasPrefix("%session-changed ") } }

    /// Sends, behind everything the publisher sent, a command that prints a word of its own, and returns the word.
    /// The publisher reads no command's output.
    func ping() -> String {
        let word = "muxify-test-ping-" + UUID().uuidString.prefix(8)
        lock.lock()
        let client = self.client
        lock.unlock()
        client?.send("display-message -p '\(word)'")
        return word
    }
}

final class RecordingControlClient: TmuxControlClient {
    let client: TmuxControlClient
    let sent: SentLines
    init(_ client: TmuxControlClient, sent: SentLines) { self.client = client; self.sent = sent }
    func send(_ command: String) { sent.add(command); client.send(command) }
    func stop() { client.stop() }
}
