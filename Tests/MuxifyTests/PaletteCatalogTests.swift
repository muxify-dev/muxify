import XCTest
@testable import MuxifyCore

final class PaletteCatalogTests: XCTestCase {
    private let game = SessionPath(path: "/work/game", name: "game",
                               layout: .bareRepository([Worktree(path: "/work/game/main", branch: "main"),
                                                        Worktree(path: "/work/game/release", branch: "release")]))
    private let notes = SessionPath(path: "/work/notes", name: "notes")
    private let now = Date(timeIntervalSince1970: 10_000)

    private func window(_ id: String, session: String, directory: String, topic: String? = nil, active: Bool = true,
                        activity: Int = 0) -> TmuxWindow {
        TmuxWindow(id: id, sessionID: "$" + session, sessionName: session, index: 0, name: "shell", paneTitle: "", path: directory,
                   command: "zsh", isActive: active, paneCount: 1, hasBell: false, sessionActivity: activity, agent: "",
                   storedBrowser: StoredBrowser(), openRequests: [], topicID: topic, sessionPath: directory)
    }

    /// A Topic whose Session is remembered in the main Worktree of game, as the app remembers it.
    private func topic(_ id: String, _ title: String) -> TopicRecord {
        var record = TopicRecord(id: id, title: title)
        record.sessions = [.object(["id": .string("saved:" + id), "name": .string("game/" + id),
                                   "base_name": .string("game"), "directory": .string("/work/game/main")])]
        return record
    }

    private func catalog(records: [TopicRecord], windows: [TmuxWindow], selected: String? = nil, visits: VisitLog = VisitLog(),
                         lastWindow: [TopicGroupID: String] = [:], agents: [Agent] = [], zen: ZenRecord? = nil,
                         mode: SidebarMode = .topics, sessionPaths: [SessionPath]? = nil) -> PaletteCatalog {
        var config = Config()
        config.sessionPaths = sessionPaths ?? [game, notes]
        var selection = TopicSelection()
        selection.windowID = selected
        let model = TopicsModel(records: records, windows: windows, config: config, selection: selection, mode: mode,
                                agents: agents, zen: zen, now: now)
        return PaletteCatalog(windows: windows, agents: agents, sessionPaths: config.sessionPaths, selectedWindowID: selected,
                              homeDirectory: "/home", topics: model, records: records, lastWindowByGroup: lastWindow,
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

    func testGoToListsOtherLiveTopicsThenCurrentThenDormantBeforeSessionsSnoozedAndSettled() {
        var snoozed = topic("z", "Zzz")
        snoozed.snoozedUntil = "never"
        var settled = topic("s", "Settled")
        settled.settledAt = "2026-01-01T00:00:00Z"
        let records = [topic("a", "Alpha"), topic("b", "Beta"), topic("c", "Charlie"), snoozed, settled]
        let windows = [window("@1", session: "game/alpha", directory: "/work/game/main", topic: "a"),
                       window("@2", session: "game/beta", directory: "/work/game/release", topic: "b"),
                       window("@3", session: "scratch", directory: "/work/notes")]
        let visits = visits([(.topic(.topic("b")), 100), (.topic(.topic("a")), 300), (.topic(.noTopic), 200)])
        let list = catalog(records: records, windows: windows, selected: "@1", visits: visits).list(goTo, query: "")
        XCTAssertEqual(list.sections.map(\.id), ["topics", "sessions", "snoozed", "settled"])
        XCTAssertEqual(CommandPaletteConfig.goTo.sources, goTo)
        let topics = list.sections[0].rows
        XCTAssertEqual(topics.map(\.id), ["topic-b", "topic-a", "topic-c"], "other live Topics, then the Active Topic, then Dormant; no No Topic row")
        XCTAssertEqual(topics[1].trailing, "Active")
        XCTAssertEqual(topics[2].trailing, "Reopen")
        XCTAssertEqual(topics[2].pick.payload?.ref, .topic(id: "c", window: nil))
        XCTAssertEqual(topics[0].pick.payload?.ref, .topic(id: "b", window: windows[1]))
        XCTAssertEqual(topics[0].trailing, "2h")
    }

    func testSnoozedAndSettledTopicsRankBelowAWeakerSessionMatch() {
        var snoozed = topic("z", "Scratch")
        snoozed.snoozedUntil = "never"
        var settled = topic("s", "Scratch")
        settled.settledAt = "2026-01-01T00:00:00Z"
        let windows = [window("@1", session: "old-scratch-2", directory: "/tmp/old")]
        let list = catalog(records: [snoozed, settled], windows: windows).list(goTo, query: "scratch")
        XCTAssertEqual(ids(list), ["session:$old-scratch-2", "topic-z", "topic-s"])
    }

    func testEveryRunningSessionHasItsOwnRowInBothModesAndDifferentNamesDoNotOccupyPaths() {
        let records = [topic("a", "Alpha")]
        let windows = [window("@1", session: "game/alpha", directory: "/work/game/main", topic: "a"),
                       window("@2", session: "notes-2", directory: "/work/notes"),
                       window("@3", session: "scratch", directory: "/tmp/scratch")]
        for mode in [SidebarMode.topics, .sessions] {
            let catalog = catalog(records: records, windows: windows, mode: mode)
            XCTAssertEqual(Set(ids(catalog.list([.sessions], query: ""))), ["session-path:/work/notes", "session:$scratch", "session:$notes-2", "session:$game/alpha",
                "session-path:/work/game/main", "session-path:/work/game/release"])
            XCTAssertEqual(ids(catalog.list([.sessions], query: "notes-2")), ["session:$notes-2"])
        }
    }

    func testExactNameSuppressesLaunchEvenElsewhereAndCurrentSessionRanksLastAmongRunning() {
        let records = [topic("a", "Fix")]
        let windows = [window("@1", session: "game/fix", directory: "/work/game/main/src", topic: "a", activity: 3),
                       window("@2", session: "game/release", directory: "/elsewhere", activity: 9),
                       window("@3", session: "scratch", directory: "/tmp/scratch", activity: 5)]
        let list = catalog(records: records, windows: windows, selected: "@2", mode: .sessions).list(goTo, query: "")
        XCTAssertEqual(list.sections.map(\.id), ["topics", "sessions"])
        let rows = list.sections.last?.rows ?? []
        XCTAssertEqual(rows.map(\.id), ["session:$scratch", "session:$game/fix", "session:$game/release", "session-path:/work/game/main", "session-path:/work/notes"])
        XCTAssertEqual(rows[2].trailing, "Current")
        XCTAssertEqual(rows.last?.pick.payload?.ref, .sessionPath(OpenDirectory(directory: .local("/work/notes"), name: "notes")))
        XCTAssertEqual(rows.last?.trailing, "↩ open")
        XCTAssertNil(rows.last?.pick.payload?.target)
    }

    func testOnATieARunningSessionComesBeforeASessionPathThenTheMoreRecent() {
        let windows = [window("@1", session: "note", directory: "/q/note", activity: 1),
                       window("@2", session: "note-b", directory: "/q/b", activity: 7)]
        let sessionPaths = [SessionPath(path: "/q/notes", name: "note-c")]
        let list = catalog(records: [], windows: windows, mode: .sessions, sessionPaths: sessionPaths).list([.sessions], query: "note")
        XCTAssertEqual(ids(list), ["session:$note-b", "session:$note", "session-path:/q/notes"])
    }

    func testRowsShowTheAgentMarkOfTheirSidebarCard() {
        let records = [topic("a", "Alpha"), topic("b", "Beta")]
        let windows = [window("@1", session: "game/alpha", directory: "/work/game/main", topic: "a"),
                       window("@2", session: "game/beta", directory: "/work/game/release", topic: "b"),
                       window("@3", session: "scratch", directory: "/tmp/scratch")]
        func agent(_ id: String, _ window: TmuxWindow, _ status: AgentStatus) -> Agent {
            Agent(paneID: id, kind: .codex, status: status, unread: true, windowID: window.id, sessionID: window.sessionID,
                  sessionName: window.sessionName, windowIndex: window.index, windowTitle: window.displayTitle, label: "Agent")
        }
        let agents = [agent("%1", windows[0], .done), agent("%2", windows[1], .working), agent("%3", windows[2], .blocked)]
        let list = catalog(records: records, windows: windows, agents: agents).list(goTo, query: "")
        func row(_ id: String) -> PickRow<PaletteItem>? { list.rows.first { $0.id == id } }
        XCTAssertEqual(row("topic-a")?.mark, .agent(.done))
        XCTAssertEqual(row("topic-b")?.mark, .agent(.working))
        XCTAssertEqual(row("session:$scratch")?.mark, .agent(.blocked))
    }

    func testDuringZenANoTopicSessionShowsNoNotificationMark() {
        let records = [topic("a", "Alpha")]
        let windows = [window("@1", session: "game/alpha", directory: "/work/game/main", topic: "a"),
                       window("@3", session: "scratch", directory: "/tmp/scratch")]
        let agents = [Agent(paneID: "%3", kind: .codex, status: .blocked, unread: true, windowID: "@3", sessionID: "$scratch",
                            sessionName: "scratch", windowIndex: 1, windowTitle: "Agent", label: "Agent")]
        let zen = ZenRecord(keptTopicID: "a", until: SnoozeDeadline.never.stored, changes: [])
        let list = catalog(records: records, windows: windows, selected: "@1", agents: agents, zen: zen).list(goTo, query: "scratch")
        XCTAssertEqual(ids(list), ["session:$scratch"])
        XCTAssertNil(list.rows[0].mark)
    }

    func testRowsWithAFolderPasteItAndOnlyOpenOrSnoozedTopicsSnooze() {
        var snoozed = topic("z", "Zzz")
        snoozed.snoozedUntil = "never"
        var settled = topic("s", "Settled")
        settled.settledAt = "2026-01-01T00:00:00Z"
        let records = [topic("a", "Alpha"), topic("d", "Dormant"), snoozed, settled]
        let windows = [window("@1", session: "game/alpha", directory: "/work/game/main", topic: "a"),
                       window("@2", session: "scratch", directory: "/elsewhere/my notes")]
        let rows = catalog(records: records, windows: windows).sections(goTo + [.windows]).flatMap(\.candidates)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: rows.compactMap { row in row.snooze.map { (row.id, $0) } }),
                       ["topic-a": "a", "topic-d": "d", "topic-z": "z"], "the Settled Topic, Session and SessionPath rows Snooze nothing")
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

    func testTypingKeepsSectionsAndMarksWhatMatched() {
        var settled = topic("s", "Game settled")
        settled.settledAt = "2026-01-01T00:00:00Z"
        settled.outcome = "Shipped the GS reward cap"
        var snoozed = topic("z", "Game paused")
        snoozed.snoozedUntil = "never"
        let records = [topic("a", "Fix game drops"), snoozed, settled]
        let windows = [window("@1", session: "game/fix", directory: "/work/game/main", topic: "a"),
                       window("@2", session: "game-scratch", directory: "/tmp/scratch")]
        let catalog = catalog(records: records, windows: windows)
        let list = catalog.list(goTo, query: "game")
        XCTAssertEqual(list.sections.map(\.title), ["Topics", "Sessions", "Snoozed", "Settled"])
        XCTAssertEqual(list.sections[0].rows.map(\.id), ["topic-a"])
        XCTAssertEqual(list.sections[2].rows[0].pick.payload?.ref, .topic(id: "z", window: nil), "a Dormant Snoozed Topic Reopens")
        XCTAssertEqual(list.sections[2].rows[0].trailing, "Reopen")
        XCTAssertEqual(list.sections[2].rows[0].detail.text, "until never")
        XCTAssertEqual(list.sections[3].rows[0].detail.text, "Shipped the GS reward cap")
        XCTAssertEqual(list.sections[1].rows.first?.id, "session:$game/fix", "all running Sessions, including Topic members, are searchable")
        let byOutcome = catalog.list(goTo, query: "sett gs")
        XCTAssertEqual(ids(byOutcome), ["topic-s"], "one word on the type word, one on the outcome")
        XCTAssertEqual(byOutcome.rows[0].title.marks, [5, 6, 7, 8])
        XCTAssertEqual(catalog.list(goTo, query: "snoo").rows.first?.detail.text, "snoozed · until never",
                       "a type word shows when it is what matched")
    }

    func testATopicRowShowsButNeverMatchesTheBaseNamesOfItsSessions() {
        let records = [topic("a", "Alpha")]
        let windows = [window("@1", session: "game/alpha", directory: "/work/game/main", topic: "a")]
        let catalog = catalog(records: records, windows: windows)
        XCTAssertFalse(ids(catalog.list([.topics], query: "game")).contains("topic-a"))
        XCTAssertTrue(catalog.list([.topics], query: "").rows.first?.detail.text.contains("game") ?? false)
    }

    func testASnoozedTopicWithAWindowGoesToItsEntryWindowAndKeepsTheSnooze() {
        var snoozed = topic("z", "Paused")
        snoozed.snoozedUntil = "never"
        let windows = [window("@1", session: "game/paused", directory: "/work/game/main", topic: "z", active: false),
                       window("@2", session: "game/paused", directory: "/work/game/main", topic: "z")]
        let row = catalog(records: [snoozed], windows: windows).list([.topics], query: "paused").rows[0]
        XCTAssertEqual(row.pick.payload?.ref, .topic(id: "z", window: windows[1]))
        XCTAssertEqual(row.pick.payload?.kind, .snoozedTopic)
        XCTAssertEqual(row.snooze, "z")
    }

    func testAPlainRepositoryIsNamedAfterTheSessionPathAndItsOutsideWorktreeAfterTheFolder() {
        let chezmoi = SessionPath(path: "/home/.local/share/chezmoi", name: "chezmoi",
                              layout: .plainRepository([Worktree(path: "/home/.local/share/chezmoi", branch: "master"),
                                                        Worktree(path: "/home/.cache/git-pile/98400b", branch: nil)]))
        let list = catalog(records: [], windows: [], sessionPaths: [chezmoi]).list([.sessions], query: "chez")
        XCTAssertEqual(list.rows.map(\.title.text), ["chezmoi", "chezmoi/98400b"])
        XCTAssertEqual(list.rows.map { $0.pick.payload?.kind }, [.sessionPath, .worktree])
    }

    func testARemoteAppWindowHasNoTopicsSource() {
        var catalog = catalog(records: [topic("a", "Alpha")], windows: [])
        catalog.topics = nil
        XCTAssertFalse(catalog.offersTopics)
        XCTAssertEqual(catalog.list(goTo, query: "").sections.map(\.id), ["sessions"])
    }

    func testMoveOffersOtherOpenTopicsBlocksAnOccupiedOneAndEndsWithNewTopicTitledByTheQuery() {
        var snoozed = topic("z", "Zzz")
        snoozed.snoozedUntil = "never"
        let records = [topic("a", "Alpha"), topic("b", "Beta"), topic("c", "Charlie"), snoozed]
        let windows = [window("@1", session: "game/alpha", directory: "/work/game/main", topic: "a"),
                       window("@2", session: "game/beta", directory: "/work/game/release", topic: "b"),
                       window("@3", session: "notes/charlie", directory: "/work/notes", topic: "c"),
                       window("@4", session: "scratch", directory: "/work/game/release")]
        let catalog = catalog(records: records, windows: windows, selected: "@4")
        let list = catalog.moveList(windows[3], query: "")
        XCTAssertEqual(ids(list), ["topic-a", "topic-b", "topic-c", "new-topic", "no-topic"])
        XCTAssertNotNil(list.rows[0].pick.payload, "folders never block membership")
        XCTAssertEqual(list.rows[2].pick.payload?.ref, .choice(.move(.topic(id: "c"))))
        XCTAssertEqual(list.rows[3].detail.text, "Untitled")
        let typed = catalog.moveList(windows[3], query: " Reward cap ")
        XCTAssertEqual(ids(typed), ["new-topic"], "a query no Topic matches leaves only New Topic")
        XCTAssertEqual(typed.rows[0].pick.payload?.ref, .choice(.move(.newTopic(title: "Reward cap"))))
        XCTAssertEqual(ids(catalog.moveList(windows[0], query: "")), ["topic-b", "topic-c", "new-topic", "no-topic"],
                       "the source's own Topic is not a target")
    }

    func testTopicVisitsOverridePinsAndDormantVisitsAndKeepCurrentLastAmongLive() {
        func pinned(_ record: TopicRecord, order: Double) -> TopicRecord {
            var record = record
            record.isPinned = true
            record.order = order
            return record
        }
        let records = [topic("a", "Alpha one"), topic("b", "Beta"), pinned(topic("c", "Charlie"), order: 0),
                       pinned(topic("d", "Alpha two"), order: 1)]
        let windows = [window("@1", session: "game/alpha", directory: "/work/game/main", topic: "a"),
                       window("@2", session: "game/beta", directory: "/work/game/main", topic: "b", activity: 900),
                       window("@3", session: "game/charlie", directory: "/work/game/main", topic: "c", activity: 1000)]
        let visits = visits([(.topic(.topic("a")), 400), (.topic(.topic("d")), 500), (.topic(.topic("b")), 200), (.topic(.topic("c")), 100)])
        let catalog = catalog(records: records, windows: windows, selected: "@1", visits: visits)
        XCTAssertEqual(ids(catalog.list([.topics], query: "")), ["topic-b", "topic-c", "topic-a", "topic-d"],
                        "visits rank live Topics regardless of Pins/activity; current then Dormant, even when Dormant was visited more recently")
        XCTAssertEqual(ids(catalog.list([.topics], query: "alpha")), ["topic-a", "topic-d"], "on an equal match the last visit decides, not the Pin")
    }

    func testTopicActivityBreaksVisitTiesUsingAllMemberSessionsAndUnvisitedTopicsFollowVisitedOnes() {
        let records = [topic("a", "Alpha"), topic("b", "Beta"), topic("c", "Charlie"), topic("d", "Dormant"), TopicRecord(id: "e", title: "Empty")]
        let windows = [window("@1", session: "game/alpha", directory: "/work/game/main", topic: "a", activity: 1),
                       window("@2", session: "game/beta", directory: "/work/game/main", topic: "b", activity: 5),
                       window("@3", session: "notes/alpha", directory: "/work/notes", topic: "a", activity: 9),
                       window("@4", session: "game/charlie", directory: "/work/game/main", topic: "c", activity: 100)]
        let visits = visits([(.topic(.topic("a")), 100), (.topic(.topic("b")), 100), (.topic(.topic("d")), 500)])
        let catalog = catalog(records: records, windows: windows, visits: visits)
        XCTAssertEqual(ids(catalog.list([.topics], query: "")), ["topic-a", "topic-b", "topic-c", "topic-d", "topic-e"])
        XCTAssertEqual(catalog.list([.topics], query: "").rows.last?.trailing, "Empty")
    }

    func testTypedTopicQueryRanksMatchesWithoutPushingCurrentDownOrDormantToBottom() {
        let records = [topic("a", "Alpha current"), topic("b", "Alpha other"), topic("c", "Alpha dormant")]
        let windows = [window("@1", session: "game/alpha", directory: "/work/game/main", topic: "a"),
                       window("@2", session: "game/beta", directory: "/work/game/main", topic: "b")]
        let catalog = catalog(records: records, windows: windows, selected: "@1",
                              visits: visits([(.topic(.topic("a")), 300), (.topic(.topic("b")), 100)]))
        XCTAssertEqual(ids(catalog.list([.topics], query: "alpha")), ["topic-a", "topic-b", "topic-c"])
        XCTAssertEqual(ids(catalog.list([.topics], query: "dormant")), ["topic-c"], "a better match still outranks running Topics")
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
        XCTAssertEqual(ids(catalog.list([.agents], query: "")), ["agent:%3", "agent:%4", "agent:%2", "agent:%1", "agent:%5"],
                       "a read, failed Agent has no Notification, so it goes with the read, done one")
        XCTAssertEqual(catalog.list([.sessions, .windows], query: "").sections.map(\.id), ["sessions"])
        XCTAssertEqual(ids(catalog.list([.windows], query: "")), ["window:@1", "window:@2"])
        XCTAssertFalse(ids(catalog.list([.agents, .windows], query: "a")).contains("window:@1"), "the Agent's row stands for its Window")
    }

    func testEntryWindowPrefersTheRememberedWindowThenTheSessionVisitedLastThenAnActiveWindow() throws {
        let records = [topic("a", "Fix")]
        let windows = [window("@1", session: "game/fix", directory: "/work/game/main", topic: "a", active: false),
                       window("@2", session: "game/fix", directory: "/work/game/main", topic: "a"),
                       window("@3", session: "notes/fix", directory: "/work/notes", topic: "a")]
        let row = try XCTUnwrap(catalog(records: records, windows: windows).topics?.rows.first)
        XCTAssertEqual(EntryWindow.of(row, lastWindowByGroup: [.topic("a"): "@1"], visits: VisitLog())?.id, "@1")
        XCTAssertEqual(EntryWindow.of(row, lastWindowByGroup: [.topic("a"): "@9"], visits: visits([(.session(name: "notes/fix"), 5)]))?.id, "@3")
        XCTAssertEqual(EntryWindow.of(row, lastWindowByGroup: [:], visits: VisitLog())?.id, "@2")
        let dormant = try XCTUnwrap(catalog(records: records, windows: []).topics?.rows.first)
        XCTAssertNil(EntryWindow.of(dormant, lastWindowByGroup: [:], visits: VisitLog()))
    }
}
