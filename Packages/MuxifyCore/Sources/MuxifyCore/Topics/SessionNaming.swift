import Foundation

/// Naming never establishes membership, folder ownership, or Session identity.
public enum SessionNaming {
    public static func available(_ base: String, topic: String? = nil, taken: Set<String>) -> String {
        let suffix = topic.map { "/" + $0 } ?? ""
        if !taken.contains(base + suffix) { return base + suffix }
        let stem = stem(of: base)
        var number = 2
        while taken.contains(stem + "+\(number)" + suffix) { number += 1 }
        return stem + "+\(number)" + suffix
    }

    public static func base(of name: String, topic: TopicRecord?) -> String {
        guard let slug = topic?.slug, name.hasSuffix("/" + slug) else { return name }
        return String(name.dropLast(slug.count + 1))
    }

    /// In a Topic, every Session of a repository shares its Session Path's name, with `+x` on collision, and the Topic
    /// slug tells the Sessions apart. Outside a Topic that name launches the Session Path's own folder, so a Session
    /// takes the launch name of the folder it runs in, such as its Worktree's. A name the user chose stays.
    public static func outsideTopics(_ base: String, in folder: Folder, sessionPaths: [SessionPath]) -> String {
        guard let choice = SessionChoice.containing(folder, in: sessionPaths), stem(of: base) == choice.sessionPath.name
        else { return base }
        return choice.directory.real == choice.sessionPath.folder.real ? base : choice.name
    }

    private static func stem(of name: String) -> String {
        guard let plus = name.lastIndex(of: "+"), let number = Int(name[name.index(after: plus)...]), number >= 2 else { return name }
        return String(name[..<plus])
    }

    public static func validate(_ name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !name.contains("."), !name.contains(":"),
              name.rangeOfCharacter(from: .controlCharacters) == nil else { throw TopicEditFailure.invalidSessionPath }
    }
}

extension TopicRecord {
    public func session(of window: TmuxWindow) -> JSONValue? {
        sessions.first { $0["id"]?.string == window.sessionRecordID }
    }

    public func baseName(of window: TmuxWindow) -> String {
        // A direct tmux rename wins. Strip only this Topic's known suffix, never an arbitrary slash.
        SessionNaming.base(of: window.sessionName, topic: self)
    }

    public func detachedCommands(for window: TmuxWindow, sessionPaths: [SessionPath], taken: inout Set<String>) -> [TopicPlan.Command] {
        taken.remove(window.sessionName)
        let folder = Folder.local(window.sessionPath.isEmpty ? window.path : window.sessionPath)
        let name = SessionNaming.available(SessionNaming.outsideTopics(baseName(of: window), in: folder, sessionPaths: sessionPaths),
                                           taken: taken)
        taken.insert(name)
        return [.tmux(["rename-session", "-t", window.sessionID, name]),
                .tmux(["set-option", "-u", "-t", window.sessionID, "@muxify_topic"]),
                .tmux(SessionLock.unsetOption(window.sessionID))]
    }
}
