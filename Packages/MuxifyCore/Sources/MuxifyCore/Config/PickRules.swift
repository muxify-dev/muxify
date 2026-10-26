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

/// How one pick list filters its ranked rows: the `show` key of a Command Palette.
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
