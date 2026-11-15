import Foundation

/// What a line typed in the address field, or a URL that a program queues in `@muxify_open`, opens. Plain
/// Foundation, so the app and the CLI turn the same input into the same URL.
public enum Omnibox {
    public static func url(for rawInput: String) -> URL? {
        let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }

        if let url = URL(string: input), let scheme = url.scheme?.lowercased(),
           ["http", "https", "file", "about"].contains(scheme) {
            return url
        }
        if input.hasPrefix("/") || input.hasPrefix("~/") {
            return URL(fileURLWithPath: (input as NSString).expandingTildeInPath)
        }
        if looksLikeHost(input) {
            let local = isLocal(input)
            return URL(string: (local ? "http://" : "https://") + input)
        }
        return searchURL(for: input)
    }

    public static func searchURL(for query: String) -> URL? {
        var components = URLComponents(string: "https://www.google.com/search")!
        components.queryItems = [URLQueryItem(name: "q", value: query.trimmingCharacters(in: .whitespacesAndNewlines))]
        return components.url
    }

    private static func looksLikeHost(_ input: String) -> Bool {
        guard !input.contains(" ") else { return false }
        if isLocal(input) { return true }
        let host = input.split(whereSeparator: { "/:?#".contains($0) }).first.map(String.init) ?? input
        return host.contains(".") && !host.hasPrefix(".") && !host.hasSuffix(".")
    }

    private static func isLocal(_ input: String) -> Bool {
        let host = input.split(whereSeparator: { "/:?#".contains($0) }).first.map { $0.lowercased() } ?? ""
        return host == "localhost" || host == "127.0.0.1" || host == "0.0.0.0" || host == "[::1]"
            || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.hasSuffix(".test")
            || (input.first?.isNumber == true && input.contains(":"))
    }
}

/// The same page for "is this URL already open": ignores the fragment, a trailing slash, and the case of the
/// scheme and host.
public enum TabURL {
    public static func matchKey(_ string: String) -> String {
        guard var components = URLComponents(string: string) else { return string }
        components.fragment = nil
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        var key = components.string ?? string
        while key.hasSuffix("/") { key.removeLast() }
        return key
    }
}

/// Where a URL opened in a Browser goes. The app's Browser follows it for each open, and the CLI follows it
/// to list the Tabs that the app will show for queued opens, so both give the same Tabs.
public enum TabOpening: Equatable {
    /// A Tab already has the page: it becomes the active Tab.
    case activate(Int)
    /// The active Tab is blank: the page loads into it.
    case load(into: Int)
    /// A new Tab at the end, which becomes the active Tab.
    case append

    /// `tabURLs` are the Tabs' URLs, empty for a blank Tab.
    public init(_ url: String, tabURLs: [String], activeTab: Int?) {
        let key = TabURL.matchKey(url)
        if let existing = tabURLs.firstIndex(where: { !$0.isEmpty && TabURL.matchKey($0) == key }) {
            self = .activate(existing)
        } else if let activeTab, tabURLs[activeTab].isEmpty {
            self = .load(into: activeTab)
        } else {
            self = .append
        }
    }
}
