import XCTest
@testable import MuxifyCore

final class TopicGroupsTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-07T08:00:00Z")!

    private func window(_ id: String, session: String, topic: String?) -> TmuxWindow {
        TmuxWindow(id: id, sessionID: session, sessionName: "app/" + (topic ?? "plain"), index: 0, name: "editor",
                   paneTitle: "editor", path: "/work/app", command: "zsh", isActive: true, paneCount: 1, hasBell: false,
                   sessionActivity: 0, agent: "", storedBrowser: StoredBrowser(), openRequests: [], topicID: topic,
                   sessionPath: "/work/app")
    }

    private func snoozed(_ id: String, until: SnoozeDeadline, order: Double) -> TopicRecord {
        var record = TopicRecord(id: id, title: id.capitalized)
        record.snoozedUntil = until.stored
        record.order = order
        return record
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
                       groups: TopicGroupsState = TopicGroupsState(), selection: TopicSelection = TopicSelection()) -> TopicsModel {
        TopicsModel(records: records, windows: windows, config: Config(), selection: selection, mode: mode, groups: groups, now: now)
    }

    func testGroupsFollowTheOpenTopicsInTopicsModeOnlyAndHideWhenEmpty() {
        let open = TopicRecord(id: "open", title: "Open")
        let records = [open, snoozed("later", until: .never, order: 1), settled("done", at: "2026-10-01T10:00:00Z")]
        let windows = [window("@1", session: "$1", topic: "open"), window("@2", session: "$2", topic: nil)]
        let topics = model(records, windows: windows)
        XCTAssertEqual(topics.rows.map(\.id), [.topic("open")])
        XCTAssertEqual(topics.groups.map(\.kind), [.snoozed, .settled])
        XCTAssertEqual(topics.groups.map(\.count), [1, 1])
        XCTAssertEqual(topics.groups.map(\.isExpanded), [false, false], "groups are collapsed until the user opens them")
        XCTAssertEqual(model(records, windows: windows, mode: .sessions).groups.map(\.kind), [])
        XCTAssertEqual(model([open, records[2]]).groups.map(\.kind), [.settled])
        XCTAssertEqual(model([open, records[1]]).groups.map(\.kind), [.snoozed])
        XCTAssertEqual(model([open]).groups.map(\.kind), [])
    }

    func testTitlesNameOpenSnoozedAndShownSettledTopics() {
        let untitled = TopicRecord(id: "blank")
        let records = [TopicRecord(id: "open", title: "Open"), untitled, snoozed("later", until: .never, order: 1)]
            + (1...16).map { settled("done-\($0)", at: "2026-10-\(String(format: "%02d", $0))T10:00:00Z") }
        let titles = model(records).titles
        XCTAssertEqual(titles["open"], "Open")
        XCTAssertEqual(titles["blank"], "Untitled 1", "an untitled Topic keeps the number its row shows")
        XCTAssertEqual(titles["later"], "Later", "a Snoozed Topic is a destination of Move to Topic and keeps its title")
        XCTAssertEqual(titles["done-16"], "Done-16")
        XCTAssertNil(titles["done-1"], "a Settled Topic beyond the shown page has no row and no title")
    }

    func testSnoozedRowsShowWakeTimeAndDormancy() {
        let wake = SnoozeDeadline.at(now.addingTimeInterval(3600))
        var second = snoozed("second", until: .never, order: 2)
        second.sessions = [.object(["repository_path": .string("/work/app")])]
        let records = [second, snoozed("first", until: wake, order: 1)]
        let topics = model(records, windows: [window("@1", session: "$1", topic: "first")])
        let group = topics.groups.first { $0.kind == .snoozed }!
        XCTAssertEqual(group.topics.map(\.id), [.topic("first"), .topic("second")])
        XCTAssertEqual(group.topics[0].kind, .snoozed(wake: wake.wakeLabel))
        XCTAssertEqual(group.topics[0].sessions.flatMap(\.windows).map(\.id), ["@1"], "a snoozed Topic lists its live Windows")
        XCTAssertFalse(group.topics[0].isDormant)
        XCTAssertEqual(group.topics[1].kind, .snoozed(wake: "never"))
        XCTAssertTrue(group.topics[1].isDormant)
        XCTAssertFalse(topics.rows.contains { $0.id == .topic("first") }, "a snoozed Topic is not an open row")
    }

    func testSnoozedRowsGoByWakeTimeSoonestFirstWithUntilUnsnoozeLastAndIgnoreThePin() {
        func pinned(_ record: TopicRecord) -> TopicRecord {
            var record = record
            record.isPinned = true
            return record
        }
        let soon = SnoozeDeadline.at(now.addingTimeInterval(3600))
        let late = SnoozeDeadline.at(now.addingTimeInterval(7200))
        let records = [snoozed("forever", until: .never, order: 0), pinned(snoozed("pinned-late", until: late, order: 1)),
                       snoozed("late", until: late, order: 2), snoozed("soon", until: soon, order: 3),
                       snoozed("forever-too", until: .never, order: 4)]
        let topics = model(records)
        let expected: [TopicGroupID] = [.topic("soon"), .topic("pinned-late"), .topic("late"), .topic("forever"), .topic("forever-too")]
        XCTAssertEqual(topics.snoozedRows.map(\.id), expected, "equal times keep the list order, where the Pinned Topic is first")
        XCTAssertEqual(topics.groups.first { $0.kind == .snoozed }?.topics.map(\.id), expected)
        XCTAssertEqual(model(records, mode: .sessions).snoozedRows.map(\.id), expected, "Sessions mode lists them in the same order")
    }

    func testPinnedTopicsComeFirstInTheOpenRowsAndTheSnoozedGroup() {
        func pinned(_ record: TopicRecord) -> TopicRecord {
            var record = record
            record.isPinned = true
            return record
        }
        var open = TopicRecord(id: "open", title: "Open")
        open.order = 0
        var pin = pinned(TopicRecord(id: "pin", title: "Pin"))
        pin.order = 5
        let records = [open, pin, snoozed("asleep", until: .never, order: 0), pinned(snoozed("pinned-asleep", until: .never, order: 9))]
        let topics = model(records)
        XCTAssertEqual(topics.rows.map(\.id), [.topic("pin"), .topic("open")])
        XCTAssertEqual(topics.rows.map(\.isPinned), [true, false])
        XCTAssertEqual(topics.groups.first { $0.kind == .snoozed }?.topics.map(\.id), [.topic("pinned-asleep"), .topic("asleep")])
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

    func testOpeningAGroupClosesTheOtherAndClosingSettledForgetsItsPages() {
        var state = TopicGroupsState()
        state.toggle(.settled)
        state.showMoreSettled()
        state.toggle(.snoozed)
        XCTAssertEqual(state.open, .snoozed, "opening Snoozed closes Settled")
        XCTAssertEqual(state.settledPages, 1, "leaving Settled forgets its extra pages")
        state.toggle(.snoozed)
        XCTAssertNil(state.open)
    }

    func testTheOpenGroupFollowsTheActiveTopicOnlyWhenItsPlaceChanges() {
        let wake = SnoozeDeadline.at(now.addingTimeInterval(3600))
        let older = (0..<20).map { settled(String(format: "old-%02d", $0), at: "2026-09-01T10:00:00Z") }
        let records = [TopicRecord(id: "open", title: "Open"), snoozed("asleep", until: wake, order: 1),
                       settled("done", at: "2026-10-01T10:00:00Z")] + older
        let windows = [window("@1", session: "$1", topic: "open"), window("@2", session: "$2", topic: "asleep"),
                       window("@3", session: "$3", topic: nil)]
        var state = TopicGroupsState()
        func follow(window: String? = nil, empty: String? = nil, records: [TopicRecord] = records) {
            var selection = TopicSelection()
            selection.windowID = window
            selection.emptyTopicID = empty
            state.follow(model(records, windows: windows, groups: state, selection: selection))
        }

        follow(window: "@2")
        XCTAssertEqual(state.open, .snoozed, "going to a Snoozed Topic opens the Snoozed group")
        state.toggle(.snoozed)
        follow(window: "@2")
        XCTAssertNil(state.open, "a header click stays while the Active Topic stays in its group")

        follow(empty: "old-00")
        XCTAssertEqual(state.open, .settled, "going to a Settled Topic opens the Settled group")
        XCTAssertEqual(state.settledPages, 2, "the Settled group shows the page that lists the Active Topic")

        state.toggle(.snoozed)
        XCTAssertEqual(state.settledPages, 1)
        follow(window: "@1")
        XCTAssertNil(state.open, "going to a Topic in the Topics list closes the open group")
        state.toggle(.settled)
        follow(window: "@3")
        XCTAssertNil(state.open, "going to No Topic closes the open group")

        follow(window: "@2")
        XCTAssertEqual(state.open, .snoozed)
        var awake = records
        awake[1].snoozedUntil = nil
        follow(window: "@2", records: awake)
        XCTAssertNil(state.open, "an Unsnooze of the Active Topic closes the group")
    }

    private func settledOn(_ stored: String) -> String {
        ISO8601DateFormatter().date(from: stored)!.formatted(date: .abbreviated, time: .omitted)
    }
}
