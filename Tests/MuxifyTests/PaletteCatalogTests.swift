import XCTest
@testable import MuxifyCore
import MuxifyTestSupport

final class PaletteCatalogTests: XCTestCase {
    private let game = SessionPath(path: "/work/game", name: "game",
                               layout: .bareRepository([Worktree(path: "/work/game/main", branch: "main"),
                                                        Worktree(path: "/work/game/release", branch: "release")]))
    private let notes = SessionPath(path: "/work/notes", name: "notes")
    private let now = Date(timeIntervalSince1970: 10_000)

    private func window(_ id: String, session: String, directory: String, topic: String? = nil, active: Bool = true,
                        activity: Int = 0) -> TmuxWindow {
        .fixture(id: id, sessionID: "$" + session, sessionName: session, path: directory, isActive: active, sessionActivity: activity,
                 topicID: topic, sessionPath: directory)
    }

    /// A Topic whose Session is remembered in the main Worktree of game, as the app remembers it.
    private func topic(_ id: String, _ title: String) -> TopicRecord {
        var record = TopicRecord(id: id, title: title)
        record.sessions = [.object(["id": .string("saved:" + id), "name": .string("game/" + id),
                                   "base_name": .string("game"), "directory": .string("/work/game/main")])]
        return record
    }

    private func catalog(records: [TopicRecord], windows: [TmuxWindow], selected: String? = nil, visits: VisitLog = VisitLog(),
                         lastWindow: [TopicGroupID: String] = [:], agents: [Agent] = [],
                         mode: SidebarMode = .board, sessionPaths: [SessionPath]? = nil) -> PaletteCatalog {
        var config = Config()
        config.sessionPaths = sessionPaths ?? [game, notes]
        var selection = TopicSelection()
        selection.windowID = selected
        let model = BoardModel(records: records, windows: windows, config: config, selection: selection,
                        location: selection.windowLocation, mode: mode,
                                agents: agents)
        return PaletteCatalog(windows: windows, agents: agents, sessionPaths: config.sessionPaths, selectedWindowID: selected,
                              homeDirectory: "/home", board: model, records: records, lastWindowByGroup: lastWindow,
                              visits: visits, now: now, agentMarks: model.agentMarks)
    }

    private func visits(_ stamps: [(VisitKey, TimeInterval)]) -> VisitLog {
        var log = VisitLog()
        for (key, seconds) in stamps {
            let window = window("@v", session: { if case .session(let name) = key { return name }; return "v" }(),
                                directory: { if case .directory(let path) = key { return path }; return "/elsewhere" }())
            let group: TopicGroupID = { if case .topic(let group) = key { return group }; return .noTopic }()
            _ = log.record(window, group: group, sessionPaths: [game, notes], folders: .local, at: Date(timeIntervalSince1970: seconds))
        }
        return log
    }

    private func ids(_ list: PickList<PaletteItem>) -> [String] { list.rows.map(\.id) }
    private let goTo: [PaletteSource] = [.topics, .sessions]

    func testAddSessionRanksBothKindsInOneSectionByScore() {
        let running = window("@1", session: "a-long-plain-title", directory: "/beta")
        let own = window("@2", session: "alpha/target", directory: "/alpha", topic: "target")
        let paths = [SessionPath(path: "/alpha", name: "alpha"), SessionPath(path: "/beta", name: "beta")]
        let rows = SessionPathRows.build(sessionPaths: paths, windows: [running, own], records: [])
        let catalog = PaletteCatalog(windows: [running, own], agents: [], sessionPaths: paths, now: now)
        let empty = catalog.addSessionList(topic: "target", query: "", rows: rows, rules: .standard)
        XCTAssertEqual(empty.sections.count, 1)
        XCTAssertNil(empty.sections.first?.title)
        XCTAssertEqual(empty.rows.first?.id, "running-$a-long-plain-title")
        XCTAssertEqual(empty.rows.map(\.symbol), ["■", "□", "□"])
        let typed = catalog.addSessionList(topic: "target", query: "alp", rows: rows, rules: .standard)
        XCTAssertEqual(typed.rows.map(\.id), ["/alpha", "running-$a-long-plain-title"])
    }

    func testAddSessionKeepsAlsoInOtherTopics() {
        let running = window("@1", session: "debug", directory: "/work/game/main/src")
        let records = [topic("target", "Target"), topic("other", "Other")]
        let windows = [running, window("@2", session: "own", directory: "/work/game/main", topic: "target"),
                       window("@3", session: "other", directory: "/work/game/main", topic: "other")]
        let rows = SessionPathRows.build(sessionPaths: [game, notes], windows: windows, records: records)
        let catalog = PaletteCatalog(windows: [running], agents: [], sessionPaths: [game, notes], now: now)
        let list = catalog.addSessionList(topic: "target", query: "", rows: rows, rules: .standard)
        XCTAssertEqual(Array(list.rows.prefix(2).map(\.id)), ["running-$debug", "/work/game/main"])
        let main = list.rows.first { $0.id == "/work/game/main" }
        XCTAssertTrue(main?.detail.text.contains("Other") == true)
        XCTAssertFalse(main?.detail.text.contains("Target") == true)
    }

    func testAddSessionBreaksEqualScoresByVisitThenActivityAcrossBothKinds() {
        let path = SessionPath(path: "/work/game", name: "game")
        let running = window("@1", session: "game", directory: "/elsewhere", activity: 100)
        let rows = SessionPathRows.build(sessionPaths: [path], windows: [], records: [])
        var visits = VisitLog()
        _ = visits.record(running, group: .noTopic, sessionPaths: [path], folders: .local, at: now)
        _ = visits.record(window("@2", session: "visitor", directory: path.folder.path), group: .noTopic,
                          sessionPaths: [path], folders: .local, at: now.addingTimeInterval(1))
        var catalog = PaletteCatalog(windows: [running], agents: [], sessionPaths: [path], visits: visits, now: now)
        for query in ["", "game"] {
            XCTAssertEqual(catalog.addSessionList(topic: "target", query: query, rows: rows, rules: .standard).rows.first?.id,
                           path.folder.real)
        }
        catalog.visits = VisitLog()
        XCTAssertEqual(catalog.addSessionList(topic: "target", query: "game", rows: rows, rules: .standard).rows.first?.id,
                       "running-$game")
    }

    func testAddSessionPathsUseLastVisitThenConfigOrderAndMatchDirectory() {
        let paths = ["alpha", "bravo", "charlie", "delta"].map { SessionPath(path: "/" + $0, name: $0) }
        let rows = SessionPathRows.build(sessionPaths: paths, windows: [], records: [])
        var visits = VisitLog()
        _ = visits.record(window("@1", session: "b", directory: "/bravo"), group: .noTopic, sessionPaths: paths,
                          folders: .local, at: Date(timeIntervalSince1970: 10))
        _ = visits.record(window("@2", session: "c", directory: "/charlie"), group: .noTopic, sessionPaths: paths,
                          folders: .local, at: Date(timeIntervalSince1970: 20))
        var catalog = PaletteCatalog(windows: [], agents: [], sessionPaths: paths, visits: visits)
        func order(_ query: String) -> [String] {
            catalog.addSessionList(topic: "target", query: query, rows: rows, rules: .standard).rows.map(\.title.text)
        }
        XCTAssertEqual(order(""), ["charlie", "bravo", "alpha", "delta"])
        XCTAssertEqual(order("alp"), ["alpha"])
        XCTAssertTrue(order("unmatched").isEmpty)
        XCTAssertEqual(order("brv"), ["bravo"])
        catalog.visits = VisitLog()
        XCTAssertEqual(order(""), ["alpha", "bravo", "charlie", "delta"])
        let path = SessionPath(path: "/work/game", name: "game")
        let directoryRows = SessionPathRows.build(sessionPaths: [path], windows: [], records: [])
        let matched = catalog.addSessionList(topic: "target", query: "work", rows: directoryRows, rules: .standard)
        XCTAssertEqual(matched.rows.first?.detail, Highlighted(text: "/work/game", marks: [1, 2, 3, 4]))
    }

    func testAGoToRowActsOnItsTopicsEntryWindowItsSessionOrItsFolder() {
        var settled = topic("s", "Settled")
        settled.settledAt = "2026-01-01T00:00:00Z"
        let records = [topic("a", "Alpha"), topic("c", "Charlie"), settled]
        let windows = [window("@1", session: "game/alpha", directory: "/work/game/main", topic: "a"),
                       window("@2", session: "game/alpha", directory: "/work/game/main", topic: "a", active: false),
                       window("@3", session: "scratch", directory: "/tmp/scratch")]
        let list = catalog(records: records, windows: windows, lastWindow: [.topic("a"): "@2"]).list(goTo, query: "", rules: .standard)
        func item(_ id: String) -> PaletteItem? { list.rows.first { $0.id == id }?.pick.payload }
        XCTAssertEqual(item("topic-a")?.ref, .topic(id: "a", window: windows[1]), "the Window that the App Window showed last in the Topic")
        XCTAssertEqual(item("topic-c")?.ref, .topic(id: "c", window: nil), "a Dormant Topic has no Window to show")
        XCTAssertEqual(item("topic-s")?.ref, .topic(id: "s", window: nil))
        XCTAssertEqual(item("session:$scratch"),
                       PaletteItem(ref: .session(SessionGroup(id: "$scratch", name: "scratch", windows: [windows[2]])), path: "/tmp/scratch",
                                   target: "scratch"))
        XCTAssertEqual(item("session-path:/work/notes"),
                       PaletteItem(ref: .sessionPath(OpenDirectory(directory: .local("/work/notes"), name: "notes")), path: "/work/notes"))
    }

    func testEveryRunningSessionHasItsOwnRowInBothModesAndDifferentNamesDoNotOccupyPaths() {
        let records = [topic("a", "Alpha")]
        let windows = [window("@1", session: "game/alpha", directory: "/work/game/main", topic: "a"),
                       window("@2", session: "notes-2", directory: "/work/notes"),
                       window("@3", session: "scratch", directory: "/tmp/scratch")]
        for mode in [SidebarMode.board, .sessions] {
            let catalog = catalog(records: records, windows: windows, mode: mode)
            XCTAssertEqual(Set(ids(catalog.list([.sessions], query: "", rules: .standard))), ["session-path:/work/notes", "session:$scratch", "session:$notes-2", "session:$game/alpha",
                "session-path:/work/game/main", "session-path:/work/game/release"])
            XCTAssertEqual(ids(catalog.list([.sessions], query: "notes-2", rules: .standard)), ["session:$notes-2"])
        }
    }

    func testRowsWithAFolderPasteIt() {
        var settled = topic("s", "Settled")
        settled.settledAt = "2026-01-01T00:00:00Z"
        let records = [topic("a", "Alpha"), topic("d", "Dormant"), settled]
        let windows = [window("@1", session: "game/alpha", directory: "/work/game/main", topic: "a"),
                       window("@2", session: "scratch", directory: "/elsewhere/my notes")]
        let rows = catalog(records: records, windows: windows).sections(goTo + [.windows]).flatMap(\.candidates)
        let pastes = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.paste) })
        XCTAssertEqual(pastes["topic-a"], .some(nil), "a Topic pastes nothing")
        XCTAssertEqual(pastes["session:$scratch"], "/elsewhere/my notes", "the path stays raw until a terminal gets it")
        XCTAssertEqual(pastes["session-path:/work/notes"], "/work/notes")
        XCTAssertEqual(pastes["window:@1"], "/work/game/main")
    }

    func testAPastedPathIsQuotedOnlyWhenTheShellWouldSplitOrExpandIt() {
        XCTAssertEqual(PaletteCatalog.shellWord("/work/game_server.git"), "/work/game_server.git")
        XCTAssertEqual(PaletteCatalog.shellWord("/work/my notes"), "'/work/my notes'")
        XCTAssertEqual(PaletteCatalog.shellWord("/work/it's"), #"'/work/it'"'"'s'"#, "the quoting fish also reads")
        XCTAssertEqual(PaletteCatalog.shellWord("/work/$HOME*"), "'/work/$HOME*'")
    }

    func testAddSessionListsWorktreesAsWorktreesAndOnlyTheKindsItsRulesShow() {
        let forge = SessionPath(path: "/work/forge", name: "forge",
                                layout: .bareRepository([Worktree(path: "/work/forge/main", branch: "main"),
                                                         Worktree(path: "/work/trees/forge-fix", branch: "fix")]))
        let windows = [window("@1", session: "loose", directory: "/beta"),
                       window("@2", session: "game/other", directory: "/work/game/main", topic: "other")]
        let rows = SessionPathRows.build(sessionPaths: [forge, notes], windows: [], records: [])
        let catalog = catalog(records: [topic("other", "Other")], windows: windows, sessionPaths: [forge, notes])
        let all = catalog.addSessionList(topic: "target", query: "", rows: rows, rules: .standard)
        XCTAssertEqual(Set(all.rows.map(\.kind)), [.session, .topicSession, .worktree, .sessionPath], "\(all.rows.map { ($0.id, $0.kind) })")
        let folders = catalog.addSessionList(topic: "target", query: "", rows: rows, rules: PickRules(show: [.sessionPath]))
        XCTAssertEqual(Set(folders.rows.map(\.id)), ["/work/forge/main", "/work/notes"], "no running Session and no Worktree")
    }

    /// A list whose `show` names every kind it can show lists what it lists with no entry, so its builder makes no row
    /// that `show` could not name.
    private func assertShowsOnlyItsKinds(_ list: ActionList, _ build: (PickRules) -> PickList<PaletteItem>,
                                         file: StaticString = #filePath, line: UInt = #line) {
        let built = build(.standard)
        XCTAssertFalse(built.rows.isEmpty, "\(list) has no rows to check", file: file, line: line)
        XCTAssertEqual(build(PickRules(show: list.kinds)), built, "\(list) makes a ranked row of a kind outside \(list.kinds)", file: file, line: line)
    }

    func testEachCatalogActionListMakesOnlyTheKindsItsShowCanName() {
        let windows = [window("@1", session: "game/alpha", directory: "/work/game/main", topic: "a"),
                       window("@2", session: "game/beta", directory: "/work/game/release", topic: "a"),
                       window("@3", session: "scratch", directory: "/tmp"),
                       window("@4", session: "spare", directory: "/tmp")]
        let catalog = catalog(records: [topic("a", "Alpha"), topic("b", "Beta")], windows: windows)
        let rows = SessionPathRows.build(sessionPaths: [game, notes], windows: windows, records: [])
        for list in ActionList.allCases {
            switch list {
            case .addSession: assertShowsOnlyItsKinds(list) { catalog.addSessionList(topic: "b", query: "", rows: rows, rules: $0) }
            case .move:
                assertShowsOnlyItsKinds(list) { catalog.moveList(windows[2], query: "", rules: $0) }
                assertShowsOnlyItsKinds(list) { catalog.moveList(windows[2], query: "", scope: .pane, rules: $0) }
            case .moveSession:
                assertShowsOnlyItsKinds(list) { catalog.destinationList(windows[2], topic: "a", query: "", rules: $0) }
                assertShowsOnlyItsKinds(list) { catalog.destinationList(windows[0], topic: nil, query: "", rules: $0) }
            // CommandPalette builds these from the WorkspaceStore: testEachPaletteActionList… checks them.
            case .startSession: assertShowsOnlyItsKinds(list) { catalog.startSessionList(query: "", rules: $0) }
            case .tags, .worktreeStart, .newWorktree, .removeWorktree: break
            }
        }
    }

    @MainActor func testEachPaletteActionListMakesOnlyTheKindsItsShowCanName() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("muxify-pick-list-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("config.yaml").path
        try ("pick_lists:\n" + ActionList.allCases.map { list in
            "  \(list.rawValue):\n    show: [\(RowKind.allCases.filter(list.kinds.contains).map(\.rawValue).joined(separator: ", "))]\n"
        }.joined()).write(toFile: path, atomically: true, encoding: .utf8)
        let narrowed = WorkspaceStore(configStore: ConfigStore(path: path), defaults: isolatedDefaults(), visitStore: isolatedVisits())
        XCTAssertEqual(narrowed.config.problems, [])
        XCTAssertEqual(Set(narrowed.config.pickLists.keys), Set(ActionList.allCases))
        let standard = WorkspaceStore(configStore: ConfigStore(path: directory.appendingPathComponent("none.yaml").path),
                                      defaults: isolatedDefaults(), visitStore: isolatedVisits())
        let defined = ConfigTags([TagDefinition(tag: Tag(name: "backend")!), TagDefinition(tag: Tag(name: "ops")!)])
        let draft = WorktreeStartDraft(topic: TopicRecord(id: "t", title: "T"), choice: SessionChoice(sessionPath: game, worktree: nil))
        draft.starts = .ready([WorktreeStartChoice(branch: "main", checkedOutAt: "/work/game/main"),
                               WorktreeStartChoice(branch: "feature", checkedOutAt: nil)])
        let removing = RemoveWorktreeDraft()
        removing.rows = .ready([MuxifyWorktreeSummary(record: MuxifyWorktreeRecord(repository: "/work/game", name: "fix",
                                                                                   path: "/trees/game/fix", branch: "fix", base: "abc"),
                                                      state: .clean, sessions: [], topic: nil)])
        // New Worktree lists the WorkspaceStore's SessionPaths, which only discovery fills: none here to check.
        for (list, flow, query) in [(ActionList.tags, PaletteFlow.text(.tags(TagField(mode: .newTopic, defined: defined))), "#"),
                                    (.worktreeStart, .worktreeStart(draft), ""), (.removeWorktree, .removeWorktree(removing), "")] {
            narrowed.palette.query = query
            standard.palette.query = query
            let built = standard.palette.flowResults(flow)
            XCTAssertFalse(built.rows.isEmpty, "\(list) has no rows to check")
            XCTAssertEqual(narrowed.palette.flowResults(flow), built, "\(list) makes a ranked row of a kind outside \(list.kinds)")
        }
    }

    func testStartSessionListsTheHomeFolderFirstThenEachSessionPathAndWorktree() {
        let forge = SessionPath(path: "/work/forge", name: "forge",
                                layout: .bareRepository([Worktree(path: "/work/forge/main", branch: "main"),
                                                         Worktree(path: "/work/trees/forge-fix", branch: "fix")]))
        let catalog = catalog(records: [], windows: [], sessionPaths: [forge, notes])
        let list = catalog.startSessionList(query: "", rules: .standard)
        XCTAssertEqual(list.rows.first?.id, "home-folder", "↩ on an empty query starts in the home folder")
        XCTAssertEqual(Set(ids(list).dropFirst()), ["session-path:/work/forge/main", "session-path:/work/trees/forge-fix", "session-path:/work/notes"])
        func target(_ id: String, in list: PickList<PaletteItem>) -> (path: String, name: String)? {
            guard case .sessionPath(let target)? = list.rows.first(where: { $0.id == id })?.pick.payload?.ref else { return nil }
            return (target.directory.path, target.name)
        }
        XCTAssertEqual(target("home-folder", in: list)?.path, "/home")
        XCTAssertEqual(target("home-folder", in: list)?.name, "home", "named after its folder")
        XCTAssertEqual(target("session-path:/work/notes", in: list)?.name, "notes", "the same start as Open as Session")
        XCTAssertEqual(target("session-path:/work/trees/forge-fix", in: list)?.name, "forge/forge-fix")

        XCTAssertEqual(ids(catalog.startSessionList(query: "notes", rules: .standard)), ["session-path:/work/notes", "home-folder"],
                       "a query's match comes before the home folder, so ↩ starts the match")
        let folders = catalog.startSessionList(query: "", rules: PickRules(show: [.sessionPath]))
        XCTAssertEqual(ids(folders).first, "home-folder")
        XCTAssertEqual(Set(ids(folders)), ["home-folder", "session-path:/work/forge/main", "session-path:/work/notes"],
                       "show leaves out the Worktrees, never the home folder")
    }

    func testARemoteAppWindowHasNoTopicsSource() {
        var catalog = catalog(records: [topic("a", "Alpha")], windows: [])
        catalog.board = nil
        XCTAssertFalse(catalog.offersTopics)
        XCTAssertEqual(catalog.list(goTo, query: "", rules: .standard).sections.map(\.id), ["sessions"])
    }

    func testMoveOffersOtherOpenTopicsBlocksAnOccupiedOneAndEndsWithNewTopicTitledByTheQuery() {
        let records = [topic("a", "Alpha"), topic("b", "Beta"), topic("c", "Charlie")]
        let windows = [window("@1", session: "game/alpha", directory: "/work/game/main", topic: "a"),
                       window("@2", session: "game/beta", directory: "/work/game/release", topic: "b"),
                       window("@3", session: "notes/charlie", directory: "/work/notes", topic: "c"),
                       window("@4", session: "scratch", directory: "/work/game/release")]
        let catalog = catalog(records: records, windows: windows, selected: "@4")
        let list = catalog.moveList(windows[3], query: "", rules: .standard)
        XCTAssertEqual(ids(list), ["topic-a", "topic-b", "topic-c", "new-topic", "no-topic"])
        XCTAssertNotNil(list.rows[0].pick.payload, "folders never block membership")
        XCTAssertEqual(list.rows[2].pick.payload?.ref, .choice(.move(.topic(id: "c"))))
        XCTAssertEqual(list.rows[3].detail.text, "Untitled")
        let typed = catalog.moveList(windows[3], query: " Reward cap ", rules: .standard)
        XCTAssertEqual(ids(typed), ["new-topic"], "a query no Topic matches leaves only New Topic")
        XCTAssertEqual(typed.rows[0].pick.payload?.ref, .choice(.move(.newTopic(title: "Reward cap"))))
        XCTAssertEqual(ids(catalog.moveList(windows[0], query: "", rules: .standard)), ["topic-b", "topic-c", "new-topic", "no-topic"],
                       "the source's own Topic is not a target")
    }

    func testAgentsThatNeedYouComeFirstAndWindowsShowEmptyOnlyAlone() {
        let windows = [window("@1", session: "a", directory: "/a"), window("@2", session: "b", directory: "/b")]
        func agent(_ id: String, _ window: TmuxWindow, _ status: AgentStatus?, unread: Bool = false) -> Agent {
            Agent(paneID: id, kind: .codex, status: status, unread: unread, windowID: window.id, sessionID: window.sessionID,
                  sessionName: window.sessionName, windowIndex: 0, windowTitle: "", label: "Agent " + id)
        }
        let agents = [agent("%1", windows[0], .done), agent("%2", windows[1], .working), agent("%3", windows[0], .failed, unread: true),
                      agent("%4", windows[1], .done, unread: true), agent("%5", windows[0], .failed)]
        let catalog = catalog(records: [], windows: windows, agents: agents, mode: .sessions)
        XCTAssertEqual(ids(catalog.list([.agents], query: "", rules: .standard)), ["agent:%3", "agent:%4", "agent:%2", "agent:%1", "agent:%5"],
                       "a read, failed Agent has no Notification, so it goes with the read, done one")
        XCTAssertEqual(catalog.list([.sessions, .windows], query: "", rules: .standard).sections.map(\.id), ["sessions"])
        XCTAssertEqual(ids(catalog.list([.windows], query: "", rules: .standard)), ["window:@1", "window:@2"])
        XCTAssertFalse(ids(catalog.list([.agents, .windows], query: "a", rules: .standard)).contains("window:@1"), "the Agent's row stands for its Window")
    }

    func testEntryWindowPrefersTheRememberedWindowThenTheSessionVisitedLastThenAnActiveWindow() throws {
        let records = [topic("a", "Fix")]
        let windows = [window("@1", session: "game/fix", directory: "/work/game/main", topic: "a", active: false),
                       window("@2", session: "game/fix", directory: "/work/game/main", topic: "a"),
                       window("@3", session: "notes/fix", directory: "/work/notes", topic: "a")]
        let row = try XCTUnwrap(catalog(records: records, windows: windows).board?.rows.first)
        XCTAssertEqual(EntryWindow.of(row, lastWindowByGroup: [.topic("a"): "@1"], visits: VisitLog())?.id, "@1")
        XCTAssertEqual(EntryWindow.of(row, lastWindowByGroup: [.topic("a"): "@9"], visits: visits([(.session(name: "notes/fix"), 5)]))?.id, "@3")
        XCTAssertEqual(EntryWindow.of(row, lastWindowByGroup: [:], visits: VisitLog())?.id, "@2")
        let dormant = try XCTUnwrap(catalog(records: records, windows: []).board?.rows.first)
        XCTAssertNil(EntryWindow.of(dormant, lastWindowByGroup: [:], visits: VisitLog()))
    }
}
