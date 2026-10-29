import Foundation

/// Where Muxify keeps its files, by one rule for the app and the command line tool:
/// an XDG variable that is set but empty counts as unset.
public struct MuxifyPaths: Equatable, Sendable {
    /// `$XDG_STATE_HOME/muxify`: the Topic records and the Worktrees Muxify made.
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
    /// The Zen record of an older Muxify. Only the upgrade of the records reads it, then removes it.
    public var legacyZenFile: URL { state.appendingPathComponent("zen.json") }
    /// Empty, and never removed: only its lock matters. Every write of the record files holds it.
    public var recordLock: URL { state.appendingPathComponent("topics.lock") }
    /// Empty, like the record lock. One Topic edit at a time holds it, from its read to its last tmux command,
    /// so a second edit sees the first one's Topic and Session names before it chooses its own.
    public var editLock: URL { state.appendingPathComponent("topic-edits.lock") }
    /// Browser History, for every Window of every Environment: the Browser runs on this Mac.
    public var browserHistory: URL { state.appendingPathComponent("browser-history.json") }
    /// Every new Worktree goes to `<worktrees>/<sessionPath name>/<slug>`. Settle removes only Worktrees inside it.
    public var worktrees: URL { state.appendingPathComponent("worktrees", isDirectory: true) }
    /// The `SessionPathCache` file of this Mac for `nil`, else of the Remote Environment with this name. The name
    /// is percent-encoded, so that each name gives a file name of its own.
    public func sessionPathCache(remote name: String?) -> URL {
        let file = name.map { "remote-" + ($0.addingPercentEncoding(withAllowedCharacters: Self.fileNameCharacters) ?? "") } ?? "local"
        return state.appendingPathComponent("session-paths", isDirectory: true).appendingPathComponent(file + ".json")
    }

    private static let fileNameCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
}
