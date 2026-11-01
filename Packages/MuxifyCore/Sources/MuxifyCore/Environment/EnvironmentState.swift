import Foundation

public struct EnvironmentRevision: Codable, Hashable, Sendable {
    public let moduleID: UUID
    public let number: UInt64

    public init(moduleID: UUID, number: UInt64) {
        self.moduleID = moduleID
        self.number = number
    }

    public func isAfter(_ other: Self) -> Bool {
        moduleID == other.moduleID && number > other.number
    }
}

public enum EnvironmentFailure: Error, Codable, Equatable, CustomStringConvertible {
    case inventory(InventoryReadFailure)
    case tmux(TmuxError)
    case other(String)

    public init(_ error: Error) {
        switch error {
        case let failure as InventoryReadFailure: self = .inventory(failure)
        case let failure as TmuxError: self = .tmux(failure)
        default: self = .other(String(describing: error))
        }
    }

    public var description: String {
        switch self {
        case .inventory(let failure): return failure.description
        case .tmux(let failure): return failure.description
        case .other(let message): return message
        }
    }
}

public enum EnvironmentObservation<Value: Codable>: Codable {
    case current(Value)
    case unavailable(lastKnown: Value?, failure: EnvironmentFailure)

    public var current: Value? {
        if case .current(let value) = self { return value }
        return nil
    }

    public var lastKnown: Value? {
        switch self {
        case .current(let value): return value
        case .unavailable(let value, _): return value
        }
    }
}

public enum EnvironmentConnection: Codable, Equatable {
    case available
    case noServer
    case failed(EnvironmentFailure)
}

public struct EnvironmentState: Codable {
    public let revision: EnvironmentRevision
    public let inventory: EnvironmentObservation<TmuxSnapshot>
    public let records: EnvironmentObservation<TopicContents>
    public var ruleSettings: EnvironmentRuleSettings? = nil
    public var ownsRules: Bool = false
    public var ruleFailure: EnvironmentFailure? = nil
    public var branches = TopicBranches()
    public var existingWorktrees: [String] = []

    public var connection: EnvironmentConnection {
        switch inventory {
        case .current(let value): return value.serverRunning ? .available : .noServer
        case .unavailable(_, let failure): return .failed(failure)
        }
    }

    public var isConfirmed: Bool { inventory.current != nil && records.current != nil && ruleFailure == nil }
}

public struct EnvironmentWriteReceipt<Value> {
    public let revision: EnvironmentRevision
    public let value: Value
}

extension EnvironmentWriteReceipt: Codable where Value: Codable {}

public struct EnvironmentRead {
    public let inventory: Result<TmuxSnapshot, Error>
    public let records: Result<TopicContents, Error>
    var ruleSettings: EnvironmentRuleSettings?
    var ownsRules = false
    var ruleFailure: EnvironmentFailure?
    var branches = TopicBranches()
    var existingWorktrees: [String] = []

    public init(inventory: Result<TmuxSnapshot, Error>, records: Result<TopicContents, Error>) {
        self.inventory = inventory
        self.records = records
    }
}
