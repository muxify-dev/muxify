import XCTest
@testable import MuxifyCore
import MuxifyTestSupport

final class InventoryReadTests: XCTestCase {
    func testReaderDistinguishesMissingServerTimeoutAndLostConnection() {
        let failures: [(TmuxError, InventoryReadFailure)] = [
            (.failed(status: 1, stderr: "no server running on /test/socket"), .noServer),
            (.failed(status: 1, stderr: "error connecting to /test/socket (No such file or directory)"), .noServer),
            (.timedOut, .timedOut),
            (.failed(status: 1, stderr: "lost server"), .connectionLost),
            (.failed(status: 1, stderr: "server exited unexpectedly"), .connectionLost),
        ]
        for (processError, expected) in failures {
            XCTAssertThrowsError(try Tmux.readSnapshot { _ in throw processError }) {
                XCTAssertEqual($0 as? InventoryReadFailure, expected)
            }
        }
    }

    func testReaderPreservesErrorsThatDoNotDescribeTheConnection() {
        for failure in [TmuxError.notInstalled, .cancelled, .notReady,
                        .failed(status: 1, stderr: "error connecting to /test/socket (Permission denied)"),
                        .failed(status: 255, stderr: "unexpected local command failure"),
                        .failed(status: 255, stderr: "error connecting to socket (No such file or directory)")] {
            XCTAssertThrowsError(try Tmux.readSnapshot { _ in throw failure }) {
                XCTAssertEqual($0 as? TmuxError, failure)
            }
        }
    }

    func testNoSessionsMeansAnEmptyRunningServer() throws {
        let snapshot = try Tmux.readSnapshot { _ in throw TmuxError.failed(status: 1, stderr: "no sessions") }
        XCTAssertTrue(snapshot.serverRunning)
        XCTAssertTrue(snapshot.windows.isEmpty)
        XCTAssertTrue(snapshot.panes.isEmpty)
    }

    func testServerConvertsOnlyConfirmedAbsenceToAnEmptyInventory() throws {
        _ = try requireTmux()
        let missing = TmuxServer(options: []) { _, _ in
            throw TmuxError.failed(status: 1, stderr: "no server running on /test/socket")
        }
        XCTAssertFalse(try missing.snapshot().serverRunning)
        for (processError, expected) in [(TmuxError.timedOut, InventoryReadFailure.timedOut),
                                         (.failed(status: 1, stderr: "lost server"), .connectionLost)] {
            let server = TmuxServer(options: []) { _, _ in throw processError }
            XCTAssertThrowsError(try server.snapshot()) {
                XCTAssertEqual($0 as? InventoryReadFailure, expected)
            }
        }
    }

    func testFailedInventoryCannotChangeTopicRecords() throws {
        _ = try requireTmux()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = MuxifyPaths(environment: ["XDG_STATE_HOME": directory.path], home: "/nonexistent")
        let store = TopicStore(paths: paths)
        try store.write { records in
            var record = TopicRecord(id: "kept", title: "Keep")
            record.isUnread = true
            try records.create(record)
        }
        let before = try store.read().records
        let server = TmuxServer(options: []) { _, _ in throw TmuxError.timedOut }
        let response = EnvironmentService(paths: paths, server: server).handle(EnvironmentRequest(.markAllRead))
        guard case .failed(let failure) = response else { return XCTFail("\(response)") }
        XCTAssertEqual(failure.kind, .tmuxFailed)
        XCTAssertEqual(failure.phase, .nothingChanged)
        XCTAssertEqual(failure.message, InventoryReadFailure.timedOut.description)
        XCTAssertEqual(try store.read().records, before)
    }
}
