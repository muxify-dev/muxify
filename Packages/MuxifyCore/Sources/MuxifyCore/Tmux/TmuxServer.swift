import Foundation

/// The tmux server that Topic work acts on. The server is a choice the caller makes, not one that an inherited
/// `$TMUX` makes: a command line tool in a Pane of another server still acts on the server it names.
public struct TmuxServer: Sendable {
    /// The user's default server: the `default` socket in `$TMUX_TMPDIR`, else in `/tmp`. Read at each use, so a
    /// caller that changes `$TMUX_TMPDIR` gets the server there.
    public static var local: TmuxServer { TmuxServer(options: [], socketPath: defaultSocketPath()) }

    private let options: [String]
    private let socketPath: String

    private init(options: [String], socketPath: String) {
        self.options = options
        self.socketPath = socketPath
    }

    /// The socket that tmux makes when no `-S` or `-L` names one.
    public static func defaultSocketPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let directory = environment["TMUX_TMPDIR"].flatMap { $0.isEmpty ? nil : $0 } ?? "/tmp"
        return "\(directory)/tmux-\(getuid())/default"
    }

    /// The server that a tmux client started in `environment` talks to: the socket in `$TMUX`, else the default one.
    public static func ofClient(environment: [String: String] = ProcessInfo.processInfo.environment) -> TmuxServer {
        // $TMUX is `<socket path>,<server pid>,<session id>`, and the path may hold a comma.
        let fields = environment["TMUX"]?.components(separatedBy: ",") ?? []
        guard fields.count >= 3 else { return TmuxServer(options: [], socketPath: defaultSocketPath(environment: environment)) }
        return TmuxServer(options: [], socketPath: fields.dropLast(2).joined(separator: ","))
    }

    /// The server at `socketPath`, such as a throwaway server in a test's run directory. `configPath` replaces
    /// the user's tmux config when this call starts the server.
    public init(socketPath: String, configPath: String? = nil) {
        self.init(options: ["-S", socketPath] + (configPath.map { ["-f", $0] } ?? []), socketPath: socketPath)
    }

    /// The default socket's server, with `configPath` in place of the user's tmux config when this call starts
    /// the server.
    public init(configPath: String) {
        self.init(options: ["-f", configPath], socketPath: Self.defaultSocketPath())
    }

    /// The tmux that runs commands on this server: the program of the process that holds its socket, which is
    /// always of the server's version, else the tmux found on `$PATH` or in the usual folders, for a server that
    /// does not run yet.
    public var binary: String? { TmuxServerBinary.path(forSocket: socketPath) ?? Tmux.binary }

    /// The tmux command line for `arguments` on this server.
    public func invocation(_ arguments: [String]) throws -> CommandInvocation {
        guard let binary else { throw TmuxError.notInstalled }
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
