import Foundation

/// The tmux server that Topic work acts on. The server is a choice the caller makes, not one that an inherited
/// `$TMUX` makes: a command line tool in a Pane of another server still acts on the server it names.
public struct TmuxServer: Sendable {
    /// The user's default server: the `default` socket in `$TMUX_TMPDIR`, else in `/tmp`.
    public static let local = TmuxServer(options: [])

    private let options: [String]

    private init(options: [String]) { self.options = options }

    /// The server at `socketPath`, such as a throwaway server in a test's run directory. `configPath` replaces
    /// the user's tmux config when this call starts the server.
    public init(socketPath: String, configPath: String? = nil) {
        self.init(options: ["-S", socketPath] + (configPath.map { ["-f", $0] } ?? []))
    }

    /// The default socket's server, with `configPath` in place of the user's tmux config when this call starts
    /// the server.
    public init(configPath: String) {
        self.init(options: ["-f", configPath])
    }

    /// The tmux command line for `arguments` on this server.
    public func invocation(_ arguments: [String]) throws -> CommandInvocation {
        guard let binary = Tmux.binary else { throw TmuxError.notInstalled }
        // `-u`: without a UTF-8 locale, as under launchd or an xcodebuild test, the tmux client prints
        // `Tmux.separator` as `_`, and every parsed field is wrong.
        return CommandInvocation(executable: binary, arguments: ["-u"] + options + arguments)
    }

    /// Runs one tmux command, or several joined by `;`, and returns its output.
    @discardableResult
    public func run(_ arguments: [String]) throws -> String {
        var environment = ProcessInfo.processInfo.environment
        // tmux uses the socket in $TMUX before the one in $TMUX_TMPDIR.
        environment["TMUX"] = nil
        environment["TMUX_PANE"] = nil
        // The long deadline is Shell's: the same commands ran through it before.
        return try CommandRunner().run(invocation(arguments), timeout: 120, environment: environment)
    }

    /// The server's Windows, clients and Panes; an empty snapshot when the server does not run.
    public func snapshot() -> TmuxSnapshot {
        (try? Tmux.readSnapshot(using: run))
            ?? TmuxSnapshot(windows: [], clients: [], panes: [], lastWindowID: nil, serverRunning: false)
    }
}
