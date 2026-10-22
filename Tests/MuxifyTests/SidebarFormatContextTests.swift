import XCTest
@testable import MuxifyCore

final class SidebarFormatContextTests: XCTestCase {
    private func window(_ id: String = "@1", remote: Bool = false) -> TmuxWindow {
        TmuxWindow(id: id, sessionID: "$1", sessionName: "app-feature", index: 2, name: "shell", paneTitle: "Task",
                   path: "/trees/feature/src", command: "sleep", isActive: true, paneCount: 1,
                   hasBell: false, sessionActivity: 0, agent: "codex", storedBrowser: .init(), openRequests: [],
                   isRemote: remote, topicID: "topic", sessionPath: "/trees/feature")
    }

    func testContextsKeepBranchAndDefaultSummaryAndIncludeHiddenPanes() throws {
        var record = TopicRecord(id: "topic", title: "Task", slug: "task")
        record.sessions = [.object(["repository_path": .string("/app"), "worktree_path": .string("/trees/feature")])]
        let window = window()
        let pane = TmuxPane(id: "%1", windowID: "@1", index: 3, isActive: true, title: "Agent task",
                            path: "/trees/feature/src", command: "sleep", agent: "codex", agentStatus: "working", unread: true)
        let agents = Agent.list(panes: [pane], windows: [window])
        let branches = TopicBranches(records: [record], paths: [window.sessionPath, pane.path].map(Folder.local)) {
            $0 == "/trees/feature/.git/HEAD" ? "ref: refs/heads/feature" : nil
        }
        let model = TopicsModel(records: [record], windows: [window], config: Config(), selection: TopicSelection(),
                                agents: agents, panes: nil)
        let contexts = SidebarFormatContexts(model: model, windows: [window], panes: [pane], agents: agents,
                                             branches: branches, records: [record], sessionPaths: [], tabCounts: ["@1": 4])
        let topic = try XCTUnwrap(contexts.topics[.topic("topic")])
        XCTAssertEqual(SidebarFormats.defaults.text(for: .topic, in: topic, mode: .topics).summary, "app-feature · 1 Window")
        XCTAssertEqual(try SidebarFormat("#{S:#{branch}}").expand(in: topic), "feature")
        XCTAssertEqual(try SidebarFormat("#{P:#{session_name}/#{window_index}/#{pane_index}/#{branch}/#{tab_count}}").expand(in: topic),
                       "app-feature/2/3/feature/4")
        XCTAssertEqual(try SidebarFormat("#{pane_count}/#{agent_count}/#{agents_working}/#{agents_unread}").expand(in: topic), "1/1/1/1")
    }

    func testAgentDefaultsKeepGroupTextAndHideItInScopedSections() throws {
        for hasTopic in [true, false] {
            var window = window()
            if !hasTopic { window.topicID = nil }
            let records = hasTopic ? [TopicRecord(id: "topic", title: "Task", slug: "task")] : []
            let pane = TmuxPane(id: "%1", windowID: window.id, title: "Agent task", command: "sleep",
                                agent: "codex", agentStatus: "working", unread: false)
            let agents = Agent.list(panes: [pane], windows: [window])
            for mode in [SidebarMode.topics, .sessions] {
                for scope in [Config.Sidebar.AgentsScope.all, .active, .window] {
                    var config = Config()
                    config.sidebar.agentsScope = .init(scope)
                    let model = TopicsModel(records: records, windows: [window], config: config,
                                            selection: TopicSelection(windowID: window.id), mode: mode, agents: agents)
                    let contexts = SidebarFormatContexts(model: model, windows: [window], panes: [pane], agents: agents,
                                                         branches: TopicBranches(), records: records, sessionPaths: [], tabCounts: [:])
                    let context = try XCTUnwrap(contexts.panes[pane.id])
                    let text = config.sidebar.formats.text(for: .agent, in: context, mode: mode)
                    XCTAssertEqual(text.title, "Agent task")
                    let group = mode == .sessions ? "app-feature" : (hasTopic ? "Task" : "No Topic")
                    XCTAssertEqual(text.summary, scope == .all ? group : "")
                    config.sidebar.formats.agent.title = .init(try SidebarFormat("#{window_name}"))
                    config.sidebar.formats.agent.summary = .init(try SidebarFormat("#{session_name} / #{topic_title}"))
                    let custom = config.sidebar.formats.text(for: .agent, in: context, mode: mode)
                    XCTAssertEqual(custom.title, "shell")
                    XCTAssertEqual(custom.summary, "app-feature / " + (hasTopic ? "Task" : ""))
                }
            }
        }
    }

    func testAgentFormatUsesItsOwnPaneWhileAnotherPaneIsActive() throws {
        let window = window()
        let panes = [
            TmuxPane(id: "%1", windowID: window.id, index: 0, isActive: false, title: "Agent task",
                     path: "/agent", command: "sleep", agent: "codex", agentStatus: "working", unread: false),
            TmuxPane(id: "%2", windowID: window.id, index: 1, isActive: true, title: "Other task",
                     path: "/other", command: "zsh", agent: "claude", agentStatus: "done", unread: false),
        ]
        let records = [TopicRecord(id: "topic", title: "Task", slug: "task")]
        let agents = Agent.list(panes: panes, windows: [window])
        let model = TopicsModel(records: records, windows: [window], config: Config(),
                                selection: TopicSelection(windowID: window.id), agents: agents)
        let contexts = SidebarFormatContexts(model: model, windows: [window], panes: panes, agents: agents,
                                             branches: TopicBranches(), records: records, sessionPaths: [], tabCounts: [:])
        var formats = SidebarFormats.defaults
        formats.agent.title = .init(try SidebarFormat("#{topic_title} / #{window_name}"))
        formats.agent.summary = .init(try SidebarFormat("#{pane_label} / #{pane_current_path} / #{agent_status}"))
        let text = formats.text(for: .agent, in: try XCTUnwrap(contexts.panes["%1"]), mode: .topics)
        XCTAssertEqual(text.title, "Task / shell")
        XCTAssertEqual(text.summary, "Agent task / /agent / working")
    }

    func testRemoteContextsDoNotExposeLocalBranches() throws {
        let window = window(remote: true)
        let branches = TopicBranches(paths: [window.sessionPath].map(Folder.local)) {
            $0 == window.sessionPath + "/.git/HEAD" ? "ref: refs/heads/local" : nil
        }
        XCTAssertEqual(branches[.local(window.sessionPath)], "local")
        let pane = TmuxPane(id: "%1", windowID: window.id, path: window.sessionPath, command: "sleep",
                            agent: "codex", agentStatus: "working", unread: false)
        let model = TopicsModel(records: [], windows: [window], config: Config(), selection: TopicSelection())
        let contexts = SidebarFormatContexts(model: model, windows: [window], panes: [pane], agents: [], branches: branches,
                                             records: [], sessionPaths: [], tabCounts: [:])
        XCTAssertEqual(try SidebarFormat("#{branch}").expand(in: XCTUnwrap(contexts.sessions["$1"])), "")
        XCTAssertEqual(try SidebarFormat("#{branch}").expand(in: XCTUnwrap(contexts.panes["%1"])), "")
    }

    func testWindowAgentScopeWithNoSelectionShowsEveryAgent() {
        var config = Config()
        config.sidebar.agentsScope = .init(.window)
        let windows = [window(), window("@2")]
        let panes = [TmuxPane(id: "%1", windowID: "@1", command: "sleep", agent: "codex", agentStatus: "working", unread: false),
                     TmuxPane(id: "%2", windowID: "@2", command: "sleep", agent: "claude", agentStatus: "done", unread: false)]
        let agents = Agent.list(panes: panes, windows: windows)
        let model = TopicsModel(records: [], windows: windows, config: config, selection: TopicSelection(), agents: agents)
        XCTAssertEqual(model.agentsScope, .everyAgent)
        XCTAssertEqual(Set(model.visibleAgents.map(\.paneID)), ["%1", "%2"])
    }
}
