import Foundation

/// A host, or a host and path, that holds two or more History entries (ADR 0059). The prefix tree is not stored:
/// `HistoryPrefix.all` makes it from the entries, and the score of a prefix is the sum of the scores of its entries.
struct HistoryPrefix: Equatable {
    /// The host and path without the scheme, such as `github.com/glebglazov`.
    let display: String
    let url: String
    /// The keys of the History entries at the prefix and below it.
    let keys: [String]
    /// The key of the History entry whose page is the prefix itself, if the user loaded it.
    let ownKey: String?

    private final class Node {
        var children: [String: Node] = [:]
        var ownKey: String?
        var keys: [String] = []
        var secure = false
    }

    /// The prefixes of the tree of hosts and path segments. A node with one child and no page of its own folds into
    /// its child, so a chain of segments gives one prefix.
    static func all(_ entries: [String: HistoryEntry]) -> [HistoryPrefix] {
        let root = Node()
        for entry in entries.values.sorted(by: { $0.key < $1.key }) {
            guard let components = URLComponents(string: entry.url), let host = components.host?.lowercased(), !host.isEmpty else { continue }
            let authority = host + (components.port.map { ":" + String($0) } ?? "")
            let segments = components.percentEncodedPath.split(separator: "/").map(String.init)
            var node = root
            for part in [authority] + segments {
                let child = node.children[part] ?? Node()
                node.children[part] = child
                child.keys.append(entry.key)
                if components.scheme?.lowercased() == "https" { child.secure = true }
                node = child
            }
            // A page with a query is not its path: it stays a page of its own under the prefix.
            if components.percentEncodedQuery == nil { node.ownKey = node.ownKey ?? entry.key }
        }
        var prefixes: [HistoryPrefix] = []
        func walk(_ node: Node, path: String) {
            let folds = node.ownKey == nil && node.children.count == 1
            if !folds, node.keys.count >= 2 {
                prefixes.append(HistoryPrefix(display: path, url: (node.secure ? "https://" : "http://") + path,
                                              keys: node.keys, ownKey: node.ownKey))
            }
            for (part, child) in node.children { walk(child, path: path + "/" + part) }
        }
        for (authority, node) in root.children { walk(node, path: authority) }
        return prefixes
    }
}

/// One row of the list under the address field (ADR 0060).
enum Suggestion: Equatable {
    case page(HistoryEntry)
    /// `title` is the title of the prefix's own page, empty when the user never loaded it.
    case prefix(HistoryPrefix, title: String)
    case tab(id: UUID, url: String, title: String)
    case devServer(port: Int)
    case search(String)

    var url: String {
        switch self {
        case .page(let entry): entry.url
        case .prefix(let prefix, _): prefix.url
        case .tab(_, let url, _): url
        case .devServer(let port): "http://localhost:" + String(port)
        case .search(let query): Omnibox.searchURL(for: query)?.absoluteString ?? ""
        }
    }

    var title: String {
        switch self {
        case .page(let entry): entry.title
        case .prefix(_, let title): title
        case .tab(_, _, let title): title
        case .devServer: "Listening in this tmux window"
        case .search(let query): "Search for “\(query)”"
        }
    }

    /// The host and path, without the scheme.
    var display: String {
        switch self {
        case .prefix(let prefix, _): prefix.display
        case .search(let query): query
        case .page(let entry): Self.display(ofKey: entry.key)
        default: Self.display(ofKey: BrowserTab.matchKey(url))
        }
    }

    var id: String {
        switch self {
        case .tab(let id, _, _): "tab-" + id.uuidString
        case .search: "search"
        default: BrowserTab.matchKey(url)
        }
    }

    /// The text that Inline completion makes of `typed`: a host or path that starts with it, as typed with or
    /// without the scheme and `www.`.
    func completion(of typed: String) -> String? {
        guard case .prefix = self, !typed.isEmpty else { return nil }
        let lowered = typed.lowercased()
        for form in [display, Self.withoutWWW(display), url] where form.count > typed.count && form.lowercased().hasPrefix(lowered) {
            return typed + form.dropFirst(typed.count)
        }
        return nil
    }

    /// The host and path of a `BrowserTab.matchKey`.
    static func display(ofKey key: String) -> String {
        guard let scheme = key.range(of: "://") else { return key }
        return String(key[scheme.upperBound...])
    }

    static func withoutWWW(_ text: String) -> String {
        text.lowercased().hasPrefix("www.") ? String(text.dropFirst(4)) : text
    }
}


/// The live rows of a Window that the list offers beside Browser History.
struct LiveRows {
    struct OpenTab: Equatable {
        let id: UUID
        let url: String
        let title: String
    }

    var tabs: [OpenTab] = []
    var ports: [Int] = []
}

/// What the ranker reads of Browser History: the entries, their prefixes, and the text of each row ready for the
/// match. It is in memory only, and made again after a change.
struct HistoryIndex {
    let entries: [String: HistoryEntry]
    let prefixes: [HistoryPrefix]
    fileprivate let rows: [Row]
    fileprivate let rowByKey: [String: Int]

    fileprivate struct Row {
        let key: String
        let suggestion: Suggestion
        let match: MatchText
    }

    init(_ entries: [String: HistoryEntry]) {
        self.entries = entries
        prefixes = HistoryPrefix.all(entries)
        var rows: [String: Row] = [:]
        for entry in entries.values {
            let suggestion = Suggestion.page(entry)
            rows[entry.key] = Row(key: entry.key, suggestion: suggestion, match: MatchText(suggestion))
        }
        // A prefix that is a page itself stands for that page.
        for prefix in prefixes {
            let key = prefix.ownKey ?? BrowserTab.matchKey(prefix.url)
            let suggestion = Suggestion.prefix(prefix, title: prefix.ownKey.flatMap { entries[$0]?.title } ?? "")
            rows[key] = Row(key: key, suggestion: suggestion, match: MatchText(suggestion))
        }
        self.rows = Array(rows.values)
        rowByKey = Dictionary(uniqueKeysWithValues: self.rows.enumerated().map { ($1.key, $0) })
    }
}

/// A row's display and title, lowercased, for the tests that run on every row at each key press.
private struct MatchText {
    let display: String
    let text: String
    let folded: [UInt8]
    /// The display without `www.`, for tier 1.
    let host: [UInt8]

    init(_ suggestion: Suggestion) {
        display = suggestion.display
        text = display + " " + suggestion.title
        folded = Array(text.lowercased().utf8)
        host = Array(Suggestion.withoutWWW(display.lowercased()).utf8)
    }

}

/// Orders the Suggestions for a query (ADR 0059): by tier, then by score in a tier, with the search row last.
enum SuggestionRanker {
    static let limit = 8

    private struct Candidate {
        let suggestion: Suggestion
        let match: MatchText
        let score: Double
        let tier: Int
    }

    static func rank(_ query: String, index: HistoryIndex, live: LiveRows, activeTopic: String?, now: Date) -> [Suggestion] {
        let typed = typedPrefix(query)
        // A display has no scheme, so the words match without the scheme and `www.` that the user typed.
        let search = Suggestion.search(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !FuzzyQuery(query).isEmpty else { return [] }
        let fuzzy = FuzzyQuery(String(decoding: typed, as: UTF8.self))
        guard !fuzzy.isEmpty else { return [search] }
        let words = fuzzy.words.map { Array($0.lowercased().utf8) }
        func entryScore(_ key: String) -> Double {
            guard let entry = index.entries[key] else { return 0 }
            let score = entry.score(at: now)
            return activeTopic.map(entry.topics.contains) == true ? score * 2 : score
        }
        func score(_ suggestion: Suggestion) -> Double {
            switch suggestion {
            case .page(let entry): entryScore(entry.key)
            case .prefix(let prefix, _): prefix.keys.reduce(0) { $0 + entryScore($1) }
            default: 0
            }
        }

        var candidates: [Candidate] = []
        var others: [Candidate] = []
        func consider(_ suggestion: Suggestion, _ match: MatchText, score: @autoclosure () -> Double) {
            guard let tier = tier(of: match, typed: typed, words: words) else { return }
            let candidate = Candidate(suggestion: suggestion, match: match, score: score(), tier: tier)
            if tier < 3 { candidates.append(candidate) } else { others.append(candidate) }
        }

        // An open Tab takes the place of its page or prefix, as a typed visit of now on top of its score.
        let tabKeys = Set(live.tabs.map { BrowserTab.matchKey($0.url) })
        for row in index.rows where !tabKeys.contains(row.key) { consider(row.suggestion, row.match, score: score(row.suggestion)) }
        for tab in live.tabs {
            let suggestion = Suggestion.tab(id: tab.id, url: tab.url, title: tab.title)
            let history = index.rowByKey[BrowserTab.matchKey(tab.url)].map { score(index.rows[$0].suggestion) } ?? 0
            consider(suggestion, MatchText(suggestion), score: history + HistoryVisit.typed.weight)
        }
        for port in live.ports {
            let suggestion = Suggestion.devServer(port: port)
            let key = BrowserTab.matchKey(suggestion.url)
            guard index.rowByKey[key] == nil, !tabKeys.contains(key) else { continue }
            consider(suggestion, MatchText(suggestion), score: 0)
        }

        // A word that starts the text or a word of it gets the same bonuses as the word against itself, so it is
        // above the 55% minimum. Only tier 3 needs the fuzzy matcher, and only when tiers 1 and 2 leave room.
        if candidates.count < limit - 1 {
            candidates += others.filter { candidate in
                zip(fuzzy.words, fuzzy.minimumScores).allSatisfy { word, minimum in
                    (FuzzyMatcher.match(word, in: candidate.match.text, scheme: .history)?.score ?? -1) >= minimum
                }
            }
        }
        candidates.sort { a, b in
            if a.tier != b.tier { return a.tier < b.tier }
            if a.score != b.score { return a.score > b.score }
            return a.match.display < b.match.display
        }
        return candidates.prefix(limit - 1).map(\.suggestion) + [search]
    }

    /// The query as the start of a host and path: lowercased, without the scheme and `www.`.
    private static func typedPrefix(_ query: String) -> [UInt8] {
        var typed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for scheme in ["https://", "http://"] where typed.hasPrefix(scheme) { typed.removeFirst(scheme.count) }
        return Array(Suggestion.withoutWWW(typed).utf8)
    }

    /// 1 when the query starts the host (without `www.`) or the host and path, 2 when each word starts a word of the
    /// host, path or title, 3 when each word is in the text in order, which the fuzzy matcher must still accept, and
    /// nil otherwise. Case is ignored.
    private static func tier(of match: MatchText, typed: [UInt8], words: [[UInt8]]) -> Int? {
        guard words.allSatisfy({ isSubsequence($0, of: match.folded) }) else { return nil }
        if match.host.starts(with: typed) { return 1 }
        return words.allSatisfy { startsAWord($0, in: match.folded) } ? 2 : 3
    }

    private static func isSubsequence(_ word: [UInt8], of text: [UInt8]) -> Bool {
        var next = 0
        for byte in text where next < word.count && byte == word[next] { next += 1 }
        return next == word.count
    }

    /// A byte from 0x80 up is part of a character outside ASCII, which counts as a letter.
    private static func startsAWord(_ word: [UInt8], in text: [UInt8]) -> Bool {
        guard !word.isEmpty, word.count <= text.count else { return false }
        func continuesWord(_ byte: UInt8) -> Bool { byte >= 0x80 || (48...57).contains(byte) || (97...122).contains(byte) }
        return (0...(text.count - word.count)).contains { start in
            (start == 0 || !continuesWord(text[start - 1])) && text[start..<(start + word.count)].elementsEqual(word)
        }
    }
}
