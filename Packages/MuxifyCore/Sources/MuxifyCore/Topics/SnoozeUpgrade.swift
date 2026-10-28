import Foundation

/// What an older Muxify wrote for Snooze and Zen, read only as far as `TopicStore.upgrade` needs it.
public enum SnoozeUpgrade {
    /// The record key that held a Topic's Snooze: an ISO 8601 time, or `never`.
    static let field = "snoozed_until"

    /// `zen.json`: the Snooze time Zen gave, and each Topic's Snooze from before Zen.
    struct Zen: Decodable {
        struct Change: Decodable {
            let topicID: String
            let previous: String?

            private enum CodingKeys: String, CodingKey {
                case topicID = "topic_id", previous = "previous_snoozed_until"
            }
        }

        let until: String
        let changes: [Change]
    }

    /// When a stored Snooze would wake: `never` after every time. Nil for a value that was never a Snooze.
    static func wake(_ stored: String) -> Date? {
        if stored == "never" { return .distantFuture }
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(stored)) ?? (try? Date.ISO8601FormatStyle().parse(stored))
    }
}

extension TopicStore {
    /// Upgrades the records in one write and removes `zen.json`. Returns the Locks that the write moved: the caller
    /// sets them in tmux. With nothing to upgrade it changes nothing, so every reader can call it.
    @discardableResult
    public func upgrade(locks: [SessionLock], arrival: TopicArrival) throws -> [SessionLock] {
        let file = paths.legacyZenFile
        let moved = try write(locks: locks) { transaction in
            // A `zen.json` that does not read is no Zen: its Topics keep their Snoozes and go to the Bench with the others.
            let zen = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(SnoozeUpgrade.Zen.self, from: $0) }
            return try transaction.upgradeSnoozes(endingZen: zen, arrival: arrival)
        }
        do { try FileManager.default.removeItem(at: file) } catch let error as CocoaError where error.code == .fileNoSuchFile {}
        return moved
    }
}
