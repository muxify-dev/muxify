/// The calls that Environment requests make on a tmux server. `TmuxServer` is a local server; the app's SSH
/// connection is the server of a Remote Environment.
public protocol TmuxRunning: Sendable {
    @discardableResult func run(_ arguments: [String]) throws -> String
    func snapshot() throws -> TmuxSnapshot
    /// Runs before Muxify types a command into `target`, a Pane of a Session that it just made (ADR 0095).
    func reportColours(beforeTypingInto target: String)
}

extension TmuxRunning {
    public func reportColours(beforeTypingInto target: String) {}
}

extension TmuxServer: TmuxRunning {}

/// The app's local server: its Listener writes the Colour Report of ADR 0095 before each command that Muxify types
/// into a Session that it just made. A switch needs none here: the App Window's view commands run a switch on the
/// Listener after its report, and the Listener reports when it follows the Terminal after any other.
public struct ColourReportingTmux: TmuxRunning {
    private let server: any TmuxRunning
    private let publisher: EnvironmentPublisher

    public init(server: any TmuxRunning, publisher: EnvironmentPublisher) {
        self.server = server
        self.publisher = publisher
    }

    @discardableResult
    public func run(_ arguments: [String]) throws -> String {
        try server.run(arguments)
    }

    public func snapshot() throws -> TmuxSnapshot {
        try server.snapshot()
    }

    public func reportColours(beforeTypingInto target: String) {
        publisher.reportColours(beforeTypingInto: target)
    }
}
