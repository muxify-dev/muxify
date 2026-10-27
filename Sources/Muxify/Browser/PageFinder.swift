import WebKit

/// Find in Page across every frame of one Tab's page, so text in an iframe
/// counts as the page's own. The script in each frame finds and highlights its
/// own matches; this puts the frames in one order and steps through all their
/// matches as one list.
@MainActor
final class PageFinder {
    private struct Frame {
        let info: WKFrameInfo
        /// The id the frame's script drew when its document loaded.
        let document: String
        var count = 0
    }

    private struct Position {
        var document: String
        var match: Int
    }

    private enum Search {
        case replaced
        case notFound
        case found(Position)
    }

    private weak var webView: WKWebView?
    /// The main frame first, then the other frames in the order they loaded.
    private var frames: [Frame] = []
    private var query = ""
    private var current: Position?
    /// Only the newest call may change the state after it waits for a frame.
    private var generation = 0

    nonisolated init(webView: WKWebView) {
        self.webView = webView
    }

    func register(_ info: WKFrameInfo, document: String) {
        frames.removeAll { $0.document == document }
        let frame = Frame(info: info, document: document)
        if info.isMainFrame { frames.insert(frame, at: 0) } else { frames.append(frame) }
    }

    /// The main frame committed a new page; its frames register as they load.
    func reset() {
        generation += 1
        frames = []
        query = ""
        current = nil
    }

    /// Returns nil when a later call has replaced this one. Step 0 shows the
    /// current match again. A new query, or matches the page removed, starts a
    /// new search in the frame the user last clicked, scrolled or typed in, else
    /// in the frame that shows the most of the page, at its first match at or
    /// below the top of its viewport.
    func find(_ query: String, step: Int) async -> FindStatus? {
        generation += 1
        let generation = generation
        guard !query.isEmpty else {
            clear()
            return .idle
        }
        if query == self.query, let current, let next = position(after: current, step: step) {
            if next.document != current.document { call("deselect", in: current.document) }
            let selected = await select(next)
            guard generation == self.generation else { return nil }
            if selected {
                self.current = next
                return status
            }
        }
        switch await search(query, generation: generation) {
        case .replaced:
            return nil
        case .notFound:
            return .notFound
        case let .found(start):
            guard await select(start), generation == self.generation else { return nil }
            current = start
            return status
        }
    }

    func clear() {
        generation += 1
        query = ""
        current = nil
        for frame in frames { call("clear", in: frame.document) }
    }

    private var total: Int { frames.reduce(0) { $0 + $1.count } }

    private func offset(of position: Position) -> Int? {
        guard let frame = frames.firstIndex(where: { $0.document == position.document }) else { return nil }
        return frames[..<frame].reduce(0) { $0 + $1.count } + position.match
    }

    private var status: FindStatus {
        guard let current, let index = offset(of: current) else { return .notFound }
        return .match(index: index, total: total)
    }

    private func position(after current: Position, step: Int) -> Position? {
        guard total > 0, var index = offset(of: current) else { return nil }
        index = ((index + step) % total + total) % total
        for frame in frames {
            if index < frame.count { return Position(document: frame.document, match: index) }
            index -= frame.count
        }
        return nil
    }

    /// Searches every frame, and drops a frame that is gone or holds another
    /// document now.
    private func search(_ query: String, generation: Int) async -> Search {
        self.query = query
        current = nil
        var replies: [String: (count: Int, start: Int, activeAt: Double, area: Double)] = [:]
        for frame in frames {
            let reply = await evaluate("return globalThis.muxifyFind?.search(id, query) ?? null",
                                       in: frame, arguments: ["query": query]) as? [String: Any]
            guard generation == self.generation else { return .replaced }
            guard let reply else { continue }
            replies[frame.document] = ((reply["count"] as? NSNumber)?.intValue ?? 0,
                                       (reply["start"] as? NSNumber)?.intValue ?? 0,
                                       (reply["activeAt"] as? NSNumber)?.doubleValue ?? 0,
                                       (reply["area"] as? NSNumber)?.doubleValue ?? 0)
        }
        frames.removeAll { replies[$0.document] == nil }
        for index in frames.indices { frames[index].count = replies[frames[index].document]?.count ?? 0 }
        let active = frames.indices.max {
            let (a, b) = (replies[frames[$0].document]!, replies[frames[$1].document]!)
            return (a.activeAt, a.area) < (b.activeAt, b.area)
        } ?? 0
        let order = frames.indices.map { (active + $0) % frames.count }
        guard let first = order.first(where: { frames[$0].count > 0 }) else { return .notFound }
        let document = frames[first].document
        return .found(Position(document: document, match: first == active ? replies[document]!.start : 0))
    }

    private func select(_ position: Position) async -> Bool {
        guard let frame = frames.first(where: { $0.document == position.document }) else { return false }
        return await evaluate("return globalThis.muxifyFind?.select(id, index) ?? false",
                              in: frame, arguments: ["index": position.match]) as? Bool ?? false
    }

    private func evaluate(_ body: String, in frame: Frame, arguments: [String: Any]) async -> Any? {
        guard let webView else { return nil }
        var arguments = arguments
        arguments["id"] = frame.document
        return try? await webView.callAsyncJavaScript(body, arguments: arguments, in: frame.info,
                                                      contentWorld: BrowserPageScripts.world)
    }

    private func call(_ function: String, in document: String) {
        guard let frame = frames.first(where: { $0.document == document }) else { return }
        webView?.callAsyncJavaScript("globalThis.muxifyFind?.\(function)()", arguments: [:], in: frame.info,
                                     in: BrowserPageScripts.world) { _ in }
    }
}
