import XCTest
@testable import MuxifyCore

final class TopicNavigationTests: XCTestCase {
    private func model(_ records: [TopicRecord], _ windows: [TmuxWindow], _ selection: TopicSelection,
                       inPlay: Int = Config.Topics.defaultInPlay) -> TopicsModel {
        var config = Config()
        config.topics.inPlay = inPlay
        return TopicsModel(records: records, windows: windows, config: config, selection: selection,
                        location: selection.windowLocation)
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

    func testNextTopicSkipsTheOtherTopicsThatLeaveTheList() {
        let records = ["a", "b", "c", "d", "e"].enumerated().map { index, id -> TopicRecord in
            var record = TopicRecord(id: id)
            record.order = Double(index)
            return record
        }
        let result = model(records, [], TopicSelection(), inPlay: 5)
        XCTAssertEqual(result.nextTopic(after: .topic("b"), skipping: ["c", "d"]), .topic("e"), "the nearest row below that stays")
        XCTAssertEqual(result.nextTopic(after: .topic("d"), skipping: ["e", "c"]), .topic("a"), "else the first In Play card that stays")
        XCTAssertEqual(result.nextTopic(after: .topic("a"), skipping: ["b", "c", "d", "e"]), .noTopic)
    }

}
