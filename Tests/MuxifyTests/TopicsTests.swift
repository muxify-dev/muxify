import XCTest
@testable import MuxifyCore

final class TopicsTests: XCTestCase {
    private func window(_ id: String, session: String, topic: String? = nil, path: String = "/work/app") -> TmuxWindow {
        TmuxWindow(id: id, sessionID: session, sessionName: "renamed-by-hand", index: 0,
                   name: "editor", paneTitle: "editor", path: "/different/active/pane", command: "zsh",
                   isActive: true, paneCount: 1, hasBell: true, sessionActivity: 0, agent: "",
                   storedBrowser: StoredBrowser(), openRequests: [], topicID: topic, sessionPath: path)
    }

    func testWatcherLoadsFolderCreatedAfterStartAndExternalRewrites() throws {
        let state = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: state) }
        let paths = MuxifyPaths(environment: ["XDG_STATE_HOME": state.path], home: "/nonexistent")
        let directory = paths.topics
        let store = TopicWatcher(store: TopicStore(paths: paths))
        store.start()
        XCTAssertTrue(store.records.isEmpty)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("external.json")
        try Data(#"{"id":"external","title":"First"}"#.utf8).write(to: file, options: .atomic)
        let appeared = expectation(description: "external Topic appears within one second")
        let firstTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { timer in
            if store.records.first?.title == "First" { timer.invalidate(); appeared.fulfill() }
        }
        wait(for: [appeared], timeout: 0.95)
        firstTimer.invalidate()
        try Data(#"{"id":"external","title":"Second"}"#.utf8).write(to: file, options: .atomic)
        let changed = expectation(description: "external replacement appears within one second")
        let secondTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { timer in
            if store.records.first?.title == "Second" { timer.invalidate(); changed.fulfill() }
        }
        wait(for: [changed], timeout: 0.95)
        secondTimer.invalidate()
        try FileManager.default.removeItem(at: file)
        store.reload()
        XCTAssertTrue(store.records.isEmpty)
    }

    func testGroupingSessionPathLabelsWorktreeAndDormantTopics() {
        var topic = TopicRecord(id: "a", title: "Fix reward")
        topic.sessions = [.object(["repository_path": .string("/work/app"), "worktree_path": .string("/trees/fix")]),
                          .object(["repository_path": .string("/work/app/tools")])]
        var dormant = TopicRecord(id: "b", slug: "untitled-3")
        dormant.sessions = [.object(["id": .string("saved"), "name": .string("debug/untitled-3"), "base_name": .string("debug"), "directory": .string("/work/app")])]
        var settled = TopicRecord(id: "settled", title: "Done")
        settled.settledAt = "2026-10-06T20:00:00Z"
        let windows = [window("@1", session: "$1", topic: "a", path: "/trees/fix/src"),
                       window("@2", session: "$1", topic: "a", path: "/trees/fix/src"),
                       window("@3", session: "$2", topic: "a", path: "/work/app/tools/bin"),
                       window("@4", session: "$3", topic: "a", path: "/work/application"),
                       window("@5", session: "$4"), window("@6", session: "$5", topic: "missing"),
                       window("@7", session: "$6", topic: "settled")]
        let model = TopicsModel(records: [topic, dormant, settled], windows: windows, config: Config(), selection: TopicSelection())
        XCTAssertEqual(model.rows.map(\.title), ["Fix reward", "Untitled 3"])
        XCTAssertEqual(model.rows[0].sessions.map(\.baseName), ["renamed-by-hand", "renamed-by-hand", "renamed-by-hand"])
        XCTAssertEqual(model.rows[0].sessions[0].windows.count, 2)
        XCTAssertFalse(model.rows[0].isDormant)
        XCTAssertTrue(model.rows[1].isDormant)
        XCTAssertEqual(model.rows[1].idleLabel, "Dormant")
        XCTAssertEqual(model.noTopicSessions.count, 3)
    }

    func testANewActiveTopicOpensAloneAndTheUserCanCloseIt() {
        let records = [TopicRecord(id: "a"), TopicRecord(id: "b"), TopicRecord(id: "no-topic")]
        let windows = [window("@1", session: "$1", topic: "a"), window("@2", session: "$1", topic: "a"),
                       window("@3", session: "$2", topic: "b"), window("@4", session: "$3")]
        var selection = TopicSelection()
        func open() -> Set<TopicGroupID> {
            Set(TopicsModel(records: records, windows: windows, config: Config(), selection: selection).rows.filter(\.isExpanded).map(\.id))
        }
        selection.select(windowID: "@1", activeTopic: .topic("a"))
        XCTAssertEqual(open(), [.topic("a")], "only the Active Topic is open at start")
        selection.setTopic(.topic("b"), open: true)
        selection.setTopic(.topic("b"), open: true)
        XCTAssertEqual(open(), [.topic("a"), .topic("b")], "opening an open Topic keeps it open")
        selection.setTopic(.topic("a"), open: false)
        XCTAssertEqual(open(), [.topic("b")], "the Active Topic closes like any other")
        selection.select(windowID: "@2", activeTopic: .topic("a"))
        XCTAssertEqual(open(), [.topic("b")], "another Window of the same Topic keeps what the user opened and closed")
        selection.select(windowID: "@3", activeTopic: .topic("b"))
        XCTAssertEqual(open(), [.topic("b")], "a new Active Topic opens alone")
        selection.select(windowID: "@4", activeTopic: .noTopic)
        XCTAssertEqual(selection.openTopics(for: .noTopic), [], "No Topic has no card to open")
        XCTAssertNotEqual(TopicGroupID.noTopic, .topic("no-topic"))
    }

    func testTheModelOpensTheNewActiveTopicBeforeTheSelectionCatchesUp() {
        let records = [TopicRecord(id: "a"), TopicRecord(id: "b")]
        let windows = [window("@1", session: "$1", topic: "a"), window("@2", session: "$2", topic: "b")]
        var selection = TopicSelection()
        selection.select(windowID: "@1", activeTopic: .topic("a"))
        selection.setTopic(.topic("a"), open: false)
        selection.windowID = "@2"
        let rows = TopicsModel(records: records, windows: windows, config: Config(), selection: selection).rows
        XCTAssertEqual(rows.filter(\.isExpanded).map(\.id), [.topic("b")])
    }

    func testUntitledNumbersRemainStableWhenManualOrderChanges() {
        var first = TopicRecord(id: "a")
        var second = TopicRecord(id: "b", slug: "untitled-1")
        let third = TopicRecord(id: "c")
        func titles() -> [TopicGroupID: String] {
            let model = TopicsModel(records: [third, second, first], windows: [], config: Config(), selection: TopicSelection())
            return Dictionary(uniqueKeysWithValues: model.rows.map { ($0.id, $0.title) })
        }
        let before = titles()
        first.order = 20
        second.order = -10
        XCTAssertEqual(titles(), before)
        XCTAssertEqual(Set(before.values), ["Untitled 1", "Untitled 2", "Untitled 3"])
    }

    func testConfigControlsBothViewsAndToggle() {
        var config = Config()
        for topics in [false, true] {
            for sessions in [false, true] {
                config.sidebar.topics = topics
                config.sidebar.sessions = sessions
                let model = TopicsModel(records: [], windows: [], config: config, selection: TopicSelection())
                XCTAssertEqual(model.topicsEnabled, topics)
                XCTAssertEqual(model.sessionsEnabled, sessions)
                XCTAssertEqual(model.showsToggle, topics && sessions)
            }
        }
    }
}
