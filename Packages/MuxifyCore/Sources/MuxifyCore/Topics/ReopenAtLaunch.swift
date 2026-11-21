/// Reopen at launch (`topics.reopen_at_launch`): the Dormant open Topics and the Dormant Guest Sessions that Muxify
/// Reopens by itself when it launches, for example after a computer restart left tmux with none of the user's Sessions.
/// Each Environment gets one answer per launch, so a tmux restart while Muxify runs Reopens nothing.
public struct ReopenAtLaunch: Sendable {
    private var answered: Set<String> = []

    public init() {}

    /// The cards to Reopen, the first time `environment` asks in this launch; none after that. With the key off the
    /// answer is none, and the Environment has still had its one answer.
    public mutating func cards(in environment: String, enabled: Bool, contents: TopicContents, windows: [TmuxWindow]) -> [TopicListID] {
        guard answered.insert(environment).inserted, enabled else { return [] }
        return Self.dormant(contents: contents, windows: windows)
    }

    /// Every Dormant open Topic, in record order, whether Pinned, In Play, a Guest or on the Bench: not Settled,
    /// remembering a Session, and with no live Session. An Empty Topic remembers none, so Reopen would create nothing.
    /// Then every Dormant Guest Session, in Lock id order: a Lock with no live Session.
    public static func dormant(contents: TopicContents, windows: [TmuxWindow]) -> [TopicListID] {
        let live = Set(windows.compactMap(\.topicID))
        let open = Set(contents.records.filter { $0.settledAt == nil }.map(\.id))
        return contents.records.filter { $0.settledAt == nil && !$0.sessions.isEmpty && !live.contains($0.id) }.map { .topic($0.id) }
            + contents.locks.filter { $0.windows(in: windows, open: open).isEmpty }.map { .lock($0.id) }
    }
}
