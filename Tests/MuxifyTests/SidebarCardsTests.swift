import XCTest
@testable import MuxifyCore

/// The Sidebar's sections, in order, with each card's label, state and mark, from the cards that `TopicsList` builds.
final class SidebarCardsTests: XCTestCase {
    private func window(_ session: String, topic: String? = nil, lock: Double? = nil) -> TmuxWindow {
        TmuxWindow(id: "@" + session.dropFirst(), sessionID: session, sessionName: "s" + session.dropFirst(), index: 0, name: "shell",
                   paneTitle: "", path: "/work", command: "zsh", isActive: true, paneCount: 1, hasBell: false, sessionActivity: 0, agent: "",
                   storedBrowser: StoredBrowser(), openRequests: [], topicID: topic, lockOrder: lock)
    }

    private func agent(in session: String, _ status: AgentStatus, unread: Bool = false) -> TmuxPane {
        TmuxPane(id: "%" + session.dropFirst() + status.rawValue, windowID: "@" + session.dropFirst(), command: "claude", agent: "claude",
                 agentStatus: status.rawValue, unread: unread)
    }

    private func topic(_ id: String, order: Double, title: String? = nil, change: (inout TopicRecord) -> Void = { _ in }) -> TopicRecord {
        var record = TopicRecord(id: id, title: title ?? id.capitalized)
        record.order = order
        change(&record)
        return record
    }

    private var records: [TopicRecord] {
        [
            topic("pinned", order: 9) { $0.isPinned = true },
            topic("alpha", order: 0) { $0.isUnread = true },
            topic("beta", order: 2) { $0.sessions = [.object(["id": .string("saved"), "directory": .string("/work")])] },
            topic("guest", order: 3) { $0.isGuest = true },
            topic("untitled-a", order: 5, title: "") { $0.slug = "untitled-2" },
            topic("untitled-b", order: 6, title: ""),
            topic("chores", order: 7) { $0.isUnread = true },
        ]
    }

    private let openPlaces = [OpenPlace(id: "gap", order: 1)]

    private var tmux: TmuxSnapshot {
        let windows = [window("$1", topic: "pinned"), window("$2", topic: "alpha"), window("$3", topic: "guest"), window("$4", lock: 4),
                       window("$5", topic: "untitled-b"), window("$6"), window("$7", topic: "chores")]
        let panes = [agent(in: "$1", .working), agent(in: "$2", .blocked), agent(in: "$2", .done, unread: true),
                     agent(in: "$4", .failed, unread: true), agent(in: "$5", .done, unread: true), agent(in: "$7", .working)]
        return TmuxSnapshot(windows: windows, clients: [], panes: panes, serverRunning: true)
    }

    private func config(inPlay: Int) -> Config {
        var config = Config()
        config.topics.inPlay = inPlay
        return config
    }

    /// Each section as lines of `kind id label state mark`, as the Sidebar lists its cards.
    private func sidebar(inPlay: Int) -> [String: [String]] {
        let tmux = tmux
        let model = TopicsModel(records: records, openPlaces: openPlaces, windows: tmux.windows, config: config(inPlay: inPlay),
                                selection: TopicSelection(), benchShown: true, agents: tmux.agents)
        var sections: [String: [String]] = [:]
        var section = "pinned"
        for item in model.list {
            switch item {
            case .card(let row):
                if section == "pinned", !row.isPinned { section = "places" }
                switch row.id {
                case .topic(let id): sections[section, default: []].append(["topic", id, row.title, row.state?.rawValue ?? "-", row.mark?.rawValue ?? "-"].joined(separator: " "))
                case .locked(let session): sections[section, default: []].append(["session", session, row.mark?.rawValue ?? "-"].joined(separator: " "))
                case .noTopic: XCTFail("No Topic has no card")
                }
            case .openPlace(let id, _): sections[section, default: []].append("open " + id)
            case .guestsLine: section = "guests"
            case .benchLine: section = "bench"
            case .noTopicSession: XCTFail("no No Topic Session is open")
            }
        }
        return sections
    }

    func testEachInPlaySectionShowsItsCardsWithTheirLabelsStatesAndMarks() {
        let shown = sidebar(inPlay: 2)
        XCTAssertEqual(shown["pinned"], ["topic pinned Pinned live working"])
        XCTAssertEqual(shown["places"], ["topic alpha Alpha live blocked", "open gap"], "the fixture covers an Open Place")
        XCTAssertEqual(shown["guests"], ["topic guest Guest live -", "session $4 failed"])
        XCTAssertEqual(shown["bench"], ["topic beta Beta dormant -", "topic untitled-a Untitled 2 empty -",
                                        "topic untitled-b Untitled 1 live done", "topic chores Chores live unread"])
    }
}
