import Foundation

extension TopicRequest {
    /// The muxify://topic transport, for automations that have no shell. Each verb maps onto one request and
    /// names its Pane in `pane`; the URL gives the sender no result. A new verb gets a URL form only when an
    /// automation needs it.
    public init(url: URL) throws {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "muxify", parts.host == "topic", parts.user == nil,
              parts.password == nil, parts.port == nil, parts.fragment == nil,
              !parts.path.isEmpty, parts.path.dropFirst().allSatisfy({ $0 != "/" }),
              let items = parts.queryItems else { throw TopicRequestError.invalidURL }
        var values: [String: String] = [:]
        for item in items {
            guard values[item.name] == nil, let value = item.value, !value.isEmpty else {
                throw TopicRequestError.invalidURL
            }
            values[item.name] = value
        }
        func keys(_ expected: Set<String>) throws {
            guard Set(values.keys) == expected else { throw TopicRequestError.invalidURL }
        }
        func pane(_ value: String?) throws -> TopicTarget {
            guard let id = value.flatMap(PaneID.init(rawValue:)) else { throw TopicRequestError.invalidURL }
            return .pane(id)
        }
        func sessionPath(_ value: String?) throws -> String {
            guard let value, value.hasPrefix("/"), !value.contains("\0"), !value.contains("\n") else {
                throw TopicRequestError.invalidURL
            }
            return value
        }
        switch parts.path {
        case "/new":
            guard Set(values.keys).isSubset(of: ["title", "sessionPath", "pane"]) else { throw TopicRequestError.invalidURL }
            let target = try values["pane"].map { try pane($0) }
            let repositoryPath = try values["sessionPath"].map { try sessionPath($0) }
            let title = values["title"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if title.isEmpty {
                guard values["title"] == nil, let target else { throw TopicRequestError.invalidURL }
                self.init(.extract(sessionPath: repositoryPath), target: target)
            } else if let repositoryPath {
                self.init(.create(title: title, sessionPath: repositoryPath))
            } else if let target {
                self.init(.create(title: title, sessionPath: nil), target: target)
            } else { throw TopicRequestError.invalidURL }
        case "/add":
            try keys(["pane", "sessionPath"])
            self.init(.addSession(sessionPath: try sessionPath(values["sessionPath"]), workingCopy: .directory), target: try pane(values["pane"]))
        case "/settle":
            try keys(["pane"])
            self.init(.settle(choices: [], outcome: ""), target: try pane(values["pane"]))
        case "/forget":
            if Set(values.keys) == ["topic"] {
                self.init(.forget(choices: [], worktrees: []), target: .topic(.named(values["topic"]!)))
            } else {
                try keys(["pane"])
                self.init(.forget(choices: [], worktrees: []), target: try pane(values["pane"]))
            }
        case "/lock", "/unlock":
            try keys(["session"])
            guard let name = values["session"], !name.isEmpty else { throw TopicRequestError.invalidURL }
            self.init(parts.path == "/lock" ? .lock : .unlock, target: .sessionName(name))
        case "/move":
            try keys(["pane", "topic"])
            self.init(.move(to: .topic(.named(values["topic"]!))), target: try pane(values["pane"]))
        default:
            throw TopicRequestError.invalidURL
        }
    }
}
