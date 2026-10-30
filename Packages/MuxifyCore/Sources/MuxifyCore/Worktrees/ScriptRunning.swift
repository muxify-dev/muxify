import Foundation

/// Runs a `/bin/sh` script on the Environment's machine: here for Local, over the owned SSH connection for a Remote
/// Environment. Muxify Worktree work is written as scripts, so the same code makes a Worktree on either.
public protocol ScriptRunning: Sendable {
    /// The script's stdout. A non-zero exit throws `TmuxError.failed` with its stderr.
    func runScript(_ script: String, arguments: [String], timeout: TimeInterval) throws -> String
}

public struct LocalScripts: ScriptRunning {
    public init() {}

    public func runScript(_ script: String, arguments: [String], timeout: TimeInterval) throws -> String {
        try CommandRunner().run(CommandInvocation(executable: "/bin/sh", arguments: ["-c", script, "muxify"] + arguments), timeout: timeout)
    }
}
