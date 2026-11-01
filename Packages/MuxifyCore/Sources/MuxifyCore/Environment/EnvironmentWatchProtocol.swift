import Foundation

public enum EnvironmentWatchProtocol {
    public static let version = 4
    public static let maximumLineBytes = 16 * 1024 * 1024
}

public struct EnvironmentTopicSettings: Codable {
    var order: SessionOrder
    var position: TopicInsertPosition
    var inPlay: Int?
    var tags: [Tag]?

    public init(_ topics: Config.Topics) {
        order = topics.sessionOrder
        position = topics.insertPosition
        inPlay = topics.inPlay
        tags = topics.tags?.definitions.map(\.tag)
    }

    var config: Config.Topics {
        var result = Config.Topics()
        result.sessionOrder = order
        result.insertPosition = position
        result.inPlay = inPlay
        result.tags = tags.flatMap { ConfigTags($0.map { TagDefinition(tag: $0) }) }
        return result
    }
}

public enum EnvironmentQuery: Codable, Sendable {
    case inventory
    case browserAvailability(pane: String?)
    case resolveWindow(String)
    case browserSocket
    case sessionExists(String)
    case settle(EnvironmentTarget)
    case forget(EnvironmentTarget)
    case worktreeStarts(String)
    /// The local branches of the checkout at the path, read on the Environment's machine, for New Worktree (ADR 0062).
    case muxifyWorktreeStarts(String)
    case removeWorktree(EnvironmentTarget)
}

public enum EnvironmentQueryResponse: Codable {
    case inventory(TmuxSnapshot)
    case browserAvailability(EnvironmentBrowserAvailability)
    case window(String?)
    case browserSocket(String?)
    case sessionExists(Bool)
    case settle([TopicSettleSession])
    case forget(TopicForgetChoices)
    case worktreeStarts([WorktreeStartChoice])
    case removeWorktree(TopicForgetChoices.Worktree?)
    case failed(TopicFailure)
}

public enum EnvironmentWatchInput: Codable {
    case hello(version: Int, settings: EnvironmentRuleSettings)
    case settings(EnvironmentRuleSettings)
    case viewing(reader: UUID, facts: EnvironmentViewing)
    case close(reader: UUID, id: UUID)
    case read
    case synchronize(reader: UUID)
    case full
    case perform(id: UUID, reader: UUID, request: EnvironmentRequest, client: String?,
                 sessionPaths: [SessionPath], topics: EnvironmentTopicSettings, worktreesRoot: String?, browsers: [EnvironmentBrowserState])
    case query(id: UUID, query: EnvironmentQuery, sessionPaths: [SessionPath], topics: EnvironmentTopicSettings)
    case attached(id: UUID, failure: EnvironmentFailure?)
}

public enum EnvironmentWatchOutput: Codable {
    case hello(version: Int, moduleID: UUID)
    case full(EnvironmentState)
    case delta(EnvironmentStateDelta)
    case performed(id: UUID, receipt: EnvironmentWriteReceipt<EnvironmentResponse>)
    case queried(id: UUID, response: EnvironmentQueryResponse)
    case attach(id: UUID, reader: UUID, plan: EnvironmentAttachment)
    case closed(id: UUID)
    case synchronized(reader: UUID, revision: EnvironmentRevision)
    case rejected(EnvironmentWatchRefusal)
}

/// A changed optional value carries its nil explicitly, so clearing a failure is different from no change.
public struct EnvironmentChanged<Value: Codable>: Codable {
    public let value: Value
}

public struct EnvironmentStateDelta: Codable {
    public let baseRevision: EnvironmentRevision
    public let revision: EnvironmentRevision
    public var inventory: EnvironmentChanged<EnvironmentObservation<TmuxSnapshot>>?
    public var records: EnvironmentChanged<EnvironmentObservation<TopicContents>>?
    public var ruleSettings: EnvironmentChanged<EnvironmentRuleSettings?>?
    public var ownsRules: EnvironmentChanged<Bool>?
    public var ruleFailure: EnvironmentChanged<EnvironmentFailure?>?
    public var branches: EnvironmentChanged<TopicBranches>?
    public var existingWorktrees: EnvironmentChanged<[String]>?

    public init(from previous: EnvironmentState, to next: EnvironmentState) {
        baseRevision = previous.revision
        revision = next.revision
        inventory = Self.changed(previous.inventory, next.inventory)
        records = Self.changed(previous.records, next.records)
        ruleSettings = Self.changed(previous.ruleSettings, next.ruleSettings)
        ownsRules = Self.changed(previous.ownsRules, next.ownsRules)
        ruleFailure = Self.changed(previous.ruleFailure, next.ruleFailure)
        branches = Self.changed(previous.branches, next.branches)
        existingWorktrees = Self.changed(previous.existingWorktrees, next.existingWorktrees)
    }

    public func applying(to previous: EnvironmentState) -> EnvironmentState? {
        guard previous.revision == baseRevision, revision.isAfter(baseRevision) else { return nil }
        return EnvironmentState(revision: revision,
            inventory: inventory?.value ?? previous.inventory, records: records?.value ?? previous.records,
            ruleSettings: ruleSettings.map(\.value) ?? previous.ruleSettings,
            ownsRules: ownsRules?.value ?? previous.ownsRules,
            ruleFailure: ruleFailure.map(\.value) ?? previous.ruleFailure,
            branches: branches?.value ?? previous.branches,
            existingWorktrees: existingWorktrees?.value ?? previous.existingWorktrees)
    }

    private static func changed<Value: Codable>(_ previous: Value, _ next: Value) -> EnvironmentChanged<Value>? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(previous)) == (try? encoder.encode(next)) ? nil : EnvironmentChanged(value: next)
    }
}

public enum EnvironmentWatchRefusal: String, Codable {
    case incompatibleVersion, missingHello, overloaded
}
