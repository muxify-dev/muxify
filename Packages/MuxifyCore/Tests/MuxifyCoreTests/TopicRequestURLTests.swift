import XCTest
@testable import MuxifyCore

final class TopicRequestURLTests: XCTestCase {
    private func request(_ string: String) throws -> EnvironmentRequest {
        try EnvironmentRequest(url: try XCTUnwrap(URL(string: string)))
    }

    private let pane7 = EnvironmentTarget.pane(PaneID(rawValue: "%7")!)

    func testNewTakesOnlyATitleAndMakesAnEmptyTopic() throws {
        XCTAssertEqual(try request("muxify://topic/new?title=%20Caf%C3%A9%20"), EnvironmentRequest(.create(title: "Café")))
    }

    func testTheOldFormsOfNewNameTheNewForms() {
        for old in ["muxify://topic/new?pane=%257", "muxify://topic/new?pane=%257&sessionPath=%2Fwork%2Fgame",
                    "muxify://topic/new?title=Fix%20reward&sessionPath=%2Fwork%2Fgame", "muxify://topic/new?pane=%257&title=Fix"] {
            XCTAssertThrowsError(try request(old), old) { error in
                XCTAssertTrue("\(error)".contains("muxify window move --new-topic"), "\(error)")
                XCTAssertTrue("\(error)".contains("muxify topic add-session"), "\(error)")
            }
        }
    }

    func testForgetNamesATopicOrPane() throws {
        XCTAssertEqual(try request("muxify://topic/forget?pane=%257"), EnvironmentRequest(.forget(choices: [], worktrees: []), target: pane7))
        XCTAssertEqual(try request("muxify://topic/forget?topic=settled"),
                       EnvironmentRequest(.forget(choices: [], worktrees: []), target: .topic(.named("settled"))))
        XCTAssertThrowsError(try request("muxify://topic/forget?topic=settled&pane=%257"))
    }

    func testMembershipAndLifecycleRequests() throws {
        XCTAssertEqual(try request("muxify://topic/add?pane=%257&sessionPath=%2Fwork%2Ftools"),
                       EnvironmentRequest(.addSession(sessionPath: "/work/tools", workingCopy: .directory), target: pane7))
        XCTAssertEqual(try request("muxify://topic/settle?pane=%257"), EnvironmentRequest(.settle(choices: [], outcome: ""), target: pane7))
        XCTAssertEqual(try request("muxify://topic/move?pane=%257&topic=Fix%20reward"),
                       EnvironmentRequest(.move(to: .topic(.named("Fix reward"))), target: pane7))
    }

    func testLockAndUnlockNameTheSession() throws {
        XCTAssertEqual(try request("muxify://topic/lock?session=my%20notes"), EnvironmentRequest(.lock, target: .sessionName("my notes")))
        XCTAssertEqual(try request("muxify://topic/unlock?session=notes"), EnvironmentRequest(.unlock, target: .sessionName("notes")))
        XCTAssertThrowsError(try request("muxify://topic/lock?pane=%257"))
        XCTAssertThrowsError(try request("muxify://topic/unlock?session=notes&pane=%257"))
        XCTAssertThrowsError(try request("muxify://topic/lock?session="), "a Lock needs a Session name")
    }

    func testRejectsMissingDuplicateAndUnknownInputs() {
        let invalid = [
            "muxify://topic/new?title=", "muxify://topic/new?title=%20&extra=x",
            "muxify://topic/new?pane=%257&title=%20", "muxify://topic/add?pane=%257",
            "muxify://topic/settle", "muxify://topic/move?pane=%257&topic=",
            "muxify://topic/settle?pane=%257&pane=%257", "muxify://topic/settle?pane=%257&pane=%258",
            "muxify://topic/add?pane=%257&sessionPath=relative", "muxify://topic/add?pane=%257&sessionPath=%2Fwork&extra=x",
            "muxify://topic/move?pane=7&topic=fix", "muxify://topic/new?pane=%25x",
            "muxify://topic/new?pane=%257&sessionPath=%2Fwork&sessionPath=%2Fwork",
            "muxify://topic/new?pane=%257&title=Fix&sessionPath=%2Fwork&extra=x",
        ]
        for value in invalid {
            XCTAssertThrowsError(try request(value), value)
        }
    }

    func testRejectsOtherURLShapes() {
        let invalid = [
            "other://topic/new?pane=%257", "muxify://other/new?pane=%257",
            "muxify://topic/new/other?pane=%257", "muxify://topic/new/?pane=%257",
            "muxify://topic/list?pane=%257", "muxify://topic/new?pane=%257#part",
            "muxify://user@topic/new?pane=%257", "muxify://topic:123/new?pane=%257",
            "muxify://topic/new", "muxify://topic/settle?pane=%257&topic=fix",
        ]
        for value in invalid { XCTAssertThrowsError(try request(value), value) }
    }
}
