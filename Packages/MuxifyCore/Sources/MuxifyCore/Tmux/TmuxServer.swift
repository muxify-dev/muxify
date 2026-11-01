import Foundation

/// The tmux server that Topic work acts on. The server is a choice the caller makes, not one that an inherited
/// `$TMUX` makes: a command line tool in a Pane of another server still acts on the server it names.
public struct TmuxServer: Sendable {
    /// The user's default server: the `default` socket in `$TMUX_TMPDIR`, else in `/tmp`.
    public static let local = TmuxServer(options: [])

    private let options: [String]
    private let execute: @Sendable (CommandInvocation, [String: String]) throws -> String

    init(options: [String], execute: @escaping @Sendable (CommandInvocation, [String: String]) throws -> String = {
        try CommandRunner().run($0, timeout: 120, environment: $1)
    }) {
        self.options = options
        self.execute = execute
    }

    /// The server at `socketPath`, such as a throwaway server in a test's run directory. `configPath` replaces
    /// the user's tmux config when this call starts the server.
    public init(socketPath: String, configPath: String? = nil, commandTimeout: TimeInterval = 120) {
        self.init(options: ["-S", socketPath] + (configPath.map { ["-f", $0] } ?? []), execute: {
            try CommandRunner().run($0, timeout: commandTimeout, environment: $1)
        })
    }

    /// The default socket's server, with `configPath` in place of the user's tmux config when this call starts
    /// the server.
    public init(configPath: String) {
        self.init(options: ["-f", configPath])
    }

    public var socketPath: String {
        if let index = options.firstIndex(of: "-S"), options.indices.contains(index + 1) {
            return Folder.local(options[index + 1]).real
        }
        let root = ProcessInfo.processInfo.environment["TMUX_TMPDIR"].flatMap { $0.isEmpty ? nil : $0 } ?? "/tmp"
        return Folder.local(root + "/tmux-\(getuid())/default").real
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
        return try execute(invocation(arguments), environment)
    }

    /// A stopped server has an empty Inventory, so Create and Reopen can start it.
    public func snapshot() throws -> TmuxSnapshot {
        do { return try Tmux.readSnapshot(using: run) }
        catch InventoryReadFailure.noServer {
            return TmuxSnapshot(windows: [], clients: [], panes: [], serverRunning: false)
        }
    }
}
