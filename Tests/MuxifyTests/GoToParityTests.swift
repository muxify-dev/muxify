import XCTest
@testable import MuxifyCore
import MuxifyTestSupport

final class GoToParityTests: XCTestCase {
    private final class Server: TmuxRunning, @unchecked Sendable {
        let windows: [TmuxWindow]
        init(windows: [TmuxWindow]) { self.windows = windows }
        func run(_ arguments: [String]) throws -> String { "" }
        func snapshot() throws -> TmuxSnapshot { TmuxSnapshot(windows: windows, clients: [], panes: [], serverRunning: true) }
    }

    private let now = Date(timeIntervalSince1970: 12 * 3600)

    private func hostPaths() throws -> MuxifyPaths {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("muxify-go-to-parity-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return MuxifyPaths(environment: ["XDG_STATE_HOME": root.path], home: "/nonexistent")
    }

    private struct Listed: Equatable {
        var sections: [String]
        var rows: [[String]]
    }

    private func lists(records: [TopicRecord] = [], windows: [TmuxWindow], selected: TmuxWindow, sessionPaths: [SessionPath],
                       visits: [VisitKey: Date], config: Config = Config(), query: String, palette: CommandPaletteConfig) throws
        -> (mac: Listed, host: Listed) {
        let paths = try hostPaths()
        try TopicStore(paths: paths).write { transaction in try records.forEach { try transaction.create($0) } }
        try VisitStore(paths: paths).add(visits)
        let stored = try TopicStore(paths: paths).read().records

        var selection = TopicSelection()
        selection.windowID = selected.id
        let model = BoardModel(records: stored, windows: windows, config: config, selection: selection, location: selection.windowLocation)
        let catalog = PaletteCatalog(windows: windows, agents: [], sessionPaths: sessionPaths, selectedWindowID: selected.id, homeDirectory: "/home",
                                     board: model, records: stored, visits: VisitLog(times: visits), now: now)
        let mac = catalog.list(palette.sources, query: query, rules: palette.rules, order: palette.order)

        let service = EnvironmentService(paths: paths, server: Server(windows: windows), sessionPaths: sessionPaths, topics: config.topics,
                                         notifications: config.notifications)
        let host = try service.goTo(GoToRequest(query: query, currentSession: selected.sessionName), palette: palette,
                                    offersTopics: config.sidebar.board, home: "/home", now: now).get()
        return (Listed(sections: mac.sections.map { "\($0.id) \($0.title ?? "-")" },
                       rows: mac.rows.map { [$0.id, $0.kind.rawValue, $0.title.text, $0.detail.text, $0.trailing, $0.mark?.rawValue ?? ""] }),
                Listed(sections: host.sections.map { "\($0.id) \($0.title ?? "-")" },
                       rows: host.rows.map { [$0.id, $0.kind, $0.title.text, $0.detail.text, $0.trailing, $0.mark?.rawValue ?? ""] }))
    }

    private func window(_ id: String, _ session: String, topic: String? = nil, activity: Int = 0) -> TmuxWindow {
        .fixture(id: id, sessionID: "$" + session, sessionName: session, path: "/code/" + session, sessionActivity: activity, topicID: topic,
                 sessionPath: "/code/" + session)
    }

    private func hours(_ stamps: [VisitKey: Double]) -> [VisitKey: Date] { stamps.mapValues { Date(timeIntervalSince1970: $0 * 3600) } }

    func testSessionsAndSessionPathsRankTheSameInTheAppAndInTheHostsAnswer() throws {
        let windows = [window("@1", "api"), window("@2", "muxify"), window("@3", "web")]
        let sessionPaths = ["api", "music", "muxify", "notes"].map { SessionPath(path: "/code/" + $0, name: $0) }
        let visits = hours([.session(name: "api"): 11, .session(name: "web"): 10, .session(name: "muxify"): 9,
                            .directory("/code/notes"): 8, .directory("/code/music"): 7])
        let expected = ["": ["web", "muxify", "api", "notes", "music"], "mu": ["music", "muxify"], "mu fy": ["muxify"]]
        for (query, titles) in expected {
            let (mac, host) = try lists(windows: windows, selected: windows[0], sessionPaths: sessionPaths, visits: visits, query: query,
                                        palette: .goTo)
            XCTAssertEqual(mac.rows.map { $0[2] }, titles, "the Mac's order for \(query.debugDescription)")
            XCTAssertEqual(host, mac, "the Host's answer for \(query.debugDescription)")
        }
    }

    func testTopicsSettledTopicsTagsAndTheRulesOfThePaletteRankTheSameInTheAppAndInTheHostsAnswer() throws {
        let backend = try XCTUnwrap(Tag(name: "backend"))
        var config = Config()
        config.topics.tags = ConfigTags([TagDefinition(tag: backend)])
        var ship = TopicRecord(id: "ship", title: "Ship the muxify release")
        ship.tags = [backend]
        ship.note = "before Friday"
        var dormant = TopicRecord(id: "music", title: "Music player")
        dormant.sessions = [.object(["id": .string("saved"), "name": .string("music/music"), "base_name": .string("music"),
                                     "directory": .string("/code/music")])]
        var settled = TopicRecord(id: "old", title: "Old muxify notes")
        settled.settledAt = "2026-01-01T00:00:00Z"
        settled.tags = [backend]
        let windows = [window("@1", "api/ship", topic: "ship", activity: 5), window("@2", "muxify", activity: 9), window("@3", "web", activity: 2),
                       window("@4", "kept", topic: "old")]
        let sessionPaths = ["api", "music", "muxify", "notes"].map { SessionPath(path: "/code/" + $0, name: $0) }
        let visits = hours([.topic(.topic("ship")): 11, .session(name: "api/ship"): 11, .session(name: "web"): 10, .topic(.noTopic): 10,
                            .session(name: "muxify"): 9, .directory("/code/notes"): 8, .topic(.topic("music")): 7, .topic(.topic("old")): 6])
        let narrowed = CommandPaletteConfig(name: "Go to…", triggers: [], sources: [.topics, .sessions], order: .ranked,
                                            rules: PickRules(show: [.topic, .settled, .session, .sessionPath, .tag], tiebreak: [.open, .visit, .length]))
        for palette in [CommandPaletteConfig.goTo, narrowed] {
            for query in ["", "mu", "muxify", "#back", "notes", "dormant", "zzz"] {
                for selected in [windows[0], windows[1]] {
                    let (mac, host) = try lists(records: [ship, dormant, settled], windows: windows, selected: selected, sessionPaths: sessionPaths,
                                                visits: visits, config: config, query: query, palette: palette)
                    XCTAssertEqual(host, mac, "\(palette.order) for \(query.debugDescription) from \(selected.sessionName)")
                    XCTAssertEqual(mac.rows.isEmpty, query == "zzz", "\(palette.order) for \(query.debugDescription)")
                }
            }
        }
    }
}
