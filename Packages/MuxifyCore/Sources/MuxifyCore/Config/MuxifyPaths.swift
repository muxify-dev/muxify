import Foundation

/// Where Muxify keeps its files, by one rule for the app and the command line tool:
/// an XDG variable that is set but empty counts as unset.
public struct MuxifyPaths: Equatable, Sendable {
    /// `$XDG_STATE_HOME/muxify`: the Topic records, the Zen record and the Worktrees Muxify made.
    public let state: URL
    /// MUXIFY_CONFIG when it is set and not empty, so each launch can choose its Config; else the XDG path.
    public let configFile: URL

    public init(environment: [String: String] = ProcessInfo.processInfo.environment, home: String = NSHomeDirectory()) {
        func value(_ name: String) -> String? { environment[name].flatMap { $0.isEmpty ? nil : $0 } }
        state = URL(fileURLWithPath: value("XDG_STATE_HOME") ?? home + "/.local/state", isDirectory: true)
            .appendingPathComponent("muxify", isDirectory: true)
        if let path = value("MUXIFY_CONFIG") {
            configFile = URL(fileURLWithPath: path.hasPrefix("~/") ? home + path.dropFirst() : path)
        } else {
            configFile = URL(fileURLWithPath: (value("XDG_CONFIG_HOME") ?? home + "/.config") + "/muxify/config.yaml")
        }
    }

    public var topics: URL { state.appendingPathComponent("topics", isDirectory: true) }
    /// Beside `topics/`, not in it, because every JSON file in `topics/` is a Topic record.
    public var zenFile: URL { state.appendingPathComponent("zen.json") }
    /// Empty, and never removed: only its lock matters. Every write of the record files and the Zen record holds it.
    public var recordLock: URL { state.appendingPathComponent("topics.lock") }
    /// Empty, like the record lock. One Topic edit at a time holds it, from its read to its last tmux command,
    /// so a second edit sees the first one's Topic and Session names before it chooses its own.
    public var editLock: URL { state.appendingPathComponent("topic-edits.lock") }
    /// Every new Worktree goes to `<worktrees>/<sessionPath name>/<slug>`. Settle removes only Worktrees inside it.
    public var worktrees: URL { state.appendingPathComponent("worktrees", isDirectory: true) }
}
