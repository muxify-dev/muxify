import XCTest
@testable import MuxifyCore

final class ReadDecisionTests: XCTestCase {
    private let topic = TopicRecord(id: "topic", title: "Fix", slug: "fix")

    private func window(zoomed: Bool, activePane: String = "%1") -> TmuxWindow {
        var window = TmuxWindow(id: "@1", sessionID: "$1", sessionName: "s", index: 0,
            name: "shell", paneTitle: "", path: "/work", command: "zsh", isActive: true,
            paneCount: 3, hasBell: false, sessionActivity: 0, agent: "", storedBrowser: StoredBrowser(),
            openRequests: [], topicID: "topic", activePaneID: activePane)
        window.isZoomed = zoomed
        return window
    }

    private func agent(_ pane: String, _ status: AgentStatus? = .done, unread: Bool) -> Agent {
        Agent(paneID: pane, kind: .claude, status: status, unread: unread, windowID: "@1", sessionID: "$1",
              sessionName: "s", windowIndex: 0, windowTitle: "Agent", label: "Agent")
    }

    private func decide(_ change: ReadChange, _ place: ReadPlan.Place, agents: [Agent], zoomed: Bool = true,
                        busy: Bool = false, writable: Bool = true) -> ReadPlan.Decision {
        ReadPlan.decide(change, in: place, records: [topic], agents: agents, windows: [window(zoomed: zoomed)],
                        busy: busy, agentsWritable: writable)
    }

    func testReadOfAZoomedPaneWithNothingUnreadNamesTheHiddenUnreadPanes() {
        let agents = [agent("%1", unread: false), agent("%2", unread: true), agent("%3", .failed, unread: true)]
        XCTAssertEqual(decide(.read, .pane("%1"), agents: agents), .refused(.onlyHiddenByZoom(hiddenPanes: 2)))
    }

    func testReadOfAZoomedPaneCountsTheUnreadPanesItLeaves() {
        let agents = [agent("%1", unread: true), agent("%2", unread: true), agent("%3", unread: false)]
        XCTAssertEqual(decide(.read, .pane("%1"), agents: agents),
                       .change(TopicReadChange(paneIDs: [PaneID(rawValue: "%1")!]), hiddenUnreadPanes: 1))
    }

    func testReadOfAZoomedPaneWithNoOtherUnreadPaneHidesNothing() {
        let agents = [agent("%1", unread: true), agent("%2", unread: false)]
        XCTAssertEqual(decide(.read, .pane("%1"), agents: agents),
                       .change(TopicReadChange(paneIDs: [PaneID(rawValue: "%1")!]), hiddenUnreadPanes: 0))
        XCTAssertEqual(decide(.read, .pane("%1"), agents: [agent("%1", unread: false), agent("%2", unread: false)]),
                       .refused(.nothingToChange))
    }

    func testAPaneThatIsNotZoomedHidesNoPanes() {
        let agents = [agent("%1", unread: false), agent("%2", unread: true)]
        XCTAssertEqual(decide(.read, .pane("%1"), agents: agents, zoomed: false), .refused(.nothingToChange),
                       "a Pane row names its own Pane, and the Window shows the others")
        XCTAssertEqual(decide(.read, .pane("%2"), agents: agents),
                       .change(TopicReadChange(paneIDs: [PaneID(rawValue: "%2")!]), hiddenUnreadPanes: 0),
                       "only the Zoomed Pane hides the other Panes")
    }

    func testUnreadOfAZoomedPaneDoesNotCountHiddenPanes() {
        let agents = [agent("%1", unread: false), agent("%2", unread: true)]
        XCTAssertEqual(decide(.unread, .pane("%1"), agents: agents),
                       .change(TopicReadChange(paneIDs: [PaneID(rawValue: "%1")!]), hiddenUnreadPanes: 0))
        XCTAssertEqual(decide(.unread, .pane("%1"), agents: [agent("%1", .working, unread: false), agent("%2", unread: true)]),
                       .refused(.nothingToChange), "a working Agent does not become Unread")
    }

    func testAWindowWithNothingToChangeIsRefused() {
        XCTAssertEqual(decide(.read, .window("@1"), agents: [agent("%1", unread: false)]), .refused(.nothingToChange))
    }

    func testBusyRefusesEvenAChangeThatCouldRun() {
        XCTAssertEqual(decide(.read, .window("@1"), agents: [agent("%1", unread: true)], busy: true), .refused(.busy))
        XCTAssertEqual(decide(.read, .topic("topic"), agents: [], busy: true), .refused(.busy))
    }

    func testWithoutTmuxOnlyATopicMarkCanChange() {
        XCTAssertEqual(decide(.read, .window("@1"), agents: [agent("%1", unread: true)], writable: false), .refused(.disconnected))
        XCTAssertEqual(decide(.unread, .topic("topic"), agents: [], writable: false),
                       .change(TopicReadChange(topicIDs: ["topic"]), hiddenUnreadPanes: 0))
    }

    func testAKnownTopicAlwaysTakesTheChange() {
        XCTAssertEqual(decide(.read, .topic("topic"), agents: [agent("%1", unread: false)]),
                       .change(TopicReadChange(), hiddenUnreadPanes: 0))
        XCTAssertEqual(decide(.read, .topic("gone"), agents: []), .refused(.nothingToChange))
    }
}
