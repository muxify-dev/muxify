import XCTest
@testable import MuxifyCore

/// The palette shows a running Session in place of the folder row with the same launch name. So a Session that
/// leaves its Topic must not take the launch name of a folder it does not run in.
final class LeavingTopicNamingTests: XCTestCase {
    private let topic = TopicRecord(id: "topic", title: "Fix", slug: "fix")
    private let sessionPaths = [SessionPath(path: "/work/game", name: "game", layout: .plainRepository([
        Worktree(path: "/work/game", branch: "main"), Worktree(path: "/trees/game/monitors", branch: "monitors"),
        Worktree(path: "/trees/game/review", branch: "review")]))]
    private let bare = [SessionPath(path: "/work/tool", name: "tool", layout: .bareRepository([
        Worktree(path: "/work/tool/main", branch: "main"), Worktree(path: "/work/tool/feat", branch: "feat")]))]

    private func window(_ name: String, in folder: String) -> TmuxWindow {
        TmuxWindow(id: "@1", sessionID: "$1", sessionName: name, index: 0, name: "shell", paneTitle: "",
            path: folder, command: "zsh", isActive: true, paneCount: 1, hasBell: false, sessionActivity: 0,
            agent: "", storedBrowser: StoredBrowser(), openRequests: [], topicID: "topic", sessionPath: folder)
    }

    private func names(_ commands: [TopicPlan.Command]) -> [String] {
        commands.compactMap {
            switch $0 {
            case .tmux(let args) where args.first == "rename-session": args.last
            case .newTopicSession(let name, _): name
            default: nil
            }
        }
    }

    private func leaving(_ window: TmuxWindow, sessionPaths: [SessionPath]? = nil) throws -> [String: [String]] {
        let sessionPaths = sessionPaths ?? self.sessionPaths
        let live = TmuxSnapshot(windows: [window], clients: [], panes: [], serverRunning: true)
        return [
            "settle": names(TopicSettlePlan(topic: topic, snapshot: live, sessionPaths: sessionPaths, choices: [], outcome: "").edit.commands),
            "forget": names(TopicForgetPlan(topic: topic, snapshot: live, sessionPaths: sessionPaths, choices: [], worktrees: [],
                                              paths: MuxifyPaths(environment: ["XDG_STATE_HOME": "/nonexistent-state"])).edit.commands),
            "remove": names(TopicMembershipPlan(removingSession: window, records: [topic], sessionPaths: sessionPaths,
                                                  windows: [window]).commands),
            "move": names(try TopicMembershipPlan(source: .session(window), destination: nil, records: [topic], windows: [window],
                                                    sessionPaths: sessionPaths).commands),
            "move window": names(try TopicMembershipPlan(source: .window(window), destination: nil, records: [topic], windows: [window],
                                                           sessionPaths: sessionPaths).commands),
        ]
    }

    func testAWorktreeSessionLeavesItsTopicUnderTheWorktreesLaunchName() throws {
        let expected = ["game/monitors"]
        XCTAssertEqual(try leaving(window("game/fix", in: "/trees/game/monitors")),
                       ["settle": expected, "forget": expected, "remove": expected, "move": expected, "move window": expected])
    }

    func testASessionInTheSessionPathFolderLeavesItsTopicUnderTheSessionPathName() throws {
        let expected = ["game"]
        XCTAssertEqual(try leaving(window("game/fix", in: "/work/game")),
                       ["settle": expected, "forget": expected, "remove": expected, "move": expected, "move window": expected])
    }

    func testARenamedWorktreeSessionKeepsItsNameWhenItLeavesItsTopic() throws {
        let expected = ["custom"]
        XCTAssertEqual(try leaving(window("custom/fix", in: "/trees/game/monitors")),
                       ["settle": expected, "forget": expected, "remove": expected, "move": expected, "move window": expected])
    }

    func testASecondWorktreeSessionOfARepositoryLeavesItsTopicUnderItsWorktreesLaunchName() throws {
        let expected = ["game/review"]
        XCTAssertEqual(try leaving(window("game+2/fix", in: "/trees/game/review")),
                       ["settle": expected, "forget": expected, "remove": expected, "move": expected, "move window": expected])
    }

    func testACheckoutInABareRepositoryLeavesItsTopicUnderItsLaunchName() throws {
        let expected = ["tool/feat"]
        XCTAssertEqual(try leaving(window("tool/fix", in: "/work/tool/feat"), sessionPaths: bare),
                       ["settle": expected, "forget": expected, "remove": expected, "move": expected, "move window": expected])
    }
}
