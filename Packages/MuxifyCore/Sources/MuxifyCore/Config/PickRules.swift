/// What a pick list's row is. One kind per row: it decides the row's icon and the ↩ title.
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
}
