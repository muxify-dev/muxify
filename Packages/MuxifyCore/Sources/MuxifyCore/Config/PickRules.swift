/// What a pick list's row is, in the words `show` takes. One kind per row: it decides the row's icon, the ↩ title,
/// and whether `show` lists it.
public enum RowKind: String, CaseIterable {
    case topic
    case snoozed, settled
    /// A running Session in no open Topic, such as a Settled Topic's Session.
    case session
    /// A running Session in an open Topic, Snoozed or not.
    case topicSession = "topic-session"
    case sessionPath = "session-path"
    case worktree
    case window, agent, command, tag

    public static let all = Set(allCases)
}

/// An Action's pick list, by its `pick_lists` name. A Command Palette is not one: `command_palettes` names it.
/// Exhaustive on purpose: a new Action list adds a case, and the compiler finds every place that lists them.
public enum ActionList: String, CaseIterable {
    case addSession = "add_session"
    /// Move: the Topic step.
    case move
    /// Move: the destination Session step.
    case moveSession = "move_session"
    /// The check step of Snooze Topics… and of Unsnooze Topics….
    case snoozeTopics = "snooze_topics", unsnoozeTopics = "unsnooze_topics"
    /// Unsnooze Topic while the Active Topic is not Snoozed.
    case unsnoozeTopic = "unsnooze_topic"
    /// Tag completion in New Topic and Edit Tags.
    case tags
    /// Add a Session › New Worktree from.
    case worktreeStart = "worktree_start"

    /// The kinds its ranked rows can be: `show` may name only these.
    public var kinds: Set<RowKind> {
        switch self {
        case .addSession: [.session, .topicSession, .sessionPath, .worktree]
        case .move: [.topic]
        case .moveSession: [.session, .topicSession]
        case .snoozeTopics: [.tag, .topic, .snoozed]
        case .unsnoozeTopics: [.tag, .snoozed]
        case .unsnoozeTopic: [.snoozed]
        case .tags: [.tag]
        case .worktreeStart: [.command]
        }
    }
}

/// How one pick list filters its ranked rows: the `show` key, which a Command Palette and a `pick_lists` entry read the
/// same way.
public struct PickRules: Equatable {
    /// Never empty. The Config reader allows only the kinds the list can show.
    public var show: Set<RowKind>

    public init(show: Set<RowKind> = RowKind.all) {
        self.show = show
    }

    /// Every kind: the rules of a list that the Config does not name.
    public static let standard = PickRules()
}

/// "a, b or c", for a Config problem.
func spelledOut(_ words: [String]) -> String {
    words.count < 2 ? words.joined() : words.dropLast().joined(separator: ", ") + " or " + words[words.count - 1]
}
