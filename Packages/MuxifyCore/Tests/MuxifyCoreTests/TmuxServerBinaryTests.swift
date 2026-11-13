import XCTest
@testable import MuxifyCore
import MuxifyTestSupport

final class TmuxServerBinaryTests: XCTestCase {
    private var directory: URL!
    private var socket: String!
    private var saved: [String: String?] = [:]

    override func setUpWithError() throws {
        _ = try requireTmux()
        // A short path: a socket path must fit in 104 bytes.
        directory = URL(fileURLWithPath: "/tmp/mxb-" + UUID().uuidString.prefix(8), isDirectory: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("bin"), withIntermediateDirectories: true)
        socket = directory.appendingPathComponent("socket").path
        for name in ["TMUX", "TMUX_PANE", "TMUX_TMPDIR"] { saved[name] = ProcessInfo.processInfo.environment[name] }
        unsetenv("TMUX")
        unsetenv("TMUX_PANE")
        setenv("TMUX_TMPDIR", directory.path, 1)
    }

    override func tearDownWithError() throws {
        chmod(socket, 0o700)
        for server in [TmuxServer(socketPath: socket), TmuxServer.local] {
            guard let path = try? server.run(["display-message", "-p", "#{socket_path}"]).trimmingCharacters(in: .whitespacesAndNewlines),
                  URL(fileURLWithPath: path).resolvingSymlinksInPath().path.hasPrefix(directory.resolvingSymlinksInPath().path + "/") else { continue }
            _ = try? server.run(["kill-server"])
        }
        for (name, value) in saved {
            if let value { setenv(name, value, 1) } else { unsetenv(name) }
        }
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    /// A copy of the tmux binary under a folder that no search looks in. The search finds a symlink in Homebrew's
    /// folder, so the copy is of the file it points to.
    private func copyOfTmux(named name: String) throws -> String {
        let copy = directory.appendingPathComponent("bin/\(name)").path
        try FileManager.default.copyItem(atPath: URL(fileURLWithPath: try requireTmux()).resolvingSymlinksInPath().path, toPath: copy)
        return copy
    }

    /// Starts a server from `binary`: on `socket` when `onSocket`, else on the default socket of `$TMUX_TMPDIR`.
    private func startServer(from binary: String, onSocket: Bool = true) throws {
        var environment = ProcessInfo.processInfo.environment
        environment["TMUX"] = nil
        environment["TMUX_PANE"] = nil
        let options = onSocket ? ["-S", socket!] : []
        _ = try CommandRunner().run(CommandInvocation(executable: binary, arguments: ["-u"] + options + ["-f", "/dev/null", "new-session", "-d", "-s", "work"]),
                                    environment: environment)
    }

    private func same(_ path: String?, _ other: String) -> Bool {
        path.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() == URL(fileURLWithPath: other).resolvingSymlinksInPath() } ?? false
    }

    func testAServerAtASocketRunsTheBinaryItWasStartedFrom() throws {
        let copy = try copyOfTmux(named: "tmux")
        try startServer(from: copy)
        XCTAssertFalse(same(Tmux.binary, copy), "the search must not find the copy, or this test proves nothing")

        let server = TmuxServer(socketPath: socket)
        let executable = try server.invocation(["list-sessions"]).executable
        XCTAssertTrue(same(executable, copy), executable)
        XCTAssertEqual(try server.snapshot().windows.map(\.sessionName), ["work"])
    }

    func testTheLocalServerRunsTheBinaryOfTheDefaultSocketsServer() throws {
        let copy = try copyOfTmux(named: "tmux")
        try startServer(from: copy, onSocket: false)
        XCTAssertTrue(same(TmuxServer.local.binary, copy), TmuxServer.local.binary ?? "nil")
        XCTAssertTrue(same(TmuxServer(configPath: "/dev/null").binary, copy))
        XCTAssertEqual(try TmuxServer.local.snapshot().windows.map(\.sessionName), ["work"])
    }

    func testAClientInASessionOfAServerRunsThatServersBinary() throws {
        let copy = try copyOfTmux(named: "tmux")
        try startServer(from: copy)
        let environment = ["TMUX": socket + ",1234,0"]
        XCTAssertTrue(same(TmuxServer.ofClient(environment: environment).binary, copy))
    }

    func testARestartedServerOfAnotherBinaryIsFoundAgain() throws {
        let first = try copyOfTmux(named: "tmux")
        try startServer(from: first)
        let server = TmuxServer(socketPath: socket)
        XCTAssertTrue(same(server.binary, first))
        try server.run(["kill-server"])

        let second = try copyOfTmux(named: "tmux-second")
        try startServer(from: second)
        XCTAssertTrue(same(server.binary, second), server.binary ?? "nil")
    }

    func testAServerFoundFromManyThreadsAtOnceAnswersTheSameBinary() throws {
        let copy = try copyOfTmux(named: "tmux")
        try startServer(from: copy)
        let server = TmuxServer(socketPath: socket)
        let lock = NSLock()
        var answers: [String?] = []
        DispatchQueue.concurrentPerform(iterations: 24) { _ in
            let binary = server.binary
            lock.lock()
            answers.append(binary)
            lock.unlock()
        }
        XCTAssertEqual(answers.count, 24)
        XCTAssertTrue(answers.allSatisfy { same($0, copy) }, "\(answers)")
    }

    func testWithNoSocketFileTheSnapshotIsEmptyAndTheSearchedBinaryRuns() throws {
        let server = TmuxServer(socketPath: socket)
        XCTAssertEqual(server.binary, Tmux.binary)
        let snapshot = try server.snapshot()
        XCTAssertFalse(snapshot.serverRunning)
        XCTAssertTrue(snapshot.windows.isEmpty)
    }

    func testASocketFileThatNoServerListensOnIsNoServer() throws {
        let copy = try copyOfTmux(named: "tmux")
        try startServer(from: copy)
        let pid = try XCTUnwrap(Int32(CommandRunner().run(CommandInvocation(executable: copy, arguments: ["-S", socket, "display-message", "-p", "#{pid}"]))
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        // A killed server leaves its socket file behind. tmux answers a refused connection with "no server running".
        kill(pid, SIGKILL)
        let deadline = Date().addingTimeInterval(5)
        while kill(pid, 0) == 0, Date() < deadline { usleep(10_000) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: socket))

        let server = TmuxServer(socketPath: socket)
        XCTAssertEqual(server.binary, Tmux.binary)
        let snapshot = try server.snapshot()
        XCTAssertFalse(snapshot.serverRunning)
        XCTAssertTrue(snapshot.windows.isEmpty)
    }

    func testAServerThatTmuxCannotReachMakesTheSnapshotFailNamingTheServersBinary() throws {
        let copy = try copyOfTmux(named: "tmux")
        try startServer(from: copy)
        XCTAssertEqual(chmod(socket, 0), 0)

        let server = TmuxServer(socketPath: socket)
        do {
            _ = try server.snapshot()
            XCTFail("the snapshot did not throw")
        } catch let TmuxError.serverFailed(binary, _, stderr) {
            XCTAssertTrue(same(binary, copy), binary)
            XCTAssertTrue(stderr.contains("Permission denied"), stderr)
            XCTAssertTrue(TmuxError.serverFailed(binary: binary, status: 1, stderr: stderr).localizedDescription.contains(binary))
        } catch {
            XCTFail("\(error)")
        }
    }
}
