import XCTest
@testable import MuxifyCore
import MuxifyTestSupport

final class GoToTests: XCTestCase {
    private let game = SessionPath(path: "/work/game", name: "game",
                                   layout: .bareRepository([Worktree(path: "/work/game/main", branch: "main"),
                                                            Worktree(path: "/work/game/release", branch: "release")]))
    private let notes = SessionPath(path: "/work/notes", name: "notes")
    private let now = Date(timeIntervalSince1970: 10_000)
    private let goTo: [PaletteSource] = [.topics, .sessions]

    private func window(_ id: String, session: String, directory: String, topic: String? = nil, active: Bool = true,
                        activity: Int = 0, saved: String = "") -> TmuxWindow {
        .fixture(id: id, sessionID: "$" + session, sessionName: session, path: directory, isActive: active, sessionActivity: activity,
                 topicID: topic, savedSessionID: saved, sessionPath: directory)
    }

    private func topic(_ id: String, _ title: String) -> TopicRecord {
        var record = TopicRecord(id: id, title: title)
        record.sessions = [.object(["id": .string("saved:" + id), "name": .string("game/" + id),
                                   "base_name": .string("game"), "directory": .string("/work/game/main")])]
        return record
    }

    private func boardSession(_ id: String, _ name: String) -> BoardSession {
        BoardSession(id: id, order: 0, isGuest: true, session: .object([
            "id": .string(id), "name": .string(name), "base_name": .string(name), "directory": .string("/work/" + name), "windows": .array([]),
        ]))
    }

    private func input(records: [TopicRecord] = [], boardSessions: [BoardSession] = [], windows: [TmuxWindow], current: GoToLocation? = nil,
                       visits: [VisitKey: TimeInterval] = [:], agents: [Agent] = [], sessionPaths: [SessionPath]? = nil,
                       tags: ConfigTags? = nil) -> GoToInput {
        var topics = Config.Topics()
        topics.tags = tags
        let marks = AgentMarks(agents, notifications: Config.Notifications())
        let board = Board(records: records, openPlaces: [], boardSessions: boardSessions, windows: windows, marks: marks, topics: topics)
        return GoToInput(board: board, records: records, windows: windows, sessionPaths: sessionPaths ?? [game, notes], sessionMarks: marks.sessions,
                         tags: tags, visits: visits.mapValues(Date.init(timeIntervalSince1970:)), current: current, home: "/home", now: now)
    }

    private func list(_ input: GoToInput, _ sources: [PaletteSource]? = nil, query: String, rules: PickRules = .standard,
                      order: PaletteOrder = .grouped) -> PickList<GoToTarget> {
        input.list(sources ?? goTo, query: query, rules: rules, order: order, payload: { $0 })
    }

    private func ids(_ list: PickList<GoToTarget>) -> [String] { list.rows.map(\.id) }

    func testGoToListsOtherLiveTopicsThenCurrentThenDormantBeforeSessionsAndSettled() {
        var settled = topic("s", "Settled")
        settled.settledAt = "2026-01-01T00:00:00Z"
        let records = [topic("a", "Alpha"), topic("b", "Beta"), topic("c", "Charlie"), settled]
        let windows = [window("@1", session: "game/alpha", directory: "/work/game/main", topic: "a"),
                       window("@2", session: "game/beta", directory: "/work/game/release", topic: "b"),
                       window("@3", session: "scratch", directory: "/work/notes")]
        let visits: [VisitKey: TimeInterval] = [.topic(.topic("b")): 100, .topic(.topic("a")): 300, .topic(.noTopic): 200]
        let list = list(input(records: records, windows: windows, current: .window(id: "@1"), visits: visits), query: "")
        XCTAssertEqual(list.sections.map(\.id), ["topics", "sessions", "settled"])
        XCTAssertEqual(CommandPaletteConfig.goTo.sources, goTo)
        let topics = list.sections[0].rows
        XCTAssertEqual(topics.map(\.id), ["topic-b", "topic-a", "topic-c"], "other live Topics, then the Active Topic, then Dormant; no No Topic row")
        XCTAssertEqual(topics.map(\.trailing), ["2h", "Active", "Reopen"])
        XCTAssertEqual(topics.map(\.pick.payload), [.topic(id: "b", state: .live), .topic(id: "a", state: .live), .topic(id: "c", state: .dormant)])
        XCTAssertEqual(list.sections[2].rows.map(\.pick.payload), [.settled(id: "s")])
    }

    func testTheSessionThatAClientNamesIsCurrentAndItsTopicIsTheActiveTopic() {
        let records = [topic("a", "Alpha"), topic("b", "Beta")]
        let windows = [window("@1", session: "game/alpha", directory: "/work/game/main", topic: "a"),
                       window("@2", session: "game/beta", directory: "/work/game/release", topic: "b"),
                       window("@3", session: "scratch", directory: "/tmp/scratch")]
        let byName = list(input(records: records, windows: windows, current: .session(name: "game/alpha")), query: "")
        XCTAssertEqual(byName, list(input(records: records, windows: windows, current: .window(id: "@1")), query: ""),
                       "the phone's Session and the app's Window in it give one list")
        XCTAssertEqual(byName.sections[0].rows.map(\.trailing), ["", "Active"])
        XCTAssertEqual(byName.sections[1].rows.prefix(3).map(\.id), ["session:$game/beta", "session:$scratch", "session:$game/alpha"])
        XCTAssertEqual(byName.sections[1].rows[2].trailing, "Current")
        let page = list(input(records: records + [topic("c", "Charlie")], windows: windows, current: .page(.topic("c"))), query: "")
        XCTAssertEqual(page.rows.first { $0.id == "topic-c" }?.trailing, "Reopen", "a Dormant Topic's page makes no row Active")
    }

    func testADormantBoardSessionIsARowAmongTheTopicsAndALiveOneIsARowOfTheSessions() {
        let windows = [window("@1", session: "game/alpha", directory: "/work/game/main", topic: "a"),
                       window("@2", session: "docs", directory: "/work/docs", saved: "s2")]
        let input = input(records: [topic("a", "Alpha")], boardSessions: [boardSession("s1", "notes"), boardSession("s2", "docs")], windows: windows,
                          visits: [.session(name: "notes"): 9_000])
        let listed = list(input, query: "")
        XCTAssertEqual(listed.sections[0].rows.map(\.id), ["topic-a", "board-session-s1"], "the Dormant one goes after the live cards")
        let dormant = try? XCTUnwrap(listed.rows.first { $0.id == "board-session-s1" })
        XCTAssertEqual(dormant?.kind, .session)
        XCTAssertEqual(dormant?.title.text, "notes")
        XCTAssertEqual(dormant?.trailing, "Reopen")
        XCTAssertEqual(dormant?.pick.payload, .boardSession(id: "s1"))
        XCTAssertEqual(listed.rows.first { $0.id == "session:$docs" }?.pick.payload, .session(id: "$docs", name: "docs"),
                       "a live Board Session is a Session")
        XCTAssertEqual(ids(list(input, query: "dormant")), ["board-session-s1"])
        XCTAssertEqual(ids(list(input, query: "notes", rules: PickRules(show: [.topic, .sessionPath]))), ["session-path:/work/notes"],
                       "show without session leaves it out")
    }

    func testSettledTopicsRankByScoreForAQueryAndComeLastWithout() {
        var settled = topic("s", "Claude mods notes")
        settled.settledAt = "2026-01-01T00:00:00Z"
        let windows = [window("@1", session: "chezmoi/what-are-claude-code-mods", directory: "/tmp/chezmoi"),
                       window("@2", session: "muxify/claude-mods-later", directory: "/tmp/muxify")]
        let input = input(records: [topic("a", "Clean up old modules"), settled], windows: windows)
        let grouped = list(input, query: "claude mods")
        XCTAssertEqual(grouped.sections.map(\.title), ["Topics", "Sessions"], "under headers, a query puts them among the open Topics")
        XCTAssertEqual(grouped.sections[0].rows.map(\.id), ["topic-s", "topic-a"],
                       "the Settled Topic matches better than the open one")
        let oneList = list(input, query: "claude mods", order: .ranked)
        XCTAssertEqual(oneList.sections.map(\.title), [nil])
        XCTAssertEqual(ids(oneList), ["session:$muxify/claude-mods-later", "session:$chezmoi/what-are-claude-code-mods", "topic-s", "topic-a"],
                       "in one list, a separator earns no more than another, so the Sessions tie the set-aside Topics and go first, and the weak open Topic is last")
        XCTAssertEqual(ids(list(input, query: "", order: .ranked)).suffix(1), ["topic-s"], "with nothing typed, Settled Topics stay last")
        XCTAssertEqual(list(input, query: "").sections.map(\.title), ["Topics", "Sessions", "Settled"])
    }

    func testExactNameSuppressesLaunchEvenElsewhereAndCurrentSessionRanksLastAmongRunning() {
        let windows = [window("@1", session: "game/fix", directory: "/work/game/main/src", topic: "a", activity: 3),
                       window("@2", session: "game/release", directory: "/elsewhere", activity: 9),
                       window("@3", session: "scratch", directory: "/tmp/scratch", activity: 5)]
        let list = list(input(records: [topic("a", "Fix")], windows: windows, current: .window(id: "@2")), query: "")
        XCTAssertEqual(list.sections.map(\.id), ["topics", "sessions"])
        let rows = list.sections.last?.rows ?? []
        XCTAssertEqual(rows.map(\.id), ["session:$scratch", "session:$game/fix", "session:$game/release", "session-path:/work/game/main", "session-path:/work/notes"])
        XCTAssertEqual(rows[2].trailing, "Current")
        XCTAssertEqual(rows.last?.pick.payload, .sessionPath(directory: "/work/notes", name: "notes"))
        XCTAssertEqual(rows.last?.trailing, "↩ open")
    }

    func testOnATieARunningSessionComesBeforeASessionPathThenTheMoreRecent() {
        let windows = [window("@1", session: "note-a", directory: "/q/note", activity: 1),
                       window("@2", session: "note-b", directory: "/q/b", activity: 7)]
        let input = input(windows: windows, sessionPaths: [SessionPath(path: "/q/notes", name: "note-c")])
        XCTAssertEqual(ids(list(input, [.sessions], query: "note")), ["session:$note-b", "session:$note-a", "session-path:/q/notes"])
    }

    func testOnATieAShorterNameComesFirstEvenWhenItIsNotRunning() {
        let windows = [window("@1", session: "note-feature", directory: "/q/note", activity: 7)]
        let input = input(windows: windows, sessionPaths: [SessionPath(path: "/q/notes", name: "note")])
        XCTAssertEqual(ids(list(input, [.sessions], query: "note")), ["session-path:/q/notes", "session:$note-feature"], "as fzf's --tiebreak=length")
    }

    func testSessionsAndSessionPathsShareOneRankByTheLastVisitAndTheCurrentSessionGoesLastAmongTheRunning() {
        let windows = ["api", "muxify", "web"].enumerated().map { window("@\($0.offset)", session: $0.element, directory: "/code/" + $0.element) }
        let paths = ["api", "music", "muxify", "notes"].map { SessionPath(path: "/code/" + $0, name: $0) }
        let hour: TimeInterval = 3600
        let input = input(windows: windows, current: .session(name: "api"),
                          visits: [.session(name: "api"): 11 * hour, .session(name: "web"): 10 * hour, .session(name: "muxify"): 9 * hour,
                                   .directory("/code/notes"): 8 * hour, .directory("/code/music"): 7 * hour],
                          sessionPaths: paths)
        func titles(_ query: String, order: PaletteOrder) -> [String] { list(input, query: query, order: order).rows.map(\.title.text) }
        for order in PaletteOrder.allCases {
            XCTAssertEqual(titles("", order: order), ["web", "muxify", "api", "notes", "music"],
                           "the running Sessions by their last visit, the current one last, then the folders; a running name hides its folder")
            XCTAssertEqual(titles("mu", order: order), ["music", "muxify"], "the shorter title first on an equal match")
            XCTAssertEqual(titles("mu fy", order: order), ["muxify"])
        }
        XCTAssertEqual(list(input, query: "mu").rows.map(\.kind), [.sessionPath, .session])
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
        let list = list(input(records: records, windows: windows, agents: agents), query: "")
        func row(_ id: String) -> PickRow<GoToTarget>? { list.rows.first { $0.id == id } }
        XCTAssertEqual(row("topic-a")?.mark, .agent(.done))
        XCTAssertEqual(row("topic-b")?.mark, .agent(.working))
        XCTAssertEqual(row("session:$scratch")?.mark, .agent(.blocked))
    }

    func testTypingKeepsSectionsAndMarksWhatMatched() {
        var settled = topic("s", "Game settled")
        settled.settledAt = "2026-01-01T00:00:00Z"
        let windows = [window("@1", session: "game/fix", directory: "/work/game/main", topic: "a"),
                       window("@2", session: "game-scratch", directory: "/tmp/scratch")]
        let input = input(records: [topic("a", "Fix game drops"), settled], windows: windows)
        let list = list(input, query: "game")
        XCTAssertEqual(list.sections.map(\.title), ["Topics", "Sessions"])
        XCTAssertEqual(list.sections[0].rows.map(\.id), ["topic-a", "topic-s"], "on an equal score, the open Topic goes first")
        XCTAssertEqual(list.sections[0].rows[1].detail.text, ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")!.formatted(date: .abbreviated, time: .omitted))
        XCTAssertEqual(list.sections[1].rows.first?.id, "session:$game/fix", "all running Sessions, including Topic members, are searchable")
        let byTwoWords = self.list(input, query: "sett gam")
        XCTAssertEqual(ids(byTwoWords), ["topic-s"], "both words match the title")
        XCTAssertEqual(byTwoWords.rows[0].title.marks, [0, 1, 2, 5, 6, 7, 8])
    }

    func testATopicRowShowsButNeverMatchesTheBaseNamesOfItsSessions() {
        let input = input(records: [topic("a", "Alpha")], windows: [window("@1", session: "game/alpha", directory: "/work/game/main", topic: "a")])
        XCTAssertFalse(ids(list(input, [.topics], query: "game")).contains("topic-a"))
        XCTAssertTrue(list(input, [.topics], query: "").rows.first?.detail.text.contains("game") ?? false)
    }

    func testAPlainRepositoryIsNamedAfterTheSessionPathAndItsOutsideWorktreeAfterTheFolder() {
        let chezmoi = SessionPath(path: "/home/.local/share/chezmoi", name: "chezmoi",
                              layout: .plainRepository([Worktree(path: "/home/.local/share/chezmoi", branch: "master"),
                                                        Worktree(path: "/home/.cache/git-pile/98400b", branch: nil)]))
        let list = list(input(windows: [], sessionPaths: [chezmoi]), [.sessions], query: "chez")
        XCTAssertEqual(list.rows.map(\.title.text), ["chezmoi", "chezmoi/98400b"])
        XCTAssertEqual(list.rows.map(\.kind), [.sessionPath, .worktree])
    }

    func testAPaletteThatLeavesOutTopicSessionsListsNoTopicSessionsAndTheFolderOfAHiddenTopicSession() {
        var settled = topic("s", "Settled")
        settled.settledAt = "2026-01-01T00:00:00Z"
        let windows = [window("@1", session: "notes", directory: "/work/notes", topic: "a"),
                       window("@2", session: "scratch", directory: "/tmp"),
                       window("@3", session: "kept", directory: "/tmp", topic: "s")]
        let input = input(records: [topic("a", "Alpha"), settled], windows: windows)
        let everything = ids(list(input, [.sessions], query: ""))
        XCTAssertTrue(everything.contains("session:$notes"), "\(everything)")
        XCTAssertFalse(everything.contains("session-path:/work/notes"), "a running launch name hides its path: \(everything)")
        let rules = PickRules(show: [.topic, .settled, .session, .sessionPath, .worktree])
        for query in ["", "notes"] {
            let shown = ids(list(input, query: query, rules: rules))
            XCTAssertFalse(shown.contains("session:$notes"), "a Topic's Session is left out for \(query.debugDescription): \(shown)")
            XCTAssertTrue(shown.contains("session-path:/work/notes"), "its folder shows again for \(query.debugDescription): \(shown)")
        }
        let shown = ids(list(input, query: "", rules: rules))
        XCTAssertTrue(shown.contains("session:$scratch"), "a No Topic Session stays: \(shown)")
        XCTAssertTrue(shown.contains("session:$kept"), "a Settled Topic's Session is not in an open Topic: \(shown)")
        XCTAssertTrue(shown.contains("topic-a"), "\(shown)")
    }

    func testABareRepositorysCheckoutInsideItsFolderIsASessionPathAndOneOutsideIsAWorktree() {
        let forge = SessionPath(path: "/work/forge", name: "forge",
                                layout: .bareRepository([Worktree(path: "/work/forge/main", branch: "main"),
                                                         Worktree(path: "/work/trees/forge-fix", branch: "fix")]))
        let list = list(input(windows: [], sessionPaths: [forge]), [.sessions], query: "")
        let kinds = Dictionary(uniqueKeysWithValues: list.rows.map { ($0.id, $0.kind) })
        XCTAssertEqual(kinds, ["session-path:/work/forge/main": .sessionPath, "session-path:/work/trees/forge-fix": .worktree])
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
        let visits: [VisitKey: TimeInterval] = [.topic(.topic("a")): 400, .topic(.topic("d")): 500, .topic(.topic("b")): 200, .topic(.topic("c")): 100]
        let input = input(records: records, windows: windows, current: .window(id: "@1"), visits: visits)
        XCTAssertEqual(ids(list(input, [.topics], query: "")), ["topic-b", "topic-c", "topic-a", "topic-d"],
                        "visits rank live Topics regardless of Pins/activity; current then Dormant, even when Dormant was visited more recently")
        XCTAssertEqual(ids(list(input, [.topics], query: "alpha")), ["topic-a", "topic-d"], "on an equal match the last visit decides, not the Pin")
    }

    func testTopicActivityBreaksVisitTiesUsingAllMemberSessionsAndUnvisitedTopicsFollowVisitedOnes() {
        let records = [topic("a", "Alpha"), topic("b", "Beta"), topic("c", "Charlie"), topic("d", "Dormant"), TopicRecord(id: "e", title: "Empty")]
        let windows = [window("@1", session: "game/alpha", directory: "/work/game/main", topic: "a", activity: 1),
                       window("@2", session: "game/beta", directory: "/work/game/main", topic: "b", activity: 5),
                       window("@3", session: "notes/alpha", directory: "/work/notes", topic: "a", activity: 9),
                       window("@4", session: "game/charlie", directory: "/work/game/main", topic: "c", activity: 100)]
        let input = input(records: records, windows: windows, visits: [.topic(.topic("a")): 100, .topic(.topic("b")): 100, .topic(.topic("d")): 500])
        let listed = list(input, [.topics], query: "")
        XCTAssertEqual(ids(listed), ["topic-a", "topic-b", "topic-c", "topic-d", "topic-e"])
        XCTAssertEqual(listed.rows.last?.trailing, "Empty")
        XCTAssertEqual(listed.rows.last?.pick.payload, .topic(id: "e", state: .empty))
    }

    func testTypedTopicQueryRanksMatchesWithoutPushingCurrentDownOrDormantToBottom() {
        let records = [topic("a", "Alpha current"), topic("b", "Alpha another"), topic("c", "Alpha dormant")]
        let windows = [window("@1", session: "game/alpha", directory: "/work/game/main", topic: "a"),
                       window("@2", session: "game/beta", directory: "/work/game/main", topic: "b")]
        let input = input(records: records, windows: windows, current: .window(id: "@1"),
                          visits: [.topic(.topic("a")): 300, .topic(.topic("b")): 100])
        XCTAssertEqual(ids(list(input, [.topics], query: "alpha")), ["topic-a", "topic-b", "topic-c"])
        XCTAssertEqual(ids(list(input, [.topics], query: "dormant")), ["topic-c"], "a better match still outranks running Topics")
    }

    func testATagIsARowForAQueryAndItsFilterListsOnlyItsTopicsOpenAndSettled() throws {
        let backend = try XCTUnwrap(Tag(name: "backend"))
        var tagged = topic("a", "Alpha")
        tagged.tags = [backend]
        var settled = topic("s", "Settled")
        settled.settledAt = "2026-01-01T00:00:00Z"
        settled.tags = [backend]
        let input = input(records: [tagged, topic("b", "Beta"), settled], windows: [], tags: ConfigTags([TagDefinition(tag: backend)]))
        XCTAssertFalse(ids(list(input, query: "")).contains("tag-backend"), "a Tag shows for a query only")
        let typed = list(input, query: "#back")
        XCTAssertEqual(typed.sections.map(\.id), ["topics", "tags"])
        XCTAssertEqual(typed.sections[1].rows.map(\.pick.payload), [.tag(backend)])
        XCTAssertEqual(typed.sections[1].rows.map(\.trailing), ["2 Topics"])
        XCTAssertEqual(typed.sections[0].rows.first?.tags.map(\.text.text), ["#backend"])
        let filtered = input.list(goTo, query: "", tagFilter: backend, rules: .standard, order: .grouped, payload: { $0 })
        XCTAssertEqual(ids(filtered), ["topic-a", "topic-s"])
    }

    func testWithoutABoardTheTopicsSourceHasNoRows() {
        var input = input(records: [topic("a", "Alpha")], windows: [])
        input.board = nil
        XCTAssertEqual(list(input, query: "").sections.map(\.id), ["sessions"])
    }

    func testATargetIsOneKeyOnTheWire() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let pinned: [(GoToTarget, String)] = [
            (.topic(id: "t", state: .live), #"{"topic":{"id":"t","state":"live"}}"#),
            (.topic(id: "t", state: .dormant), #"{"topic":{"id":"t","state":"dormant"}}"#),
            (.settled(id: "t"), #"{"settled":{"id":"t"}}"#),
            (.boardSession(id: "s1"), #"{"board_session":{"id":"s1"}}"#),
            (.session(id: "$1", name: "api"), #"{"session":{"id":"$1","name":"api"}}"#),
            (.sessionPath(directory: "/code/api", name: "api"), #"{"session_path":{"directory":"/code/api","name":"api"}}"#),
            (.tag(try XCTUnwrap(Tag(name: "backend"))), #"{"tag":{"name":"backend"}}"#),
        ]
        for (target, json) in pinned {
            XCTAssertEqual(String(decoding: try encoder.encode(target), as: UTF8.self), json)
            XCTAssertEqual(try JSONDecoder().decode(GoToTarget.self, from: Data(json.utf8)), target)
        }
    }
}
