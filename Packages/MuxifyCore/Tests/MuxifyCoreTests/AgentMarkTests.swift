import XCTest
@testable import MuxifyCore

final class AgentMarkTests: XCTestCase {
    private func agent(_ status: AgentStatus?, unread: Bool) -> Agent {
        Agent(paneID: "%1", kind: .claude, status: status, unread: unread, windowID: "@1", sessionID: "$1",
              sessionName: "s", windowIndex: 1, windowTitle: "Agent", label: "Agent")
    }

    private func notifications(done: Bool = true, failed: Bool = true, blocked: Bool = true) -> Config.Notifications {
        var notifications = Config.Notifications()
        notifications.doneEnabled = done
        notifications.failedEnabled = failed
        notifications.blockedEnabled = blocked
        return notifications
    }

    /// The whole table: each Status, read and Unread, with each Notification type on and off.
    func testEveryStatusReadOrUnreadUnderEachSwitchAndQuiet() {
        let statuses: [AgentStatus?] = [nil, .working, .done, .failed, .blocked]
        for status in statuses {
            for unread in [false, true] {
                for done in [false, true] {
                    for failed in [false, true] {
                        for blocked in [false, true] {
                            let expected: AgentMark?
                            switch status {
                            case .working?: expected = .working
                            case .blocked? where blocked: expected = .blocked
                            case .failed? where failed && unread: expected = .failed
                            case .done? where done && unread: expected = .done
                            default: expected = nil
                            }
                            let mark = AgentMark(agent(status, unread: unread),
                                                 notifications: notifications(done: done, failed: failed, blocked: blocked))
                            XCTAssertEqual(mark, expected, "\(String(describing: status)) unread=\(unread) done=\(done) "
                                           + "failed=\(failed) blocked=\(blocked)")
                        }
                    }
                }
            }
        }
    }

    func testAReadDoneAgentHasNoMark() {
        XCTAssertNil(AgentMark(agent(.done, unread: false), notifications: Config.Notifications()))
    }

    func testAGroupShowsItsStrongestMember() {
        XCTAssertEqual([AgentMark.working, .done, .failed, .blocked].max(), .blocked)
        XCTAssertEqual([AgentMark.done, .failed, .working].max(), .failed)
        XCTAssertEqual([AgentMark.working, .done].max(), .done)
        XCTAssertEqual([AgentMark.working].max(), .working)
        XCTAssertEqual(AgentMark.allCases.filter(\.isNotification), [.done, .failed, .blocked])
    }
}
