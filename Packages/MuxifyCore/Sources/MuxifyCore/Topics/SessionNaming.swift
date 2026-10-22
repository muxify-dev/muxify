import Foundation

/// Naming never establishes membership, folder ownership, or Session identity.
public enum SessionNaming {
    public static func available(_ base: String, topic: String? = nil, taken: Set<String>) -> String {
        let suffix = topic.map { "/" + $0 } ?? ""
        if !taken.contains(base + suffix) { return base + suffix }
        let stem: String
        if let plus = base.lastIndex(of: "+"), let number = Int(base[base.index(after: plus)...]), number >= 2 {
            stem = String(base[..<plus])
        } else { stem = base }
        var number = 2
        while taken.contains(stem + "+\(number)" + suffix) { number += 1 }
        return stem + "+\(number)" + suffix
    }

    public static func base(of name: String, topic: TopicRecord?) -> String {
        guard let slug = topic?.slug, name.hasSuffix("/" + slug) else { return name }
        return String(name.dropLast(slug.count + 1))
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

    public func detachedCommands(for window: TmuxWindow, taken: inout Set<String>) -> [TopicPlan.Command] {
        taken.remove(window.sessionName)
        let name = SessionNaming.available(baseName(of: window), taken: taken)
        taken.insert(name)
        return [.tmux(["rename-session", "-t", window.sessionID, name]),
                .tmux(["set-option", "-u", "-t", window.sessionID, "@muxify_topic"]),
                .tmux(SessionLock.unsetOption(window.sessionID))]
    }
}
