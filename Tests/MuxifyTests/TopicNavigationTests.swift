import XCTest
@testable import MuxifyCore

final class TopicNavigationTests: XCTestCase {
    private func window(_ id: String, topic: String?, active: Bool = true) -> TmuxWindow {
        TmuxWindow(id: id, sessionID: "$" + (topic ?? "none"), sessionName: "app/" + (topic ?? "none"), index: 0,
                   name: "editor", paneTitle: "editor", path: "/work/app", command: "zsh",
                   isActive: active, paneCount: 1, hasBell: false, sessionActivity: 0, agent: "",
                   storedBrowser: StoredBrowser(), openRequests: [], topicID: topic, sessionPath: "/work/app")
    }

    private func model(_ records: [TopicRecord], _ windows: [TmuxWindow], _ selection: TopicSelection) -> TopicsModel {
        TopicsModel(records: records, windows: windows, config: Config(), selection: selection,
                        location: selection.windowID.flatMap(WindowID.init(rawValue:)).map(Location.window))
    }

    private func visit(_ id: String, topic: String, selection: inout TopicSelection) {
        selection.select(windowID: id, activeTopic: .topic(topic))
    }

    func testEachTopicRemembersTheWindowLastLookedAtAcrossRepeatedSnapshots() {
        var selection = TopicSelection()
        visit("@1", topic: "a", selection: &selection)
        visit("@2", topic: "a", selection: &selection)
        visit("@3", topic: "b", selection: &selection)
        visit("@4", topic: "c", selection: &selection)
        for _ in 0..<5 { visit("@4", topic: "c", selection: &selection) }
        XCTAssertEqual(selection.lastWindowByGroup, [.topic("a"): "@2", .topic("b"): "@3", .topic("c"): "@4"])
        visit("@5", topic: "c", selection: &selection)
        XCTAssertEqual(selection.lastWindowByGroup[.topic("c")], "@5")
    }

    func testNoTopicRemembersItsWindowAndANilSelectionForgetsNothing() {
        var selection = TopicSelection()
        visit("@1", topic: "a", selection: &selection)
        selection.select(windowID: "@2", activeTopic: .noTopic)
        selection.select(windowID: nil, activeTopic: nil)
        XCTAssertEqual(selection.lastWindowByGroup, [.topic("a"): "@1", .noTopic: "@2"])
        selection.select(windowID: "@2", activeTopic: .noTopic)
        visit("@2", topic: "b", selection: &selection)
        XCTAssertEqual(selection.lastWindowByGroup[.topic("b")], "@2")
    }

    func testManualReorderChangesSidebarOrder() throws {
        let records = [TopicRecord(id: "a"), TopicRecord(id: "b"), TopicRecord(id: "c"), TopicRecord(id: "d")]
        var selection = TopicSelection()
        visit("@1", topic: "a", selection: &selection)
        visit("@2", topic: "b", selection: &selection)
        let edits = try TopicOrder.moving(.topic("d"), to: .before(.topic("c")), in: records.map(TopicListEntry.topic)).records
        let updated = records.map { record in edits.first { $0.id == record.id } ?? record }
        let result = model(updated, [window("@1", topic: "a"), window("@2", topic: "b")], selection)
        XCTAssertEqual(result.rows.map(\.id), [.topic("a"), .topic("b"), .topic("d"), .topic("c")])
    }

    func testNextTopicUsesVisibleOrderThenFallsBackToNoTopic() {
        var a = TopicRecord(id: "a")
        a.order = 2
        var b = TopicRecord(id: "b")
        b.order = 1
        var settled = TopicRecord(id: "settled")
        settled.settledAt = "2026-01-01T00:00:00Z"
        let result = model([a, settled, b], [], TopicSelection())
        XCTAssertEqual(result.nextTopic(after: "b"), .topic("a"))
        XCTAssertEqual(result.nextTopic(after: "a"), .topic("b"))
        XCTAssertEqual(model([a, settled], [], TopicSelection()).nextTopic(after: "a"), .noTopic)
    }

    func testNextTopicSkipsTheOtherTopicsThatLeaveTheList() {
        let records = ["a", "b", "c", "d", "e"].enumerated().map { index, id -> TopicRecord in
            var record = TopicRecord(id: id)
            record.order = Double(index)
            return record
        }
        let result = model(records, [], TopicSelection())
        XCTAssertEqual(result.nextTopic(after: "b", skipping: ["c", "d"]), .topic("e"), "the nearest row below that stays")
        XCTAssertEqual(result.nextTopic(after: "d", skipping: ["e", "c"]), .topic("b"), "else the nearest row above that stays")
        XCTAssertEqual(result.nextTopic(after: "a", skipping: ["b", "c", "d", "e"]), .noTopic)
    }

}
