import XCTest
@testable import MuxifyCore

final class AgentsScopeTests: XCTestCase {
    private let alpha = TopicRecord(id: "a", title: "Alpha")
    private let beta = TopicRecord(id: "b", title: "Beta")

    private func window(_ id: String, session: String, topic: String?) -> TmuxWindow {
        TmuxWindow(id: id, sessionID: session, sessionName: "name-" + session, index: 0, name: "agent",
                   paneTitle: "agent", path: "/work/app", command: "sleep", isActive: true, paneCount: 1,
                   hasBell: false, sessionActivity: 0, agent: "codex", storedBrowser: StoredBrowser(),
                   openRequests: [], topicID: topic, sessionPath: "/work/app")
    }

    private func agent(_ id: String, in window: TmuxWindow, _ status: AgentStatus = .done, unread: Bool = false) -> Agent {
        Agent(paneID: id, kind: .codex, status: status, unread: unread, windowID: window.id,
              sessionID: window.sessionID, sessionName: window.sessionName, windowIndex: window.index, windowTitle: window.displayTitle, label: "Agent")
    }

    private func model(_ records: [TopicRecord], _ windows: [TmuxWindow], _ agents: [Agent], selected: String,
                       mode: SidebarMode = .topics, scope: Config.Sidebar.AgentsScope = .active) -> TopicsModel {
        var config = Config()
        config.sidebar.agentsScope = .init(scope)
        var selection = TopicSelection()
        selection.windowID = selected
        return TopicsModel(records: records, windows: windows, config: config, selection: selection, mode: mode, agents: agents)
    }

    func testTopicsModeListsOnlyTheAgentsOfTheActiveTopicOrNoTopic() {
        let inAlpha = window("@1", session: "$1", topic: "a")
        let inBeta = window("@2", session: "$2", topic: "b")
        let loose = window("@3", session: "$3", topic: nil)
        let windows = [inAlpha, inBeta, loose]
        let agents = [agent("%1", in: inAlpha), agent("%2", in: inBeta, .blocked, unread: true), agent("%3", in: loose)]

        let onAlpha = model([alpha, beta], windows, agents, selected: "@1")
        XCTAssertEqual(onAlpha.visibleAgents.map(\.paneID), ["%1"])
        XCTAssertEqual(onAlpha.agentsScope, .topic(.topic("a"), title: "Alpha"))
        XCTAssertEqual(onAlpha.agentGroups, [:], "the header names the Topic, so rows show the Agent only")
        XCTAssertEqual(onAlpha.rows.first { $0.id == .topic("b") }?.mark, .agent(.blocked))

        let onBeta = model([alpha, beta], windows, agents, selected: "@2")
        XCTAssertEqual(onBeta.visibleAgents.map(\.paneID), ["%2"])
        XCTAssertEqual(onBeta.agentsScope.name, "Beta")

        let onNoTopic = model([alpha, beta], windows, agents, selected: "@3")
        XCTAssertEqual(onNoTopic.visibleAgents.map(\.paneID), ["%3"])
        XCTAssertEqual(onNoTopic.agentsScope, .topic(.noTopic, title: "No Topic"))
    }

    func testAnUnknownTopicOptionScopesToNoTopic() {
        let orphan = window("@1", session: "$1", topic: "missing")
        let loose = window("@2", session: "$2", topic: nil)
        let blocked = agent("%2", in: loose, .blocked, unread: true)
        let scoped = model([alpha], [orphan, loose], [agent("%1", in: orphan), blocked], selected: "@1")
        XCTAssertEqual(scoped.visibleAgents.map(\.paneID), ["%2", "%1"])
        XCTAssertEqual(scoped.agentsScope.name, "No Topic")

        let elsewhere = window("@3", session: "$3", topic: "a")
        let onAlpha = model([alpha], [orphan, loose, elsewhere], [blocked], selected: "@3")
        XCTAssertEqual(onAlpha.visibleAgents, [])
        XCTAssertEqual(onAlpha.sessionMarks["$2"], .blocked)
    }

    func testOrderStaysNotificationsThenWorkingInsideTheScope() {
        let inAlpha = window("@1", session: "$1", topic: "a")
        let inBeta = window("@2", session: "$2", topic: "b")
        let agents = [agent("%1", in: inAlpha), agent("%2", in: inAlpha, .working), agent("%3", in: inAlpha, .failed, unread: true),
                      agent("%4", in: inBeta, .blocked, unread: true), agent("%5", in: inBeta, .working)]
        XCTAssertEqual(model([alpha, beta], [inAlpha, inBeta], agents, selected: "@1").visibleAgents.map(\.paneID), ["%3", "%2", "%1"])
    }

    func testSessionsModeListsOnlyTheAgentsOfTheSelectedWindowsSession() {
        let first = window("@1", session: "$1", topic: "a")
        let second = window("@2", session: "$1", topic: "a")
        let other = window("@3", session: "$2", topic: "a")
        let windows = [first, second, other]
        let agents = [agent("%1", in: first), agent("%2", in: second), agent("%3", in: other, .blocked, unread: true)]

        let onFirst = model([alpha], windows, agents, selected: "@1", mode: .sessions)
        XCTAssertEqual(onFirst.visibleAgents.map(\.paneID), ["%1", "%2"])
        XCTAssertEqual(onFirst.agentsScope, .session(id: "$1", name: "name-$1"))
        XCTAssertEqual(onFirst.sessionMarks, ["$2": .blocked])

        let onOther = model([alpha], windows, agents, selected: "@3", mode: .sessions)
        XCTAssertEqual(onOther.visibleAgents.map(\.paneID), ["%3"])
        XCTAssertEqual(onOther.agentsScope.name, "name-$2")
    }

    func testSessionsModeScopesBySessionWhenTheConfigTurnsTopicsOff() {
        let first = window("@1", session: "$1", topic: "a")
        let other = window("@2", session: "$2", topic: "a")
        var config = Config()
        config.sidebar.topics = false
        var selection = TopicSelection()
        selection.windowID = "@1"
        let scoped = TopicsModel(records: [alpha], windows: [first, other], config: config, selection: selection,
                                 mode: .topics, agents: [agent("%1", in: first), agent("%2", in: other)])
        XCTAssertEqual(scoped.mode, .sessions)
        XCTAssertEqual(scoped.visibleAgents.map(\.paneID), ["%1"])
    }

    func testAllListsEveryAgentInBothModesExceptSnoozedTopics() {
        var snoozed = beta
        snoozed.snoozedUntil = "never"
        let inAlpha = window("@1", session: "$1", topic: "a")
        let inBeta = window("@2", session: "$2", topic: "b")
        let loose = window("@3", session: "$3", topic: nil)
        let agents = [agent("%1", in: inAlpha), agent("%2", in: inBeta), agent("%3", in: loose)]
        for mode in [SidebarMode.topics, .sessions] {
            let every = model([alpha, snoozed], [inAlpha, inBeta, loose], agents, selected: "@1", mode: mode, scope: .all)
            XCTAssertEqual(every.agentsScope, .everyAgent, "\(mode)")
            XCTAssertNil(every.agentsScope.name, "\(mode)")
            XCTAssertEqual(every.visibleAgents.map(\.paneID), ["%1", "%3"], "\(mode)")
            let groups = mode == .topics ? ["%1": "Alpha", "%3": "No Topic"] : ["%1": "name-$1", "%3": "name-$3"]
            XCTAssertEqual(every.agentGroups, groups, "\(mode)")
        }
    }

    func testSnoozedTopicAgentsStayHiddenInTheirOwnScope() {
        var snoozed = alpha
        snoozed.snoozedUntil = "never"
        let inAlpha = window("@1", session: "$1", topic: "a")
        let blocked = agent("%1", in: inAlpha, .blocked, unread: true)
        for mode in [SidebarMode.topics, .sessions] {
            let scoped = model([snoozed], [inAlpha], [blocked], selected: "@1", mode: mode)
            XCTAssertEqual(scoped.visibleAgents, [], "\(mode)")
            XCTAssertEqual(scoped.sessionMarks, [:], "\(mode)")
        }
    }
}
