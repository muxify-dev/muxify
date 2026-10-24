import XCTest
@testable import MuxifyCore

final class ZenTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private var zenEnd: SnoozeDeadline { .at(now.addingTimeInterval(3600)) }

    private func topic(_ id: String, snoozed: SnoozeDeadline? = nil, settled: Bool = false) -> TopicRecord {
        var record = TopicRecord(id: id, title: id)
        record.snoozedUntil = snoozed?.stored
        if settled { record.settledAt = "2033-01-01T00:00:00Z" }
        return record
    }

    private func snooze(of id: String, in records: [TopicRecord]) -> String? {
        records.first { $0.id == id }!.snoozedUntil
    }

    func testStartSnoozesOnlyTheOpenTopicsItWouldLengthen() {
        let shorter = SnoozeDeadline.at(now.addingTimeInterval(600))
        let longer = SnoozeDeadline.at(now.addingTimeInterval(7200))
        let due = SnoozeDeadline.at(now.addingTimeInterval(-60))
        let records = [topic("kept"), topic("free"), topic("settled", settled: true), topic("never", snoozed: .never),
                       topic("longer", snoozed: longer), topic("shorter", snoozed: shorter), topic("due", snoozed: due)]

        let (zen, saves) = ZenRecord.start(keeping: "kept", until: zenEnd, records: records)

        XCTAssertEqual(Set(saves.map(\.id)), ["free", "shorter", "due"])
        XCTAssertTrue(saves.allSatisfy { $0.snoozedUntil == zenEnd.stored })
        XCTAssertEqual(zen, ZenRecord(keptTopicID: "kept", until: zenEnd.stored, changes: [
            .init(topicID: "free", previous: nil),
            .init(topicID: "shorter", previous: shorter.stored),
            .init(topicID: "due", previous: due.stored),
        ]))
    }

    func testZenUntilUnsnoozeLengthensEveryTimedSnoozeButNotAnotherUntilUnsnooze() {
        let records = [topic("later", snoozed: .at(now.addingTimeInterval(86400 * 30))), topic("never", snoozed: .never)]

        let (_, saves) = ZenRecord.start(keeping: "kept", until: .never, records: records)

        XCTAssertEqual(saves.map(\.id), ["later"])
        XCTAssertEqual(saves.first?.snoozedUntil, "never")
    }

    func testARecordThatKeepsNoTopicDoesNotDecode() {
        let json = #"{"kept_topic_id": null, "until": "never", "changes": []}"#
        XCTAssertThrowsError(try JSONDecoder().decode(ZenRecord.self, from: Data(json.utf8)))
    }

    func testEndRestoresAFutureSnoozeAndUnsnoozesAPastOne() {
        let earlier = SnoozeDeadline.at(now.addingTimeInterval(600))
        let (zen, saves) = ZenRecord.start(keeping: "kept", until: zenEnd, records: [topic("free"), topic("earlier", snoozed: earlier)])

        let beforeEarlierWakes = zen.end(records: saves, now: now.addingTimeInterval(60))
        XCTAssertNil(snooze(of: "free", in: beforeEarlierWakes))
        XCTAssertEqual(snooze(of: "earlier", in: beforeEarlierWakes), earlier.stored)

        let afterEarlierWakes = zen.end(records: saves, now: now.addingTimeInterval(1200))
        XCTAssertNil(snooze(of: "earlier", in: afterEarlierWakes))
    }

    func testEndSkipsTopicsTheUserChangedOrSettledDuringZen() {
        let (zen, saves) = ZenRecord.start(keeping: "kept", until: zenEnd, records: [topic("resnoozed"), topic("woken"),
                                                                                 topic("settled"), topic("untouched")])
        var during = saves
        during[0].snoozedUntil = "never"
        during[1].snoozedUntil = nil
        during[2].settledAt = "2033-01-01T00:00:00Z"

        let ends = zen.end(records: during, now: now)

        XCTAssertEqual(ends.map(\.id), ["untouched"])
        XCTAssertNil(ends.first?.snoozedUntil)
    }

    private func window(_ id: String, session: String, topic: String?) -> TmuxWindow {
        TmuxWindow(id: id, sessionID: session, sessionName: "name-" + session, index: 0, name: "agent",
                   paneTitle: "agent", path: "/work/app", command: "sleep", isActive: true, paneCount: 1,
                   hasBell: false, sessionActivity: 0, agent: "codex", storedBrowser: StoredBrowser(),
                   openRequests: [], topicID: topic, sessionPath: "/work/app")
    }

    private func agent(_ id: String, in window: TmuxWindow, _ status: AgentStatus) -> Agent {
        Agent(paneID: id, kind: .codex, status: status, unread: true, windowID: window.id,
              sessionID: window.sessionID, sessionName: window.sessionName, windowIndex: window.index, windowTitle: window.displayTitle, label: "Agent")
    }

    /// Kept and Made are open Topics; Made came during Zen, so Zen did not Snooze it. Two Sessions are in No Topic.
    private let kept = TopicRecord(id: "kept", title: "Kept")
    private let made = TopicRecord(id: "made", title: "Made")
    private var windows: [TmuxWindow] {
        [window("@1", session: "$k", topic: "kept"), window("@2", session: "$m", topic: "made"),
         window("@3", session: "$n1", topic: nil), window("@4", session: "$n2", topic: nil)]
    }
    private var agents: [Agent] {
        [agent("%2", in: windows[1], .done), agent("%3", in: windows[2], .done), agent("%4", in: windows[3], .working)]
    }

    private func model(selected: String, zen: ZenRecord?, mode: SidebarMode = .topics) -> TopicsModel {
        var config = Config()
        config.sidebar.agentsScope = .init(.all)
        var selection = TopicSelection()
        selection.windowID = selected
        return TopicsModel(records: [kept, made], windows: windows, config: config, selection: selection,
                        location: selection.windowID.flatMap(WindowID.init(rawValue:)).map(Location.window), mode: mode,
                           agents: agents, zen: zen, now: now)
    }

    private var zen: ZenRecord { ZenRecord(keptTopicID: "kept", until: zenEnd.stored, changes: []) }

    func testZenHidesTheNotificationsOfNoTopicAndKeepsThoseOfATopicMadeDuringZen() {
        for mode in [SidebarMode.topics, .sessions] {
            let without = model(selected: "@3", zen: nil, mode: mode)
            XCTAssertEqual(without.sessionMarks, ["$m": .done, "$n1": .done, "$n2": .working])
            XCTAssertEqual(without.visibleAgents.map(\.paneID), ["%2", "%3", "%4"])

            let during = model(selected: "@3", zen: zen, mode: mode)
            XCTAssertEqual(during.sessionMarks, ["$m": .done], "\(mode)")
            XCTAssertEqual(during.agentMarks, ["%2": .done, "%4": .working], "an Agent's own row keeps only its Working mark")
            XCTAssertEqual(during.visibleAgents.map(\.paneID), ["%2"], "\(mode)")
        }
        XCTAssertEqual(model(selected: "@1", zen: zen).rows.first { $0.id == .topic("made") }?.mark, .agent(.done))
    }

    func testWithOrWithoutZenTheTopicListHasNoNoTopicRowAndAnEmptyNoTopicSlotWhileATopicIsActive() {
        for zen in [nil, zen] {
            for selected in ["@1", "@2"] {
                let model = model(selected: selected, zen: zen)
                XCTAssertEqual(model.rows.map(\.id), [.topic("kept"), .topic("made")], "Zen: \(zen != nil)")
                XCTAssertNil(model.openedNoTopicSession, "Zen: \(zen != nil)")
                XCTAssertEqual(model.noTopicSessions.map(\.id.session), ["$n1", "$n2"], "the Switcher still reaches them")
            }
        }
    }

    func testZenHidesALockedSessionAndShowsItAsTheNoTopicCardWhileTheUserIsInIt() {
        var windows = self.windows
        windows[3].lockOrder = 10
        func model(selected: String, zen: ZenRecord?) -> TopicsModel {
            var selection = TopicSelection()
            selection.windowID = selected
            return TopicsModel(records: [kept, made], windows: windows, config: Config(), selection: selection,
                            location: selection.windowID.flatMap(WindowID.init(rawValue:)).map(Location.window),
                               agents: agents, zen: zen, now: now)
        }
        let without = model(selected: "@4", zen: nil)
        XCTAssertEqual(without.rows.map(\.id), [.topic("kept"), .topic("made"), .locked("$n2")])
        XCTAssertNil(without.openedNoTopicSession)
        XCTAssertEqual(without.sessionMarks["$n2"], .working, "a Locked Session is not quiet without Zen")

        let during = model(selected: "@4", zen: zen)
        XCTAssertEqual(during.rows.map(\.id), [.topic("kept"), .topic("made")], "Zen hides the Locked Session")
        XCTAssertEqual(during.openedNoTopicSession?.id.session, "$n2", "while the user is in it, it is the one No Topic card")
        XCTAssertNil(during.sessionMarks["$n2"], "it is quiet as No Topic is")
        XCTAssertEqual(during.lockedSessionIDs, ["$n2"], "Zen does not end the Lock")
        XCTAssertNil(model(selected: "@1", zen: zen).openedNoTopicSession)
        for zen in [nil, zen] {
            XCTAssertEqual(model(selected: "@1", zen: zen).noTopicSessions.map(\.id.session), ["$n1", "$n2"], "the palette still reaches it")
        }
    }

    func testWithOrWithoutZenTheNoTopicSlotShowsOnlyTheOpenedSessionAndTheNextOneReplacesIt() {
        for zen in [nil, zen] {
            let opened = { (selected: String) in self.model(selected: selected, zen: zen).openedNoTopicSession?.id.session }
            XCTAssertEqual(opened("@3"), "$n1", "Zen: \(zen != nil)")
            XCTAssertEqual(opened("@4"), "$n2", "Zen: \(zen != nil)")
            XCTAssertNil(opened("@1"), "Zen: \(zen != nil)")
            XCTAssertEqual(model(selected: "@3", zen: zen).rows.map(\.id), [.topic("kept"), .topic("made")], "Zen: \(zen != nil)")
        }
    }
}
