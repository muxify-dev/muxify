import XCTest
@testable import MuxifyCore

final class TmuxRecoveryTests: XCTestCase {
    func testOnlyConfirmedSessionAbsenceEnablesEmptyServerRecovery() {
        XCTAssertTrue(TmuxError.failed(status: 1, stderr: "no sessions").indicatesNoSessions)
        XCTAssertTrue(TmuxError.failed(status: 1, stderr: "no server running on /test/socket").indicatesNoSessions)
        XCTAssertTrue(TmuxError.failed(status: 1, stderr: "error connecting to /test/socket (No such file or directory)").indicatesNoSessions)
        for error in [TmuxError.timedOut, .notReady, .cancelled, .notInstalled,
                      .failed(status: 1, stderr: "error connecting to /test/socket (Permission denied)")] {
            XCTAssertFalse(error.indicatesNoSessions, error.description)
        }
    }

}
