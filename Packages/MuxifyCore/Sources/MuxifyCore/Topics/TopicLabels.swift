import Foundation

/// The name of each Topic, as its card shows it. An open Topic shows its title, else "Untitled N". A Settled Topic
/// shows its title, else its slug.
public struct TopicLabels: Sendable {
    /// The N of each open Topic with no title, by Topic id.
    private let numbers: [String: Int]

    /// An untitled open Topic keeps the N of its `untitled-N` slug when no other Topic took it first, by id order. The
    /// others take the lowest N that is free.
    public init(_ records: [TopicRecord]) {
        let untitled = records.filter { $0.settledAt == nil && Self.title(of: $0) == nil }.sorted { $0.id < $1.id }
        var numbers: [String: Int] = [:]
        var used: Set<Int> = []
        for record in untitled {
            if let number = Self.slugNumber(of: record), used.insert(number).inserted { numbers[record.id] = number }
        }
        for record in untitled where numbers[record.id] == nil {
            let number = Self.lowestFree(used)
            numbers[record.id] = number
            used.insert(number)
        }
        self.numbers = numbers
    }

    /// A record that was not in the list takes its number as if it came last.
    public func label(of record: TopicRecord) -> String {
        if let title = Self.title(of: record) { return title }
        if record.settledAt != nil {
            return record.slug.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? "Untitled Topic"
        }
        if let number = numbers[record.id] { return "Untitled \(number)" }
        let used = Set(numbers.values)
        if let number = Self.slugNumber(of: record), !used.contains(number) { return "Untitled \(number)" }
        return "Untitled \(Self.lowestFree(used))"
    }

    private static func title(of record: TopicRecord) -> String? {
        guard let title = record.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return title
    }

    private static func slugNumber(of record: TopicRecord) -> Int? {
        guard let slug = record.slug, slug.hasPrefix("untitled-"), let number = Int(slug.dropFirst(9)), number > 0 else { return nil }
        return number
    }

    private static func lowestFree(_ used: Set<Int>) -> Int {
        var number = 1
        while used.contains(number) { number += 1 }
        return number
    }
}
