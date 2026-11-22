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

    /// Two Guest Sessions: `scratch` is live, `notes` is Dormant.
    private var contents: TopicContents {
        TopicContents(records: records, boardSessions: [BoardSession(id: "notes", order: 9), BoardSession(id: "scratch", order: 10)])
    }

    private var windows: [TmuxWindow] {
        [.fixture(topicID: "live"), .fixture(id: "@2", sessionID: "$2"), .fixture(id: "@3", sessionID: "$3", savedSessionID: "scratch")]
    }

    private let dormantTopics: [BoardCardID] = [.topic("pinned"), .topic("in-play"), .topic("guest"), .topic("bench-1"), .topic("bench-2")]

    func testTheKeyOffReopensNoTopic() {
        var reopen = ReopenAtLaunch()
        XCTAssertEqual(reopen.cards(in: "Local", enabled: false, contents: contents, windows: []), [])
        XCTAssertEqual(reopen.cards(in: "Local", enabled: false, contents: contents, windows: windows), [])
    }

    func testTheKeyOnReopensEveryDormantOpenTopicAndGuestSessionAndNoSettledEmptyOrLiveOne() {
        var reopen = ReopenAtLaunch()
        XCTAssertEqual(reopen.cards(in: "Local", enabled: true, contents: contents, windows: windows), dormantTopics + [.session("notes")])
    }

    func testAfterARestartEveryOpenTopicThatRemembersASessionAndEveryGuestSessionIsChosen() {
        XCTAssertEqual(ReopenAtLaunch.dormant(contents: contents, windows: []),
                       dormantTopics + [.topic("live"), .session("notes"), .session("scratch")])
    }

    func testEachEnvironmentGetsOneAnswerPerLaunchSoATmuxRestartReopensNothing() {
        var reopen = ReopenAtLaunch()
        XCTAssertEqual(reopen.cards(in: "Local", enabled: true, contents: contents, windows: windows).count, 6)
        // The tmux server restarted while Muxify ran: every open Topic and Guest Session is Dormant again.
        XCTAssertEqual(reopen.cards(in: "Local", enabled: true, contents: contents, windows: []), [])
        XCTAssertEqual(reopen.cards(in: "devbox", enabled: true, contents: contents, windows: windows).count, 6)
        XCTAssertEqual(reopen.cards(in: "devbox", enabled: true, contents: contents, windows: windows), [])
    }

    func testTheFirstAnswerCountsEvenWithTheKeyOff() {
        var reopen = ReopenAtLaunch()
        XCTAssertEqual(reopen.cards(in: "Local", enabled: false, contents: contents, windows: []), [])
        // Turning the key on while Muxify runs waits for the next launch.
        XCTAssertEqual(reopen.cards(in: "Local", enabled: true, contents: contents, windows: []), [])
    }
}
