import XCTest
@testable import MuxifyCore

final class NotificationsAndSnoozeTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-07T08:00:00Z")!
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
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
            TopicsModel(records: [topic], windows: windows, config: config, selection: TopicSelection(), agents: agents, now: now)
        }
        XCTAssertEqual(model().rows.first?.mark, .unread)
        XCTAssertEqual(model([agent(.working)], windows: [window("@1", topic: "a")]).rows.first?.mark, .unread)
        XCTAssertEqual(model([agent(.failed)], windows: [window("@1", topic: "a")]).rows.first?.mark, .agent(.failed))
        XCTAssertEqual(model([agent(.blocked)], windows: [window("@1", topic: "a")]).rows.first?.mark, .agent(.blocked))
        XCTAssertEqual(model([agent(.working)], windows: [window("@1", topic: "a")]).agentMarks["%1"], .working)
        topic.snoozedUntil = "never"
        XCTAssertNil(model().groups.first?.topics.first?.mark)
        topic.snoozedUntil = SnoozeDeadline.at(now).stored
        XCTAssertEqual(model().dueWakes.first?.count, 0)
        XCTAssertEqual(model().rows.first?.mark, .unread)
        topic.settledAt = "2026-10-07T08:00:00Z"
        XCTAssertEqual(model().groups.first { $0.kind == .settled }?.topics.first?.mark, .unread)
    }

    func testEveryScheduleFormAndTypedShorthand() throws {
        let forms = ["+5m": "2026-10-07T08:05:00Z", "+2h": "2026-10-07T10:00:00Z",
                     "+2d": "2026-10-09T08:00:00Z", "today": "2026-10-07T09:00:00Z",
                     "today 10:30": "2026-10-07T10:30:00Z", "tomorrow": "2026-10-08T09:00:00Z",
                     "tomorrow 12:15": "2026-10-08T12:15:00Z",
                     "mon": "2026-10-12T09:00:00Z", "tue": "2026-10-13T09:00:00Z",
                     "wed": "2026-10-07T09:00:00Z", "thu": "2026-10-08T09:00:00Z",
                     "fri 10:00": "2026-10-09T10:00:00Z", "sat": "2026-10-10T09:00:00Z",
                     "sun": "2026-10-11T09:00:00Z", "1300": "2026-10-07T13:00:00Z",
                     "9": "2026-10-07T09:00:00Z", "930": "2026-10-07T09:30:00Z", "13:00": "2026-10-07T13:00:00Z",
                     "1pm": "2026-10-07T13:00:00Z", "1:30 pm": "2026-10-07T13:30:00Z", "130pm": "2026-10-07T13:30:00Z",
                     "12am": "2026-10-08T00:00:00Z", "12pm": "2026-10-07T12:00:00Z", "0700": "2026-10-08T07:00:00Z",
                     "tomorrow 1300": "2026-10-08T13:00:00Z", "tomorrow 1 pm": "2026-10-08T13:00:00Z",
                     "fri 9": "2026-10-09T09:00:00Z"]
        for (form, expected) in forms {
            XCTAssertEqual(try XCTUnwrap(SnoozeSchedule(form)).deadline(from: now, calendar: calendar), .at(date(expected)), form)
        }
        XCTAssertEqual(SnoozeSchedule("never")?.deadline(from: now), .never)
        XCTAssertEqual(SnoozeSchedule("2h", typed: true)?.deadline(from: now, calendar: calendar), .at(date("2026-10-07T10:00:00Z")))
        XCTAssertNil(SnoozeSchedule("today 07:00")?.deadline(from: now, calendar: calendar))
        XCTAssertEqual(SnoozeSchedule("today 1:00"), .day(0, hour: 1, minute: 0))
        XCTAssertEqual(SnoozeSchedule("1300")?.deadline(from: date("2026-10-07T14:00:00Z"), calendar: calendar), .at(date("2026-10-08T13:00:00Z")))
        XCTAssertEqual(SnoozeSchedule("1300", typed: true), .next(hour: 13, minute: 0))
        XCTAssertEqual(SnoozeSchedule("wed 07:00")?.deadline(from: now, calendar: calendar), .at(date("2026-10-14T07:00:00Z")))
        for form in ["2h", "+0m", "+-1h", "+999999999999999999d", "+1w", "friday", "tomorrow 24:00", "today 09:60", "never 09:00",
                     "2400", "1360", "13pm", "0am", "12345", "1:3", "123:00", "today pm", "today 09:00 extra", ""] {
            XCTAssertNil(SnoozeSchedule(form), form)
        }
    }

    func testSnoozeOfASetWritesTheChosenTimeOnEveryOpenTopicAndNamesEachShorterSnooze() {
        let until = SnoozeDeadline.at(now.addingTimeInterval(3600))
        func topic(_ id: String, snoozed: SnoozeDeadline? = nil, settled: Bool = false) -> TopicRecord {
            var record = TopicRecord(id: id)
            record.snoozedUntil = snoozed?.stored
            if settled { record.settledAt = "2026-10-01T00:00:00Z" }
            return record
        }
        let records = [topic("free"), topic("never", snoozed: .never), topic("later", snoozed: .at(now.addingTimeInterval(7200))),
                       topic("earlier", snoozed: .at(now.addingTimeInterval(600))), topic("due", snoozed: .at(now.addingTimeInterval(-60))),
                       topic("settled", settled: true), topic("unmarked")]

        let snooze = SnoozeSet(["later", "free", "never", "earlier", "due", "settled", "missing"], until: until, records: records)

        XCTAssertEqual(snooze.saves.map(\.id), ["later", "free", "never", "earlier", "due"], "every open marked Topic, in set order")
        XCTAssertTrue(snooze.saves.allSatisfy { $0.snoozedUntil == until.stored }, "a later Snooze is replaced too")
        XCTAssertEqual(snooze.shortened, ["later", "never"])
        XCTAssertEqual(SnoozeSet(["never", "later"], until: .never, records: records).shortened, [], "Until I unsnooze is never shorter")
    }

    func testConfigDefaultsReplacementValidationAndKeybind() throws {
        let defaults = try load("")
        XCTAssertEqual(defaults.topics.snoozePresets, SnoozePreset.defaults)
        XCTAssertEqual(defaults.notifications, Config.Notifications())
        XCTAssertEqual(defaults.keybinds.firstTrigger(for: .snoozeTopic), try KeyTrigger("alt+cmd+s"))
        XCTAssertNil(defaults.keybinds.firstTrigger(for: .snoozeTopics), "shift+alt+cmd+s is Zen, so Snooze Topics has no default")
        XCTAssertEqual(try load("keybindings:\n  snooze_topics: ctrl+alt+s").keybinds.action(for: try KeyTrigger("ctrl+alt+s")), .snoozeTopics)
        XCTAssertNil(defaults.keybinds.firstTrigger(for: .unsnoozeTopics), "Unsnooze Topics has no default")
        XCTAssertEqual(try load("keybindings:\n  unsnooze_topics: ctrl+alt+u").keybinds.action(for: try KeyTrigger("ctrl+alt+u")), .unsnoozeTopics)
        let config = try load("""
        notifications:
          done_enabled: false
          failed_enabled: false
          blocked_enabled: false
        topics:
          snooze_presets:
            - label: Short break
              at: +5m
            - label: Quiet
              at: never
            - label: Bad
              at: +4w
        keybindings:
          snooze_topic: cmd+shift+s
        """)
        XCTAssertEqual(config.topics.snoozePresets, [SnoozePreset(label: "Short break", schedule: .relative(5, .minute)), SnoozePreset(label: "Quiet", schedule: .never)])
        XCTAssertEqual(config.problems.count, 1)
        XCTAssertTrue(config.problems[0].message.contains("at"))
        XCTAssertFalse(config.notifications.doneEnabled)
        XCTAssertFalse(config.notifications.failedEnabled)
        XCTAssertFalse(config.notifications.blockedEnabled)
        XCTAssertEqual(config.keybinds.firstTrigger(for: .snoozeTopic), try KeyTrigger("cmd+shift+s"))
        XCTAssertTrue(try load("topics:\n  snooze_presets: []").topics.snoozePresets.isEmpty)
        XCTAssertEqual(try load("topics:\n  snooze_presets: bad").topics.snoozePresets, SnoozePreset.defaults)
        XCTAssertEqual(try load("notifications:\n  done_enabled: nope\n  other: true").problems.count, 2)
        let template = Config.template.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.hasPrefix("# ") ? String(line.dropFirst(2)) : String(line)
        }.joined(separator: "\n")
        XCTAssertTrue(template.contains("notifications:"))
        XCTAssertTrue(Config.template.contains("snooze_topic"))
    }

    func testMarksAndWakeCountsRespectEachNotificationFlag() {
        var topic = TopicRecord(id: "a")
        topic.snoozedUntil = SnoozeDeadline.at(now).stored
        let windows = [window("@1", topic: "a")]
        let agents = [agent(.done), agent(.failed, id: "%2"), agent(.blocked, id: "%3")]
        func model(_ config: Config, _ agents: [Agent]) -> TopicsModel {
            TopicsModel(records: [topic], windows: windows, config: config, selection: TopicSelection(), agents: agents, now: now)
        }
        XCTAssertEqual(model(Config(), agents).rows[0].mark, .agent(.blocked))
        XCTAssertEqual(model(Config(), agents).dueWakes[0].count, 3)
        for (key, disabled, expected) in [(\Config.Notifications.blockedEnabled, AgentStatus.blocked, AgentMark.failed),
                                         (\Config.Notifications.failedEnabled, .failed, .blocked),
                                         (\Config.Notifications.doneEnabled, .done, .blocked)] {
            var config = Config()
            config.notifications[keyPath: key] = false
            XCTAssertEqual(model(config, agents).rows[0].mark, .agent(expected))
            XCTAssertEqual(model(config, agents).dueWakes[0].count, 2)
            XCTAssertNil(model(config, [agent(disabled)]).rows[0].mark)
            XCTAssertEqual(model(config, [agent(disabled)]).dueWakes[0].count, 0)
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

    func testASnoozedTopicHasNoMarkAndItsAgentsKeepOnlyTheWorkingMark() {
        var snoozed = TopicRecord(id: "a")
        snoozed.snoozedUntil = "never"
        let windows = [window("@1", topic: "a"), window("@2", topic: nil)]
        let agents = [agent(.working), agent(.blocked, id: "%2"), agent(.failed, id: "%3"), agent(.done, id: "%4", window: "@2")]
        let model = TopicsModel(records: [snoozed], windows: windows, config: Config(), selection: TopicSelection(),
                                agents: agents, now: now)
        XCTAssertNil(model.groups.first { $0.kind == .snoozed }?.topics.first?.mark)
        XCTAssertEqual(model.agentMarks, ["%1": .working, "%4": .done])

        var config = Config()
        config.notifications.doneEnabled = false
        let off = TopicsModel(records: [], windows: windows, config: config, selection: TopicSelection(), agents: agents, now: now)
        XCTAssertEqual(off.agentMarks, ["%1": .working, "%2": .blocked, "%3": .failed], "done_enabled: false reaches every row")
    }

        func testSnoozedMembershipVisibilityAndDueWakeRemainSeparateFromDormancy() {
        var future = TopicRecord(id: "future")
        future.snoozedUntil = SnoozeDeadline.at(now.addingTimeInterval(60)).stored
        var never = TopicRecord(id: "never")
        never.snoozedUntil = "never"
        var past = TopicRecord(id: "past")
        past.snoozedUntil = "2026-10-07T07:00:00.100Z"
        past.sessions = [.object(["repository_path": .string("/work/app")])]
        var settled = TopicRecord(id: "settled")
        settled.snoozedUntil = past.snoozedUntil
        settled.settledAt = past.snoozedUntil
        let windows = [window("@1", topic: "future"), window("@2", topic: nil)]
        let model = TopicsModel(records: [future, never, past, settled], windows: windows, config: Config(), selection: TopicSelection(),
                                agents: [agent(.blocked), agent(.done, id: "%2", window: "@2")], now: now)
        XCTAssertEqual(Set(model.snoozedTopicIDs), ["future", "never"])
        XCTAssertEqual(model.groups.first { $0.kind == .snoozed }?.topics.map(\.id), [.topic("future"), .topic("never")])
        XCTAssertEqual(model.visibleAgents.map(\.paneID), ["%2"])
        XCTAssertEqual(model.noTopicSessions.flatMap(\.windows).map(\.id), ["@2"])
        XCTAssertEqual(model.dueWakes.map(\.id), ["past"])
        XCTAssertTrue(model.rows.first { $0.id == .topic("past") }!.isDormant)
        let later = TopicsModel(records: [future, never], windows: windows, config: Config(), selection: TopicSelection(),
                                agents: [agent(.blocked)], now: now.addingTimeInterval(60))
        XCTAssertEqual(later.dueWakes.map(\.id), ["future"])
        XCTAssertEqual(later.visibleAgents.count, 1)
    }

    func testRapidExplicitVisitsReadBothTopicsAndNoTopicReadsOnlyItsWindow() {
        let windows = [window("@1", topic: "a"), window("@2", topic: "a"),
                       window("@3", topic: "b"), window("@4", topic: nil), window("@5", topic: nil)]
        var visits = AgentReadVisits()
        visits.enter(windowID: "@1", windows: windows)
        visits.enter(windowID: "@3", windows: windows)
        XCTAssertEqual(visits.consume(in: windows), ["@1", "@2", "@3"])
        XCTAssertTrue(visits.consume(in: windows).isEmpty)
        visits.enter(windowID: "@4", windows: windows)
        XCTAssertEqual(visits.consume(in: windows), ["@4"])
        visits.enter(windowID: "@6", windows: windows)
        XCTAssertTrue(visits.consume(in: windows).isEmpty)
        XCTAssertTrue(visits.consume(in: windows + [window("@6", topic: nil)]).isEmpty)
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
