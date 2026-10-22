/// The two calls that Environment requests make on a tmux server. `TmuxServer` is a local server; the app's SSH
/// connection is the server of a Remote Environment.
public protocol TmuxRunning: Sendable {
    @discardableResult func run(_ arguments: [String]) throws -> String
    func snapshot() throws -> TmuxSnapshot
}

extension TmuxServer: TmuxRunning {}
