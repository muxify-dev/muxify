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

    func testRemoteReadDistinguishesStartupTimeoutAndLostConnection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("ssh")
        let environment = RemoteEnvironment(name: "Test", host: "unused", username: "test")
        let cases: [(String, Error)] = [
            ("exit 255", TmuxError.notReady),
            ("exec /bin/sleep 5", InventoryReadFailure.timedOut),
            ("""
            case " $* " in *" -O check "*) exit 0 ;; esac
            printf 'no server running on /test/socket\\n' >&2
            exit 1
            """, InventoryReadFailure.noServer),
            ("""
            case " $* " in *" -O check "*) exit 0 ;; esac
            printf 'lost server\\n' >&2
            exit 1
            """, InventoryReadFailure.connectionLost),
            ("""
            case " $* " in
                *" -O check "*) exit 0 ;;
                *list-windows*) printf 'connection closed\\n' >&2; exit 255 ;;
            esac
            printf '%s\\n' '123\(Tmux.separator)/dev/test\(Tmux.separator)/home/test\(Tmux.separator)test\(Tmux.separator)remote'
            """, InventoryReadFailure.connectionLost),
        ]
        for (script, expected) in cases {
            try ("#!/bin/sh\n" + script + "\n").write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            let connection = try TmuxConnection(environment: environment, sshExecutable: executable.path)
            XCTAssertThrowsError(try connection.snapshot()) { error in
                if let failure = expected as? InventoryReadFailure {
                    XCTAssertEqual(error as? InventoryReadFailure, failure)
                } else {
                    XCTAssertEqual(error as? TmuxError, expected as? TmuxError)
                }
            }
        }
    }

}
