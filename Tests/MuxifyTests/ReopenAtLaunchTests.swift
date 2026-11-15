import XCTest
@testable import MuxifyCore
import MuxifyTestSupport

final class ReopenAtLaunchTests: XCTestCase {
    private func topic(_ id: String, remembers: Bool = true, settled: Bool = false, pinned: Bool = false, guest: Bool = false,
                       order: Double = 0) -> TopicRecord {
        var record = TopicRecord(id: id, title: id)
        record.order = order
        record.isPinned = pinned
        record.isGuest = guest
        if settled { record.settledAt = "2026-11-01T10:00:00Z" }
        if remembers { record.sessions = [.object(["id": .string("s-" + id), "name": .string(id), "directory": .string("/tmp")])] }
        return record
    }

    /// Pinned, In Play, a Guest and two on the Bench (with `in_play: 1`) are Dormant; the others are not.
    private var records: [TopicRecord] {
        [topic("pinned", pinned: true), topic("in-play", order: 0), topic("guest", guest: true, order: 1),
         topic("bench-1", order: 2), topic("bench-2", order: 3),
         topic("settled", settled: true), topic("empty", remembers: false), topic("live", order: 4)]
    }

    private var windows: [TmuxWindow] { [.fixture(topicID: "live"), .fixture(id: "@2", sessionID: "$2")] }

    func testTheKeyOffReopensNoTopic() {
        var reopen = ReopenAtLaunch()
        XCTAssertEqual(reopen.topics(in: "Local", enabled: false, records: records, windows: []), [])
        XCTAssertEqual(reopen.topics(in: "Local", enabled: false, records: records, windows: windows), [])
    }

    func testTheKeyOnReopensEveryDormantOpenTopicAndNoSettledEmptyOrLiveOne() {
        var reopen = ReopenAtLaunch()
        XCTAssertEqual(reopen.topics(in: "Local", enabled: true, records: records, windows: windows),
                       ["pinned", "in-play", "guest", "bench-1", "bench-2"])
    }

    func testAfterARestartEveryOpenTopicThatRemembersASessionIsChosen() {
        XCTAssertEqual(ReopenAtLaunch.dormant(records: records, windows: []), ["pinned", "in-play", "guest", "bench-1", "bench-2", "live"])
    }

    func testEachEnvironmentGetsOneAnswerPerLaunchSoATmuxRestartReopensNothing() {
        var reopen = ReopenAtLaunch()
        XCTAssertEqual(reopen.topics(in: "Local", enabled: true, records: records, windows: windows).count, 5)
        // The tmux server restarted while Muxify ran: every open Topic is Dormant again.
        XCTAssertEqual(reopen.topics(in: "Local", enabled: true, records: records, windows: []), [])
        XCTAssertEqual(reopen.topics(in: "devbox", enabled: true, records: records, windows: windows).count, 5)
        XCTAssertEqual(reopen.topics(in: "devbox", enabled: true, records: records, windows: windows), [])
    }

    func testTheFirstAnswerCountsEvenWithTheKeyOff() {
        var reopen = ReopenAtLaunch()
        XCTAssertEqual(reopen.topics(in: "Local", enabled: false, records: records, windows: []), [])
        // Turning the key on while Muxify runs waits for the next launch.
        XCTAssertEqual(reopen.topics(in: "Local", enabled: true, records: records, windows: []), [])
    }
}
