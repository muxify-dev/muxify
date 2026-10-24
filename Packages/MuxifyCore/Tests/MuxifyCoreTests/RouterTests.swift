import XCTest
@testable import MuxifyCore

final class RouterTests: XCTestCase {
    func testAnEmptyTopicPageEntersTheWindowThatAppears() {
        let target = WindowID(rawValue: "@2")!
        var router = Router()
        let page = Location.emptyTopic(.topic("work"))
        _ = router.handle(.go(page), .init(records: [TopicRecord(id: "work")]))
        let effects = router.handle(.read(1), .init(windows: [window("@2")], records: [TopicRecord(id: "work")],
                                                   entryWindows: [.topic("work"): target]))
        XCTAssertEqual(router.location, .window(target))
        XCTAssertTrue(effects.contains(.visit(.window(target))))
    }

    func testAGoChangesLocationBeforeTheCommandFinishesAndVisitsIt() throws {
        var router = Router()
        let target = id("@2")
        let effects = router.handle(.go(.window(target), readsOnArrival: true), .init(windows: [window("@2")]))
        let intent = try windowIntent(router)
        XCTAssertEqual(router.location, .window(target))
        XCTAssertEqual(effects, [.visit(.window(target)), .switchClient(target, intent: intent.id)])
        XCTAssertEqual(router.handle(.commandFinished(intent.id, .success, lastStartedRead: 4), .init()), [.enterRead(target)])
    }

    func testAGoToAPageCancelsAWindowIntentAndDoesNotMoveTheClient() throws {
        var router = Router()
        _ = router.handle(.go(.window(id("@1"))), .init())
        let old = try windowIntent(router)
        let page = Location.emptyTopic(.topic("work"))
        XCTAssertEqual(router.handle(.go(page), .init()), [.visit(page)])
        XCTAssertNil(router.intent)
        XCTAssertTrue(router.handle(.commandFinished(old.id, .failure, lastStartedRead: 1), .init()).isEmpty)
        XCTAssertEqual(router.location, page)
    }

    func testAReadBeforeCompletionCannotRecoverAMissingTarget() throws {
        var router = Router()
        let facts = Router.Facts(windows: [window("@1"), window("@2")], ownClientWindow: id("@1"))
        _ = router.handle(.read(1), facts)
        _ = router.handle(.go(.window(id("@2"))), facts)
        let pending = try windowIntent(router)
        let old = Router.Facts(windows: [window("@1")], ownClientWindow: id("@1"))
        XCTAssertTrue(router.handle(.read(2), old).isEmpty)
        XCTAssertEqual(router.location, .window(id("@2")))
        XCTAssertEqual(router.intent, .window(pending))
        _ = router.handle(.commandFinished(pending.id, .success, lastStartedRead: 3), facts)
        XCTAssertTrue(router.handle(.read(3), old).isEmpty)
        XCTAssertEqual(router.location, .window(id("@2")))
        XCTAssertNotNil(router.intent)
        _ = router.handle(.read(4), .init(windows: facts.windows, ownClientWindow: id("@2")))
        XCTAssertNil(router.intent)
        XCTAssertEqual(router.location, .window(id("@2")))
    }

    func testAFreshReadEndsAnIntentWithoutATimeLimit() throws {
        var router = Router()
        let facts = Router.Facts(windows: [window("@1"), window("@2"), window("@3")], ownClientWindow: id("@1"))
        _ = router.handle(.read(1), facts)
        _ = router.handle(.go(.window(id("@2"))), facts)
        let pending = try windowIntent(router)
        _ = router.handle(.commandFinished(pending.id, .success, lastStartedRead: 2), facts)
        let later = Router.Facts(windows: facts.windows, ownClientWindow: id("@3"), now: .distantFuture)
        _ = router.handle(.read(3), later)
        XCTAssertNil(router.intent)
        XCTAssertEqual(router.location, .window(id("@3")))
    }

    func testAnOldReadCannotCompleteAnIntentEvenWhenTheClientMatches() throws {
        var router = Router()
        let facts = Router.Facts(windows: [window("@2")], ownClientWindow: id("@2"))
        _ = router.handle(.go(.window(id("@2"))), facts)
        let pending = try windowIntent(router)
        _ = router.handle(.read(1), facts)
        XCTAssertNotNil(router.intent)
        _ = router.handle(.commandFinished(pending.id, .success, lastStartedRead: 2), facts)
        _ = router.handle(.read(2), facts)
        XCTAssertNotNil(router.intent)
        _ = router.handle(.read(3), facts)
        XCTAssertNil(router.intent)
    }

    func testACompletedIntentDoesNotFollowAClientThatDidNotMove() throws {
        var router = Router()
        let facts = Router.Facts(windows: [window("@1"), window("@2")], ownClientWindow: id("@1"))
        _ = router.handle(.read(1), facts)
        _ = router.handle(.go(.window(id("@2"))), facts)
        let pending = try windowIntent(router)
        _ = router.handle(.commandFinished(pending.id, .success, lastStartedRead: 2), facts)
        _ = router.handle(.read(3), facts)
        XCTAssertNil(router.intent)
        XCTAssertEqual(router.location, .window(id("@2")))
    }

    func testAnEarlierCommandCannotFinishANewerIntentToTheSameWindow() throws {
        var router = Router()
        _ = router.handle(.go(.window(id("@1"))), .init())
        let first = try windowIntent(router)
        _ = router.handle(.go(.window(id("@2"))), .init())
        _ = router.handle(.go(.window(id("@1"))), .init())
        let latest = try windowIntent(router)
        XCTAssertNotEqual(first.id, latest.id)
        for result in [Router.CommandResult.success, .failure] {
            XCTAssertTrue(router.handle(.commandFinished(first.id, result, lastStartedRead: 4), .init()).isEmpty)
            XCTAssertEqual(router.intent, .window(latest))
            XCTAssertEqual(router.location, .window(id("@1")))
        }
    }

    func testACommandFailureRestoresAWindowOrAnEmptyTopicPage() throws {
        for origin in [Location.window(id("@1")), .emptyTopic(.topic("work"))] {
            var router = Router()
            _ = router.handle(.go(origin), .init())
            _ = router.handle(.go(.window(id("@2"))), .init())
            let pending = try windowIntent(router)
            _ = router.handle(.commandFinished(pending.id, .failure, lastStartedRead: 2), .init())
            XCTAssertEqual(router.location, origin)
            XCTAssertNil(router.intent)
        }
    }

    func testATopicResultUsesTheCompletionReadBarrierWithoutAnotherSwitch() throws {
        var router = Router()
        let target = id("@2")
        let effects = router.handle(.result(.window(target), lastStartedRead: 3), .init())
        XCTAssertEqual(effects, [.visit(.window(target))])
        XCTAssertEqual(try windowIntent(router).finishedBefore, 3)
        _ = router.handle(.read(3), .init(windows: [window("@1")], ownClientWindow: id("@1")))
        XCTAssertEqual(router.location, .window(target))
        _ = router.handle(.read(4), .init(windows: [window("@2")], ownClientWindow: target))
        XCTAssertNil(router.intent)
        XCTAssertEqual(router.location, .window(target))
        XCTAssertTrue(router.handle(.result(nil, lastStartedRead: 4), .init()).isEmpty)
        XCTAssertEqual(router.location, .window(target))
    }

    func testAClientMoveChangesAWindowOrPageButAnUnchangedClientLeavesAPage() {
        for origin in [Location.window(id("@1")), .emptyTopic(.topic("work")), .emptyTopic(.noTopic)] {
            var router = Router()
            let facts = Router.Facts(windows: [window("@1"), window("@2")], ownClientWindow: id("@1"), records: [TopicRecord(id: "work")])
            _ = router.handle(.read(1), facts)
            if origin.windowID == nil { _ = router.handle(.go(origin), facts) }
            _ = router.handle(.read(2), facts)
            XCTAssertEqual(router.location, origin)
            var moved = facts
            moved.ownClientWindow = id("@2")
            XCTAssertEqual(router.handle(.read(3), moved), [.visit(.window(id("@2")))])
            XCTAssertEqual(router.location, .window(id("@2")))
            XCTAssertNil(router.intent)
        }
    }

    func testASettledRecordKeepsItsPageAndForgetReturnsToTheClient() {
        var router = Router()
        var settled = TopicRecord(id: "work")
        settled.settledAt = "2026-10-24T12:00:00Z"
        let facts = Router.Facts(windows: [window("@1")], ownClientWindow: id("@1"), records: [settled])
        _ = router.handle(.read(1), facts)
        _ = router.handle(.go(.emptyTopic(.topic("work"))), facts)
        XCTAssertTrue(router.handle(.read(2), facts).isEmpty)
        XCTAssertEqual(router.location, .emptyTopic(.topic("work")))
        var forgotten = facts
        forgotten.records = []
        XCTAssertEqual(router.handle(.read(3), forgotten), [.visit(.window(id("@1")))])
        XCTAssertEqual(router.location, .window(id("@1")))
    }

    func testNextTopicUsesItsEntryWindowAfterTheNextRead() {
        var router = Router()
        _ = router.handle(.go(.emptyTopic(.topic("old"))), .init())
        _ = router.handle(.settled(next: .topic("next")), .init())
        XCTAssertEqual(router.location, .emptyTopic(.topic("old")))
        let facts = Router.Facts(windows: [window("@1"), window("@2")], entryWindows: [.topic("next"): id("@2")])
        _ = router.handle(.read(1), facts)
        XCTAssertEqual(router.location, .window(id("@2")))
    }

    func testNextTopicWithoutAWindowShowsItsPageAndAMissingLockedSessionShowsNoTopic() {
        for (next, expected) in [(TopicGroupID.topic("work"), TopicGroupID.topic("work")), (.noTopic, .noTopic), (.locked("$1"), .noTopic)] {
            var router = Router()
            _ = router.handle(.settled(next: next), .init())
            XCTAssertEqual(router.handle(.read(1), .init()), [.visit(.emptyTopic(expected))])
            XCTAssertEqual(router.location, .emptyTopic(expected))
            XCTAssertNil(router.intent)
        }
    }

    func testRecoveryUsesTheNearestEarlierSiblingThenTheNextSibling() {
        let before = [window("@1"), window("@2"), window("@3"), window("@4")]
        for (selected, survivors, target) in [("@3", [before[0], before[1], before[3]], "@2"),
                                              ("@1", [before[1], before[2]], "@2"),
                                              ("@3", [before[0], before[3]], "@1")] {
            var router = Router()
            _ = router.handle(.read(1), .init(windows: before, ownClientWindow: id(selected)))
            _ = router.handle(.read(2), .init(windows: survivors))
            XCTAssertEqual(router.location, .window(id(target)))
        }
    }

    func testRecoveryKeepsItsSiblingInventoryThroughAProtectedRead() throws {
        var router = Router()
        let before = [window("@1"), window("@2"), window("@3")]
        _ = router.handle(.go(.window(id("@3"))), .init(windows: before))
        let pending = try windowIntent(router)
        _ = router.handle(.read(1), .init(windows: [before[0]]))
        _ = router.handle(.commandFinished(pending.id, .success, lastStartedRead: 1), .init())
        _ = router.handle(.read(2), .init(windows: [before[0], before[1]]))
        XCTAssertEqual(router.location, .window(id("@2")))
    }

    func testRecoveryFallsBackToThePreviousWindowThenTheFirstWindowThenNothing() {
        let before = [window("@1", sessionID: "$1"), window("@2", sessionID: "$2"), window("@3", sessionID: "$3")]
        for (survivors, target) in [([before[0], before[1]], Optional(id("@2"))), ([before[0]], Optional(id("@1"))), ([], nil)] {
            var router = Router()
            _ = router.handle(.read(1), .init(windows: before, ownClientWindow: id("@2")))
            _ = router.handle(.read(2), .init(windows: before, ownClientWindow: id("@3")))
            _ = router.handle(.read(3), .init(windows: survivors))
            XCTAssertEqual(router.location, target.map(Location.window))
        }
    }

    func testAPageAndRepeatedReadsDoNotEraseThePreviousWindow() {
        var router = Router()
        let before = [window("@1", sessionID: "$1"), window("@2", sessionID: "$2"), window("@3", sessionID: "$3")]
        _ = router.handle(.read(1), .init(windows: before, ownClientWindow: id("@2")))
        _ = router.handle(.read(2), .init(windows: before, ownClientWindow: id("@3")))
        _ = router.handle(.read(3), .init(windows: before, ownClientWindow: id("@3")))
        _ = router.handle(.go(.emptyTopic(.topic("work"))), .init())
        _ = router.handle(.result(.window(id("@3")), lastStartedRead: 3), .init(windows: before))
        _ = router.handle(.read(4), .init(windows: [before[0], before[1]]))
        XCTAssertEqual(router.location, .window(id("@2")))
    }

    func testAWindowOrSessionRequestWaitsUntilTheReadListsItsWindow() {
        let now = Date(timeIntervalSince1970: 100)
        for request in [SelectRequest.window("@2"), .session("made")] {
            var router = Router()
            _ = router.handle(.request(request, at: now), .init(now: now))
            XCTAssertNotNil(router.intent)
            _ = router.handle(.read(1), .init(windows: [window("@1")], now: now.addingTimeInterval(1)))
            XCTAssertNotNil(router.intent)
            _ = router.handle(.read(2), .init(windows: [window("@1"), window("@2", sessionName: "made")], now: now.addingTimeInterval(2)))
            XCTAssertEqual(router.location, .window(id("@2")))
        }
    }

    func testASessionRequestUsesItsActiveWindowOrItsFirstWindow() {
        for active in [true, false] {
            var router = Router()
            let windows = [window("@1", active: false), window("@2", active: active)]
            _ = router.handle(.request(.session("test"), at: .distantPast), .init(windows: windows, now: .distantPast))
            XCTAssertEqual(router.location, .window(id(active ? "@2" : "@1")))
        }
    }

    func testARequestExpiresWithoutAffectingTheLocation() {
        var router = Router()
        let now = Date(timeIntervalSince1970: 100)
        _ = router.handle(.go(.emptyTopic(.noTopic)), .init())
        _ = router.handle(.request(.window("@9"), at: now), .init(now: now))
        _ = router.handle(.read(1), .init(now: now.addingTimeInterval(6)))
        XCTAssertNil(router.intent)
        XCTAssertEqual(router.location, .emptyTopic(.noTopic))
    }

    func testATopicRequestUsesOnlyOpenRecordsAndDelegatesReopenOnARead() {
        var router = Router()
        let now = Date(timeIntervalSince1970: 100)
        let record = TopicRecord(id: "work")
        let facts = Router.Facts(records: [record], now: now)
        XCTAssertTrue(router.handle(.request(.topic("work"), at: now), facts).isEmpty)
        var settled = facts
        settled.records[0].settledAt = "2026-10-24T12:00:00Z"
        XCTAssertTrue(router.handle(.read(1), settled).isEmpty)
        XCTAssertNotNil(router.intent)
        XCTAssertEqual(router.handle(.read(2), facts), [.requestTopic(.topic("work"))])
        XCTAssertNil(router.intent)
    }

    func testARequestBeforeStartupWaitsForAReadThatCanAttach() throws {
        var router = Router()
        let now = Date(timeIntervalSince1970: 100)
        var facts = Router.Facts(windows: [window("@2")], hasTerminal: false, now: now)
        XCTAssertTrue(router.handle(.request(.window("@2"), at: now), facts).isEmpty)
        XCTAssertTrue(router.handle(.read(1), facts).isEmpty)
        XCTAssertNil(router.location)
        facts.allowAttach = true
        let effects = router.handle(.read(2), facts)
        let pending = try windowIntent(router)
        XCTAssertEqual(router.location, .window(id("@2")))
        XCTAssertTrue(effects.contains(.attach(id("@2"), intent: pending.id)))
    }

    func testAttachUsesAnIntentBeforeTheRememberedAndInitialWindows() throws {
        var router = Router()
        _ = router.handle(.result(.window(id("@3")), lastStartedRead: 1), .init())
        let pending = try windowIntent(router)
        let facts = Router.Facts(windows: [window("@1"), window("@2"), window("@3")], hasTerminal: false,
                                 allowAttach: true, rememberedWindow: id("@2"), initialWindow: id("@1"))
        XCTAssertEqual(router.handle(.read(1), facts), [.attach(id("@3"), intent: pending.id)])
        for (remembered, target) in [(Optional(id("@2")), id("@2")), (nil, id("@1")), (Optional(id("@9")), id("@1"))] {
            var fresh = Router()
            var next = facts
            next.rememberedWindow = remembered
            let effects = fresh.handle(.read(1), next)
            XCTAssertEqual(fresh.location, .window(target))
            XCTAssertTrue(effects.contains(.attach(target, intent: try windowIntent(fresh).id)))
        }
    }

    func testAnEmptyServerCanAttachWithoutAWindowOnlyWhenAllowed() {
        var router = Router()
        XCTAssertTrue(router.handle(.read(1), .init(hasTerminal: false)).isEmpty)
        XCTAssertEqual(router.handle(.read(2), .init(hasTerminal: false, allowAttach: true)), [.attach(nil, intent: nil)])
        XCTAssertNil(router.location)
    }

    func testAnEmptyTopicPageDoesNotAttachATerminal() {
        for group in [TopicGroupID.topic("work"), .noTopic] {
            var router = Router()
            let facts = Router.Facts(windows: [window("@1")], records: [TopicRecord(id: "work")],
                                     hasTerminal: false, allowAttach: true, initialWindow: id("@1"))
            _ = router.handle(.go(.emptyTopic(group)), facts)
            XCTAssertTrue(router.handle(.read(1), facts).isEmpty)
            XCTAssertEqual(router.location, .emptyTopic(group))
        }
    }

    func testANewServerClearsLocationAndHistoryWithoutReusingACommandID() throws {
        var router = Router()
        _ = router.handle(.go(.window(id("@1"))), .init())
        let old = try windowIntent(router)
        XCTAssertTrue(router.handle(.serverChanged, .init()).isEmpty)
        XCTAssertNil(router.location)
        XCTAssertNil(router.intent)
        _ = router.handle(.go(.window(id("@1"))), .init())
        let new = try windowIntent(router)
        XCTAssertNotEqual(new.id, old.id)
        _ = router.handle(.commandFinished(old.id, .failure, lastStartedRead: 9), .init())
        XCTAssertEqual(router.intent, .window(new))
    }

    func testTheSameEventsAndFactsProduceTheSameRouterAndEffects() {
        var first = Router()
        var second = Router()
        let facts = Router.Facts(windows: [window("@1")])
        let event = Router.Event.go(.window(id("@1")))
        XCTAssertEqual(first.handle(event, facts), second.handle(event, facts))
        XCTAssertEqual(first, second)
    }

    func testAnOldCommandCannotReplaceANewerPageButALaterExternalMoveCan() throws {
        var router = Router()
        var facts = Router.Facts(windows: [window("@1"), window("@2"), window("@3")],
                                 ownClientWindow: id("@1"), records: [TopicRecord(id: "work")])
        _ = router.handle(.read(1), facts)
        _ = router.handle(.go(.window(id("@2"))), facts)
        let old = try windowIntent(router)
        let page = Location.emptyTopic(.topic("work"))
        _ = router.handle(.go(page), facts)
        facts.ownClientWindow = id("@2")
        _ = router.handle(.read(2), facts)
        XCTAssertEqual(router.location, page)
        _ = router.handle(.commandFinished(old.id, .success, lastStartedRead: 3), facts)
        facts.ownClientWindow = id("@1")
        _ = router.handle(.read(3), facts)
        facts.ownClientWindow = id("@2")
        _ = router.handle(.read(4), facts)
        XCTAssertEqual(router.location, page)
        facts.ownClientWindow = id("@3")
        _ = router.handle(.read(5), facts)
        XCTAssertEqual(router.location, .window(id("@3")))
    }

    func testACommandIssuedByAReadCannotReplaceANewerPage() throws {
        var router = Router()
        let now = Date(timeIntervalSince1970: 100)
        _ = router.handle(.request(.window("@2"), at: now), .init(now: now))
        var facts = Router.Facts(windows: [window("@1"), window("@2")], ownClientWindow: id("@1"), now: now)
        _ = router.handle(.read(1), facts)
        let pending = try windowIntent(router)
        _ = router.handle(.go(.emptyTopic(.noTopic)), facts)
        _ = router.handle(.commandFinished(pending.id, .success, lastStartedRead: 1), facts)
        facts.ownClientWindow = id("@2")
        _ = router.handle(.read(2), facts)
        XCTAssertEqual(router.location, .emptyTopic(.noTopic))
    }

    func testAnExternalMoveDuringAnOldCommandIsFollowedWhenTheCommandFails() throws {
        var router = Router()
        var facts = Router.Facts(windows: [window("@1"), window("@2"), window("@3")], ownClientWindow: id("@1"))
        _ = router.handle(.read(1), facts)
        _ = router.handle(.go(.window(id("@2"))), facts)
        let pending = try windowIntent(router)
        _ = router.handle(.go(.emptyTopic(.noTopic)), facts)
        facts.ownClientWindow = id("@3")
        _ = router.handle(.read(2), facts)
        _ = router.handle(.commandFinished(pending.id, .failure, lastStartedRead: 2), facts)
        _ = router.handle(.read(3), facts)
        XCTAssertEqual(router.location, .window(id("@3")))
    }

    private func id(_ value: String) -> WindowID { WindowID(rawValue: value)! }

    private func windowIntent(_ router: Router, file: StaticString = #filePath, line: UInt = #line) throws -> Router.WindowIntent {
        guard case .window(let pending) = router.intent else {
            XCTFail("Expected a Window Intent", file: file, line: line)
            throw NSError(domain: "RouterTests", code: 1)
        }
        return pending
    }

    private func window(_ id: String, sessionID: String = "$1", sessionName: String = "test", active: Bool = true) -> TmuxWindow {
        TmuxWindow(id: id, sessionID: sessionID, sessionName: sessionName, index: 0, name: "shell",
                   paneTitle: "", path: "/", command: "sh", isActive: active, paneCount: 1,
                   hasBell: false, sessionActivity: 0, agent: "", storedBrowser: StoredBrowser(), openRequests: [])
    }
}
