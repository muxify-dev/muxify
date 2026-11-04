/// Reopen at launch (`topics.reopen_at_launch`): the Dormant open Topics that Muxify Reopens by itself when it
/// launches, for example after a computer restart left tmux with none of the user's Sessions. Each Environment gets
/// one answer per launch, so a tmux restart while Muxify runs Reopens nothing.
public struct ReopenAtLaunch: Sendable {
    private var answered: Set<String> = []

    public init() {}

    /// The Topics to Reopen, in record order, the first time `environment` asks in this launch; none after that.
    /// With the key off the answer is none, and the Environment has still had its one answer.
    public mutating func topics(in environment: String, enabled: Bool, records: [TopicRecord], windows: [TmuxWindow]) -> [String] {
        guard answered.insert(environment).inserted, enabled else { return [] }
        return Self.dormant(records: records, windows: windows)
    }

    /// Every Dormant open Topic, whether Pinned, In Play, a Guest or on the Bench: not Settled, remembering a Session,
    /// and with no live Session. An Empty Topic remembers none, so Reopen would create nothing.
    public static func dormant(records: [TopicRecord], windows: [TmuxWindow]) -> [String] {
        let live = Set(windows.compactMap(\.topicID))
        return records.filter { $0.settledAt == nil && !$0.sessions.isEmpty && !live.contains($0.id) }.map(\.id)
    }
}
