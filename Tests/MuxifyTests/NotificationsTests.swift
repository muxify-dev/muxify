import XCTest
@testable import MuxifyCore

final class NotificationsTests: XCTestCase {
    private func load(_ text: String) throws -> Config { try Config.load(path: "/cfg/config.yaml") { _ in text }.get() }
    private func window(_ id: String, topic: String?) -> TmuxWindow {
        TmuxWindow(id: id, sessionID: "$1", sessionName: "app/topic", index: 0, name: "agent",
                   paneTitle: "agent", path: "/app", command: "sleep", isActive: true, paneCount: 1,
                   hasBell: false, sessionActivity: 0, agent: "codex", storedBrowser: StoredBrowser(),
                   openRequests: [], topicID: topic)
    }
    private func agent(_ status: AgentStatus, id: String = "%1", window: String = "@1", unread: Bool = true) -> Agent {
        Agent(paneID: id, kind: .codex, status: status, unread: unread, windowID: window,
              sessionID: "$1", sessionName: "app/topic", windowIndex: 1, windowTitle: "Agent", label: "Agent")
    }

    func testTopicUnreadIsIndependentOfAgentsAndNotificationSettings() {
        var topic = TopicRecord(id: "a")
        topic.isUnread = true
        var config = Config()
        config.notifications.doneEnabled = false
        func model(_ agents: [Agent] = [], windows: [TmuxWindow] = []) -> TopicsModel {
            TopicsModel(records: [topic], windows: windows, config: config, selection: TopicSelection(), agents: agents)
        }
        XCTAssertEqual(model().rows.first?.mark, .unread)
        XCTAssertEqual(model([agent(.working)], windows: [window("@1", topic: "a")]).rows.first?.mark, .unread)
        XCTAssertEqual(model([agent(.failed)], windows: [window("@1", topic: "a")]).rows.first?.mark, .agent(.failed))
        XCTAssertEqual(model([agent(.blocked)], windows: [window("@1", topic: "a")]).rows.first?.mark, .agent(.blocked))
        XCTAssertEqual(model([agent(.working)], windows: [window("@1", topic: "a")]).agentMarks["%1"], .working)
        topic.settledAt = "2026-10-07T08:00:00Z"
        XCTAssertEqual(model().groups.first { $0.kind == .settled }?.topics.first?.mark, .unread)
    }

    func testActiveTopicSpinesIdentifyWindowsWithAgentMarks() {
        var topic = TopicRecord(id: "a")
        topic.isUnread = true
        let windows = [window("@1", topic: "a"), window("@2", topic: "a"), window("@3", topic: "a")]
        let agents = [agent(.done), agent(.blocked, id: "%2", window: "@2", unread: false),
                      agent(.working, id: "%3", window: "@3")]
        var selection = TopicSelection()
        selection.select(windowID: "@1", activeTopic: .topic("a"))
        var config = Config()
        func model(_ location: Location? = .window(WindowID(rawValue: "@1")!)) -> TopicsModel {
            TopicsModel(records: [topic], windows: windows, config: config, selection: selection,
                        location: location, agents: agents)
        }
        XCTAssertEqual(model().rows[0].agentSpines, ["@1": .done, "@2": .blocked, "@3": .working])
        XCTAssertEqual(model().rows[0].mark, .agent(.blocked), "The header keeps the strongest mark")
        XCTAssertTrue(model(nil).rows[0].agentSpines.isEmpty, "An inactive card keeps its full spine")
        selection.setTopic(.topic("a"), open: false)
        XCTAssertTrue(model().rows[0].agentSpines.isEmpty, "A collapsed card keeps its full spine")
        selection.setTopic(.topic("a"), open: true)
        config.notifications.doneEnabled = false
        XCTAssertEqual(model().rows[0].agentSpines, ["@2": .blocked, "@3": .working])
        config.notifications.blockedEnabled = false
        XCTAssertEqual(model().rows[0].agentSpines, ["@3": .working])
        XCTAssertTrue(model().rows[0].isUnread)
        XCTAssertTrue(model().rows[0].usesRowMarks)
    }

    func testReplacingPaneRowsCarryTheirOwnAgentSpines() {
        let panes = ["%1", "%2", "%3"].enumerated().map { index, id in
            TmuxPane(id: id, windowID: "@1", index: index, isActive: index == 0, title: "Pane", path: "/app",
                     command: "zsh", agent: "", agentStatus: "", unread: false)
        }
        var selection = TopicSelection()
        selection.select(windowID: "@1", activeTopic: .topic("a"))
        let model = TopicsModel(records: [TopicRecord(id: "a")], windows: [window("@1", topic: "a")],
                                config: Config(), selection: selection, location: .window(WindowID(rawValue: "@1")!),
                                agents: [agent(.done), agent(.failed, id: "%2", unread: false), agent(.working, id: "%3")], panes: panes)
        XCTAssertEqual(model.rows[0].agentSpines, ["%1": .done, "%3": .working])
    }

    func testNotificationDefaultsAndReplacement() throws {
        XCTAssertEqual(try load("").notifications, Config.Notifications())
        let config = try load("""
        notifications:
          done_enabled: false
          failed_enabled: false
          blocked_enabled: false
        """)
        XCTAssertTrue(config.problems.isEmpty)
        XCTAssertFalse(config.notifications.doneEnabled)
        XCTAssertFalse(config.notifications.failedEnabled)
        XCTAssertFalse(config.notifications.blockedEnabled)
        XCTAssertEqual(try load("notifications:\n  done_enabled: nope\n  other: true").problems.count, 2)
        let template = Config.template.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.hasPrefix("# ") ? String(line.dropFirst(2)) : String(line)
        }.joined(separator: "\n")
        XCTAssertTrue(template.contains("notifications:"))
    }

    func testMarksRespectEachNotificationFlag() {
        let topic = TopicRecord(id: "a")
        let windows = [window("@1", topic: "a")]
        let agents = [agent(.done), agent(.failed, id: "%2"), agent(.blocked, id: "%3")]
        func model(_ config: Config, _ agents: [Agent]) -> TopicsModel {
            TopicsModel(records: [topic], windows: windows, config: config, selection: TopicSelection(), agents: agents)
        }
        XCTAssertEqual(model(Config(), agents).rows[0].mark, .agent(.blocked))
        for (key, disabled, expected) in [(\Config.Notifications.blockedEnabled, AgentStatus.blocked, AgentMark.failed),
                                         (\Config.Notifications.failedEnabled, .failed, .blocked),
                                         (\Config.Notifications.doneEnabled, .done, .blocked)] {
            var config = Config()
            config.notifications[keyPath: key] = false
            XCTAssertEqual(model(config, agents).rows[0].mark, .agent(expected))
            XCTAssertNil(model(config, [agent(disabled)]).rows[0].mark)
        }
        XCTAssertEqual(model(Config(), Array(agents.prefix(2))).rows[0].mark, .agent(.failed))
        XCTAssertEqual(model(Config(), [agents[0]]).rows[0].mark, .agent(.done))
        XCTAssertEqual(model(Config(), [agent(.done, unread: false), agent(.working, id: "%2")]).rows[0].mark, .agent(.working))
        XCTAssertNil(model(Config(), [agent(.done, unread: false)]).rows[0].mark, "a read, done Agent has no mark")
        XCTAssertEqual(model(Config(), [agent(.blocked, unread: false), agent(.done, id: "%2")]).rows[0].mark, .agent(.blocked))
        var noBlocked = Config()
        noBlocked.notifications.blockedEnabled = false
        XCTAssertNil(model(noBlocked, [agent(.blocked, unread: false)]).rows[0].mark)
    }

    func testANotificationTypeThatIsOffReachesEveryAgentRow() {
        let windows = [window("@1", topic: "a"), window("@2", topic: nil)]
        let agents = [agent(.working), agent(.blocked, id: "%2"), agent(.failed, id: "%3"), agent(.done, id: "%4", window: "@2")]
        var config = Config()
        config.notifications.doneEnabled = false
        let off = TopicsModel(records: [], windows: windows, config: config, selection: TopicSelection(), agents: agents)
        XCTAssertEqual(off.agentMarks, ["%1": .working, "%2": .blocked, "%3": .failed], "done_enabled: false reaches every row")
    }

    func testReadScopeUsesTheWindowOrOnlyItsZoomedPane() {
        var current = window("@1", topic: "a")
        current.activePaneID = "%1"
        let panes = [TmuxPane(id: "%1", windowID: "@1", command: "sleep", agent: "codex", agentStatus: "done", unread: true), TmuxPane(id: "%2", windowID: "@1", command: "sleep", agent: "codex", agentStatus: "done", unread: true),
                     TmuxPane(id: "%3", windowID: "@2", command: "sleep", agent: "codex", agentStatus: "done", unread: true)]
        XCTAssertEqual(AgentReadScope(window: current).target, .window("@1"))
        XCTAssertEqual(AgentReadScope(window: current).paneIDs(in: panes), ["%1", "%2"])
        current.isZoomed = true
        XCTAssertEqual(AgentReadScope(window: current).target, .pane("%1"))
        XCTAssertEqual(AgentReadScope(window: current).paneIDs(in: panes), ["%1"])
    }

    func testReadVisitsObserveNewlyShownPanesAndDiscardSupersededEntries() {
        let panes = [TmuxPane(id: "%1", windowID: "@1", command: "sleep", agent: "codex", agentStatus: "done", unread: true), TmuxPane(id: "%2", windowID: "@1", command: "sleep", agent: "codex", agentStatus: "done", unread: true),
                     TmuxPane(id: "%3", windowID: "@2", command: "sleep", agent: "codex", agentStatus: "done", unread: true)]
        let zoom = AgentReadScope.pane(windowID: "@1", paneID: "%1")
        var visits = AgentReadVisits()
        XCTAssertEqual(visits.consume(showing: zoom, panes: panes, observing: true), ["%1"])
        XCTAssertTrue(visits.consume(showing: zoom, panes: panes, observing: true).isEmpty,
                      "Continued viewing must preserve explicit Unread")
        XCTAssertEqual(visits.consume(showing: .window("@1"), panes: panes, observing: true), ["%2"],
                       "Ending Zoom reads only newly shown Panes")
        visits.enter(windowID: "@1")
        visits.enter(windowID: "@2")
        XCTAssertEqual(visits.consume(showing: .window("@2"), panes: panes, observing: false), ["%3"])
        XCTAssertTrue(visits.consume(showing: .window("@1"), panes: panes, observing: false).isEmpty,
                      "A superseded entry must not clear a later explicit mark")
        visits.enter(windowID: "@1")
        XCTAssertEqual(visits.consume(showing: zoom, panes: panes, observing: false), ["%1"],
                       "An explicit visit to the same Window reads only its confirmed Zoomed Pane")
        visits.enter(windowID: "@1")
        XCTAssertTrue(visits.consume(showing: nil, panes: panes, observing: true).isEmpty,
                      "A hidden Terminal never reads its Panes")
        XCTAssertEqual(visits.consume(showing: zoom, panes: panes, observing: true), ["%1"])
        visits.hide()
        XCTAssertEqual(visits.consume(showing: zoom, panes: panes, observing: true), ["%1"],
                       "A hide and reveal between snapshots starts a new visit")
    }

    func testDisabledNotificationSortingPreservesSnapshotPaneOrderAfterSwap() {
        let windows = [window("@1", topic: nil)]
        let panes = [TmuxPane(id: "%9", windowID: "@1", command: "sleep", agent: "codex", agentStatus: "done", unread: false),
                     TmuxPane(id: "%1", windowID: "@1", command: "sleep", agent: "codex", agentStatus: "done", unread: true)]
        let agents = Agent.list(panes: panes, windows: windows, ordered: false)
        var config = Config()
        config.notifications.doneEnabled = false
        let model = TopicsModel(records: [], windows: windows, config: config, selection: TopicSelection(), agents: agents)
        XCTAssertEqual(model.visibleAgents.map(\.paneID), ["%9", "%1"])
        XCTAssertEqual(Agent.list(panes: panes, windows: windows).map(\.paneID), ["%1", "%9"])
    }

    func testDisabledNotificationsDoNotPromoteAgentsAboveWorkingStatus() {
        var config = Config()
        config.notifications.doneEnabled = false
        let model = TopicsModel(records: [], windows: [window("@1", topic: nil)], config: config, selection: TopicSelection(),
                                agents: [agent(.done), agent(.working, id: "%2"), agent(.failed, id: "%3")])
        XCTAssertEqual(model.visibleAgents.map(\.paneID), ["%3", "%2", "%1"])
    }
}
