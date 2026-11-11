import Foundation

/// How many times each counted SwiftUI view's body ran over a stretch of time, by the view's name, such as
/// `SidebarCard`. The app's body counter only ever grows, except when a verify check resets it; Diagnostics reads it
/// each second and keeps the differences, which `init(from:to:)` makes.
public struct BodyCounts: Equatable, Sendable {
    /// No name with zero.
    public private(set) var counts: [String: Int] = [:]

    public init(_ counts: [String: Int] = [:]) {
        self.counts = counts.filter { $0.value > 0 }
    }

    /// The bodies that ran between two readings of the counter. A count that fell, as after a reset of the counter,
    /// started again from zero, so the difference is its later count: never negative.
    public init(from earlier: [String: Int], to later: [String: Int]) {
        self.init(later.reduce(into: [:]) { result, item in
            let before = earlier[item.key, default: 0]
            result[item.key] = item.value >= before ? item.value - before : item.value
        })
    }

    public var isEmpty: Bool { counts.isEmpty }

    public subscript(name: String) -> Int { counts[name, default: 0] }

    public static func += (counts: inout BodyCounts, more: BodyCounts) {
        counts.counts.merge(more.counts, uniquingKeysWith: +)
    }

    /// `none`, or `name:N,name:N` in the order of the names.
    public var value: String {
        isEmpty ? "none" : DiagnosticsRecord.pairs(counts.sorted { $0.key < $1.key }.map { ($0.key, String($0.value)) })
    }

    public init?(value: String) {
        if value == "none" { self.init(); return }
        var counts: [String: Int] = [:]
        for pair in DiagnosticsRecord.pairs(in: value) ?? [] {
            guard !pair.name.isEmpty, counts[pair.name] == nil, let count = Int(pair.value), count > 0 else { return nil }
            counts[pair.name] = count
        }
        guard !counts.isEmpty else { return nil }
        self.init(counts)
    }
}
