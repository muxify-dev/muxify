import Foundation

/// The main thread of a `sample` file, folded into what an agent reads first: how busy the thread was, and where
/// that time went by library, by symbol and by the app's own frames. The app writes it into the Diagnostics log as
/// three `digest` records after each sample, so it outlives the raw file.
///
/// A sample's call graph gives each frame the number of samples that passed through it, its children indented below
/// it. A frame's self time is its count less its immediate children's. The run loop's wait,
/// `__CFRunLoopServiceMachPort` and everything under it, is idle; every other sample is busy. The shares of
/// libraries, symbols and app frames are of the busy samples, so the wait does not drown them.
public struct SampleDigest: Equatable, Sendable {
    public struct Share: Equatable, Sendable {
        public let name: String
        /// The library of a symbol; nil for a library's own share and for an app frame.
        public let library: String?
        /// Of the busy samples, in %.
        public let percent: Double
    }

    public static let topLibraries = 8
    public static let topSymbols = 15
    public static let topFrames = 15
    /// The longest a symbol's name gets in a record.
    public static let symbolLength = 80
    /// The frame whose samples are the main run loop waiting.
    static let idleFrame = "__CFRunLoopServiceMachPort"

    /// Every sample of the main thread.
    public let samples: Int
    /// The samples not in the run loop's wait.
    public let busySamples: Int
    /// The libraries by self time, the highest first.
    public let libraries: [Share]
    /// The symbols by self time, each with its library, the highest first.
    public let symbols: [Share]
    /// The frames from the app binary by inclusive time, the highest first. A frame that recurs on one stack path
    /// counts once, at its outermost call.
    public let frames: [Share]

    /// The busy samples' share of all, in %.
    public var busy: Double {
        samples == 0 ? 0 : Double(busySamples) * 100 / Double(samples)
    }

    /// The digest of the main thread in `text`, a `sample` file. Nil when it has no main thread.
    public init?(sample text: String) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let header = lines.firstIndex(where: Self.isMainThread), let total = Self.row(lines[header], symbol: false)
        else { return nil }
        let app = Self.binary(in: lines)
        var fold = Fold(isApp: { library in app.map { library == $0 || library.hasPrefix($0 + ".") } ?? false })
        for line in lines[(header + 1)...] {
            // The next thread, or the end of the call graph.
            guard line.hasPrefix("    "), !Self.isThread(line) else { break }
            guard let row = Self.row(line, symbol: true) else { continue }
            fold.add(row)
        }
        fold.finish()
        let busy = max(0, total.count - fold.idle)
        samples = total.count
        busySamples = busy
        func ranked<Key: Hashable>(_ counts: [Key: Int], top: Int, _ share: (Key, Double) -> Share) -> [Share] {
            counts.filter { $0.value > 0 }
                .map { (key: $0.key, count: $0.value) }
                .sorted { $0.count != $1.count ? $0.count > $1.count : "\($0.key)" < "\($1.key)" }
                .prefix(top)
                .map { share($0.key, busy == 0 ? 0 : Double($0.count) * 100 / Double(busy)) }
        }
        libraries = ranked(fold.libraries, top: Self.topLibraries) { Share(name: $0, library: nil, percent: $1) }
        symbols = ranked(fold.symbols, top: Self.topSymbols) { Share(name: $0.symbol, library: $0.library, percent: $1) }
        frames = ranked(fold.frames, top: Self.topFrames) { Share(name: $0.symbol, library: nil, percent: $1) }
    }

    /// The three `digest` records of the sample in `file`, a name in the Diagnostics folder:
    /// - `samples`, `busy` (in %) and `libraries`, as `library:%` pairs;
    /// - `symbols`, as `symbol@library:%` pairs;
    /// - `frames`, as `symbol:%` pairs.
    ///
    /// A pair splits at its last `:`, and a symbol at its last `@`. Symbol names are shortened (`short`). An empty
    /// list is `none`.
    public func records(file: String) -> [DiagnosticsRecord] {
        func pairs(_ shares: [Share]) -> String {
            shares.isEmpty ? "none" : DiagnosticsRecord.pairs(shares.map { share in
                let name = share.library == nil ? Self.short(share.name) : "\(Self.short(share.name))@\(share.library!)"
                return (name, DiagnosticsRecord.decimal(share.percent))
            })
        }
        return [
            DiagnosticsRecord(.digest, [("sample", file), ("samples", String(samples)),
                                        ("busy", DiagnosticsRecord.decimal(busy)), ("libraries", pairs(libraries))]),
            DiagnosticsRecord(.digest, [("sample", file), ("symbols", pairs(symbols))]),
            DiagnosticsRecord(.digest, [("sample", file), ("frames", pairs(frames))]),
        ]
    }

    /// `symbol` as one short word: a parenthesized or angle-bracketed part that holds a space, a comma or a bracket
    /// of its own becomes `(...)` or `<...>`, every run of whitespace becomes `_`, a comma left over becomes `;`, and a name longer than
    /// `symbolLength` is cut to end in `...`. `dispatch_items(unsigned long long, unsigned long long)` becomes
    /// `dispatch_items(...)`; `forEachItem(from:style:do:)` stays as it is.
    public static func short(_ symbol: String) -> String {
        let pairs: [Character: Character] = ["(": ")", "<": ">"]
        var text = ""
        var index = symbol.startIndex
        while index < symbol.endIndex {
            let character = symbol[index]
            guard let close = pairs[character], let end = closing(symbol, from: index) else {
                text.append(character)
                index = symbol.index(after: index)
                continue
            }
            let inside = symbol[symbol.index(after: index)..<end]
            text.append(character)
            text += inside.contains(where: { ",()<>".contains($0) || $0.isWhitespace }) ? "..." : String(inside)
            text.append(close)
            index = symbol.index(after: end)
        }
        let words = text.split(whereSeparator: \.isWhitespace).joined(separator: "_")
            .replacingOccurrences(of: ",", with: ";")
        return words.count > symbolLength ? String(words.prefix(symbolLength - 3)) + "..." : words
    }

    // MARK: Folding

    private struct Symbol: Hashable, CustomStringConvertible {
        let symbol: String
        let library: String
        var description: String { "\(symbol) \(library)" }
    }

    private struct Row {
        let depth: Int
        let count: Int
        let symbol: Symbol
    }

    /// Walks the main thread's rows in order, keeping the path from the root to the row it reads.
    private struct Fold {
        private struct Frame {
            let row: Row
            let idle: Bool
            var children = 0
            var idleWithin = 0
        }

        let isApp: (String) -> Bool
        private var path: [Frame] = []
        private var onPath: [Symbol: Int] = [:]
        private(set) var idle = 0
        private(set) var libraries: [String: Int] = [:]
        private(set) var symbols: [Symbol: Int] = [:]
        private(set) var frames: [Symbol: Int] = [:]

        init(isApp: @escaping (String) -> Bool) {
            self.isApp = isApp
        }

        mutating func add(_ row: Row) {
            while let last = path.last, last.row.depth >= row.depth { pop() }
            let inIdle = path.last?.idle ?? false
            let idle = inIdle || row.symbol.symbol == SampleDigest.idleFrame
            if !path.isEmpty { path[path.count - 1].children += row.count }
            if idle, !inIdle { self.idle += row.count }
            path.append(Frame(row: row, idle: idle))
            onPath[row.symbol, default: 0] += 1
        }

        mutating func finish() {
            while !path.isEmpty { pop() }
        }

        private mutating func pop() {
            let frame = path.removeLast()
            let symbol = frame.row.symbol
            onPath[symbol, default: 1] -= 1
            if !path.isEmpty {
                path[path.count - 1].idleWithin += frame.idle ? frame.row.count : frame.idleWithin
            }
            guard !frame.idle else { return }
            let own = frame.row.count - frame.children
            if own > 0 {
                symbols[symbol, default: 0] += own
                libraries[symbol.library, default: 0] += own
            }
            if isApp(symbol.library), onPath[symbol, default: 0] == 0 {
                frames[symbol, default: 0] += frame.row.count - frame.idleWithin
            }
        }
    }

    // MARK: Parsing

    private static func isThread(_ line: Substring) -> Bool {
        let rest = line.dropFirst(4)
        guard line.hasPrefix("    "), rest.first?.isNumber == true else { return false }
        return rest.drop(while: \.isNumber).hasPrefix(" Thread_")
    }

    private static func isMainThread(_ line: Substring) -> Bool {
        isThread(line) && (line.contains("Main Thread") || line.contains("com.apple.main-thread"))
    }

    /// The app binary's name, from the header's `Process:  MuxifyApp [62313]`.
    private static func binary(in lines: [Substring]) -> String? {
        guard let line = lines.prefix(40).first(where: { $0.hasPrefix("Process:") }) else { return nil }
        return line.dropFirst("Process:".count).split(separator: " ").first.map(String.init)
    }

    /// A call-graph line: its indent of ` +!:|`, its count, then `symbol  (in library) + offset  [address]`. With
    /// `symbol` false, any line with an indent and a count, such as a thread's.
    private static func row(_ line: Substring, symbol: Bool) -> Row? {
        let indent = line.prefix(while: { " +!:|".contains($0) })
        let digits = line[indent.endIndex...].prefix(while: \.isNumber)
        guard !digits.isEmpty, let count = Int(digits) else { return nil }
        let rest = line[digits.endIndex...]
        guard rest.first == " " else { return nil }
        guard symbol else { return Row(depth: indent.count, count: count, symbol: Symbol(symbol: "", library: "")) }
        guard let open = rest.range(of: " (in "), let close = rest[open.upperBound...].firstIndex(of: ")") else { return nil }
        let name = rest[..<open.lowerBound].trimmingCharacters(in: .whitespaces)
        let library = String(rest[open.upperBound..<close])
        return Row(depth: indent.count, count: count, symbol: Symbol(symbol: name, library: library))
    }

    /// The index of the bracket that closes the one at `open`, counting both kinds; nil when it never closes.
    private static func closing(_ text: String, from open: String.Index) -> String.Index? {
        var depth = 0
        var index = open
        while index < text.endIndex {
            switch text[index] {
            case "(", "<": depth += 1
            case ")", ">":
                depth -= 1
                if depth == 0 { return index }
            default: break
            }
            index = text.index(after: index)
        }
        return nil
    }
}

/// Which raw sample files the Diagnostics folder keeps: the `freeze-`, `burst-` and leftover `cpu-` files of the
/// last `maxAge`, and within those no more than `maxBytes` in all, the newest first.
public enum SampleRetention {
    public static let maxAge: TimeInterval = 3 * 24 * 3600
    public static let maxBytes: Int64 = 300 << 20
    public static let prefixes = ["freeze-", "burst-", "cpu-"]

    public struct File: Equatable, Sendable {
        public let name: String
        public let modified: Date
        public let bytes: Int64

        public init(name: String, modified: Date, bytes: Int64) {
            self.name = name
            self.modified = modified
            self.bytes = bytes
        }
    }

    /// Whether `name` is a raw sample file.
    public static func isSample(_ name: String) -> Bool {
        name.hasSuffix(".txt") && prefixes.contains { name.hasPrefix($0) }
    }

    /// The names of the sample files among `files` to delete at `now`, the oldest first. Other files are kept.
    public static func doomed(_ files: [File], now: Date, maxAge: TimeInterval = maxAge, maxBytes: Int64 = maxBytes) -> [String] {
        var total: Int64 = 0
        var doomed: [String] = []
        for file in files.filter({ isSample($0.name) }).sorted(by: { $0.modified > $1.modified }) {
            total += file.bytes
            if now.timeIntervalSince(file.modified) > maxAge || total > maxBytes { doomed.append(file.name) }
        }
        return doomed.reversed()
    }
}
