import XCTest
@testable import MuxifyCore

final class TopicGroupsTests: XCTestCase {
    private func window(_ id: String, session: String, topic: String?) -> TmuxWindow {
        TmuxWindow(id: id, sessionID: session, sessionName: "app/" + (topic ?? "plain"), index: 0, name: "editor",
                   paneTitle: "editor", path: "/work/app", command: "zsh", isActive: true, paneCount: 1, hasBell: false,
                   sessionActivity: 0, agent: "", storedBrowser: StoredBrowser(), openRequests: [], topicID: topic,
                   sessionPath: "/work/app")
    }

    private func settled(_ id: String, at: String, outcome: String? = nil) -> TopicRecord {
        var record = TopicRecord(id: id, title: id.capitalized)
        record.settledAt = at
        record.outcome = outcome
        record.sessions = [.object(["id": .string("saved"), "name": .string("app/fix-links"), "base_name": .string("app/fix-links"), "directory": .string("/work/app"),
                                    "windows": .array([.object(["name": .string("server"), "directory": .string("/work/app/srv")]),
                                                       .object(["name": .string("shell")])])])]
        return record
    }

    private func model(_ records: [TopicRecord], windows: [TmuxWindow] = [], mode: SidebarMode = .topics,
                       groups: TopicGroupsState = TopicGroupsState(), selection: TopicSelection = TopicSelection(), location: Location? = nil) -> TopicsModel {
        TopicsModel(records: records, windows: windows, config: Config(), selection: selection,
                        location: location ?? selection.windowID.flatMap(WindowID.init(rawValue:)).map(Location.window), mode: mode, groups: groups)
    }

    func testGroupsFollowTheOpenTopicsInTopicsModeOnlyAndHideWhenEmpty() {
        let open = TopicRecord(id: "open", title: "Open")
        let records = [open, settled("done", at: "2026-10-01T10:00:00Z")]
        let windows = [window("@1", session: "$1", topic: "open"), window("@2", session: "$2", topic: nil)]
        let topics = model(records, windows: windows)
        XCTAssertEqual(topics.rows.map(\.id), [.topic("open")])
        XCTAssertEqual(topics.groups.map(\.kind), [.settled])
        XCTAssertEqual(topics.groups.map(\.count), [1])
        XCTAssertEqual(topics.groups.map(\.isExpanded), [false], "the group is collapsed until the user opens it")
        XCTAssertEqual(model(records, windows: windows, mode: .sessions).groups.map(\.kind), [])
        XCTAssertEqual(model([open]).groups.map(\.kind), [])
    }

    func testTitlesNameOpenAndShownSettledTopics() {
        let untitled = TopicRecord(id: "blank")
        let records = [TopicRecord(id: "open", title: "Open"), untitled]
            + (1...16).map { settled("done-\($0)", at: "2026-10-\(String(format: "%02d", $0))T10:00:00Z") }
        let titles = model(records).titles
        XCTAssertEqual(titles["open"], "Open")
        XCTAssertEqual(titles["blank"], "Untitled 1", "an untitled Topic keeps the number its row shows")
        XCTAssertEqual(titles["done-16"], "Done-16")
        XCTAssertNil(titles["done-1"], "a Settled Topic beyond the shown page has no row and no title")
    }

    func testPinnedTopicsComeFirstInTheOpenRows() {
        func pinned(_ record: TopicRecord) -> TopicRecord {
            var record = record
            record.isPinned = true
            return record
        }
        var open = TopicRecord(id: "open", title: "Open")
        open.order = 0
        var pin = pinned(TopicRecord(id: "pin", title: "Pin"))
        pin.order = 5
        let topics = model([open, pin])
        XCTAssertEqual(topics.rows.map(\.id), [.topic("pin"), .topic("open")])
        XCTAssertEqual(topics.rows.map(\.isPinned), [true, false])
    }

    func testSettledRowsShowNewestFirstWithOutcomeOrDateAndRememberedSessions() {
        let records = [settled("older", at: "2026-10-01T10:00:00Z"), settled("newer", at: "2026-10-05T10:00:00Z", outcome: "Shipped")]
        var selection = TopicSelection()
        selection.setTopic(.topic("newer"), open: true)
        let group = model(records, selection: selection).groups.first { $0.kind == .settled }!
        XCTAssertEqual(group.topics.map(\.id), [.topic("newer"), .topic("older")])
        XCTAssertEqual(group.topics[0].kind, .settled(detail: "Shipped"))
        XCTAssertEqual(group.topics[1].kind, .settled(detail: settledOn("2026-10-01T10:00:00Z")))
        XCTAssertTrue(group.topics[0].isExpanded)
        XCTAssertFalse(group.topics[0].isDormant, "a Settled Topic is not Dormant, it is done")
        let session = group.topics[0].sessions[0]
        XCTAssertEqual(session.baseName, "app/fix-links")
        guard case .remembered(let windows) = session.contents else { return XCTFail("remembered Windows expected") }
        XCTAssertEqual(windows.map(\.name), ["server", "shell"])
        XCTAssertEqual(windows.map(\.directory), ["/work/app/srv", "/work/app"])
        XCTAssertTrue(session.windows.isEmpty, "remembered Windows are never live Windows")
    }

    func testSettledGroupShowsFifteenPerPageAndCollapsingResetsThePages() {
        let records = (0..<32).map { settled(String(format: "topic-%02d", $0), at: String(format: "2026-09-%02dT10:00:00Z", $0 % 30 + 1)) }
        var state = TopicGroupsState()
        state.toggle(.settled)
        let firstPage = model(records, groups: state).groups[0]
        XCTAssertEqual(firstPage.count, 32)
        XCTAssertEqual(firstPage.topics.count, 15)
        XCTAssertEqual(firstPage.hiddenCount, 17)
        XCTAssertEqual(firstPage.topics.first?.id, .topic("topic-29"), "the newest Settled Topic comes first")
        state.showMoreSettled()
        let secondPage = model(records, groups: state).groups[0]
        XCTAssertEqual(secondPage.topics.count, 30)
        XCTAssertEqual(secondPage.hiddenCount, 2)
        state.showMoreSettled()
        XCTAssertEqual(model(records, groups: state).groups[0].hiddenCount, 0)
        state.toggle(.settled)
        state.toggle(.settled)
        XCTAssertEqual(model(records, groups: state).groups[0].topics.count, 15, "collapsing Settled forgets the extra pages")
        XCTAssertTrue(model(records, groups: state).groups[0].isExpanded)
    }

    func testTheOpenGroupFollowsTheActiveTopicOnlyWhenItsPlaceChanges() {
        let older = (0..<20).map { settled(String(format: "old-%02d", $0), at: "2026-09-01T10:00:00Z") }
        let records = [TopicRecord(id: "open", title: "Open"), settled("done", at: "2026-10-01T10:00:00Z")] + older
        let windows = [window("@1", session: "$1", topic: "open"), window("@3", session: "$3", topic: nil)]
        var state = TopicGroupsState()
        func follow(window: String? = nil, empty: String? = nil, records: [TopicRecord] = records) {
            var selection = TopicSelection()
            selection.windowID = window
            state.follow(model(records, windows: windows, groups: state, selection: selection, location: empty.map { .emptyTopic(.topic($0)) }))
        }

        follow(empty: "old-00")
        XCTAssertEqual(state.open, .settled, "going to a Settled Topic opens the Settled group")
        XCTAssertEqual(state.settledPages, 2, "the Settled group shows the page that lists the Active Topic")
        state.toggle(.settled)
        XCTAssertEqual(state.settledPages, 1)
        follow(empty: "old-00")
        XCTAssertNil(state.open, "a header click stays while the Active Topic stays in its group")

        state.toggle(.settled)
        follow(window: "@1")
        XCTAssertNil(state.open, "going to a Topic in the Topics list closes the open group")
        state.toggle(.settled)
        follow(window: "@3")
        XCTAssertNil(state.open, "going to No Topic closes the open group")

        follow(empty: "done")
        XCTAssertEqual(state.open, .settled)
        var reopened = records
        reopened[1].settledAt = nil
        follow(empty: "done", records: reopened)
        XCTAssertNil(state.open, "a Reopen of the Active Topic closes the group")
    }

    private func settledOn(_ stored: String) -> String {
        ISO8601DateFormatter().date(from: stored)!.formatted(date: .abbreviated, time: .omitted)
    }
}
