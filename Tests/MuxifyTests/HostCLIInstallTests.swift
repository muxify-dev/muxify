import XCTest
@testable import MuxifyCore
import MuxifyTestSupport

/// The Host CLI install over a Remote Environment's owned connection, with an SSH fixture that runs the remote
/// command here, in a temporary HOME.
final class HostCLIInstallTests: XCTestCase {
    private final class Reports: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        let arrived: XCTestExpectation

        init(_ arrived: XCTestExpectation) { self.arrived = arrived }

        var all: [String] { lock.withLock { lines } }

        func add(_ line: String) {
            lock.withLock { lines.append(line) }
            arrived.fulfill()
        }
    }

    private func executable(_ text: String, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// The fixture holds an install while `hold` exists; with `refuse`, it fails an install as a lost connection does.
    private func connection(in root: URL, hold: URL, refuse: Bool = false) throws -> TmuxConnection {
        let tools = root.appendingPathComponent("tools")
        let ssh = root.appendingPathComponent("ssh")
        try executable("""
        #!/bin/bash
        unset TMUX TMUX_PANE
        export HOME=\(Tmux.shellQuote(root.appendingPathComponent("home").path))
        export PATH=\(Tmux.shellQuote(tools.path + ":/usr/bin:/bin"))
        for arg do command=$arg; done
        if [[ "$command" == *muxify.new* ]]; then
            while [ -f \(Tmux.shellQuote(hold.path)) ]; do sleep 0.02; done
            \(refuse ? "echo 'ssh: connect to host unused port 22: Connection refused' >&2; exit 255" : "")
        fi
        exec /bin/sh -c "$command"

        """, at: ssh)
        return try TmuxConnection(environment: RemoteEnvironment(name: "Fixture", host: "unused", username: "unused"),
                                  sshExecutable: ssh.path)
    }

    /// An older `muxify` first on the remote PATH, and a published one at the returned `file://` base URL.
    private func publish(in root: URL) throws -> String {
        try executable("#!/bin/sh\necho 'muxify old1234 100'\n", at: root.appendingPathComponent("tools/muxify"))
        let assets = root.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try "muxify abc1234 200\n".write(to: assets.appendingPathComponent("version"), atomically: true, encoding: .utf8)
        for asset in ["muxify-darwin-arm64", "muxify-linux-aarch64", "muxify-linux-x86_64"] {
            try executable("#!/bin/sh\necho 'muxify abc1234 200'\n", at: assets.appendingPathComponent(asset))
        }
        return "file://" + assets.path + "/"
    }

    func testTheConnectDoesNotWaitAndTheResultLineIsReported() throws {
        let root = try TestDirectory()
        let hold = root.url.appendingPathComponent("hold")
        FileManager.default.createFile(atPath: hold.path, contents: nil)
        let connection = try connection(in: root.url, hold: hold)
        defer { connection.retire(); connection.cleanup() }
        let base = try publish(in: root.url)
        let reports = Reports(expectation(description: "reported"))

        let started = Date()
        HostCLI.install(over: connection, environmentName: "Fixture", baseURL: base, report: { reports.add($0) })
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5, "install returns while the script still runs")
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(reports.all, [], "nothing is reported before the script ends")

        try FileManager.default.removeItem(at: hold)
        wait(for: [reports.arrived], timeout: 20)
        XCTAssertEqual(reports.all, ["Host CLI: Fixture: updated old1234 100 -> abc1234 200"])
        let installed = root.url.appendingPathComponent("home/.local/bin/muxify")
        XCTAssertEqual(try CommandRunner().run(CommandInvocation(executable: installed.path, arguments: ["--version"])),
                       "muxify abc1234 200\n")
    }

    func testAFailureIsReportedAndLeavesTheConnectionWorking() throws {
        let root = try TestDirectory()
        let hold = root.url.appendingPathComponent("hold")
        let connection = try connection(in: root.url, hold: hold, refuse: true)
        defer { connection.retire(); connection.cleanup() }
        let base = try publish(in: root.url)
        let reports = Reports(expectation(description: "reported"))

        HostCLI.install(over: connection, environmentName: "Fixture", baseURL: base, report: { reports.add($0) })
        wait(for: [reports.arrived], timeout: 20)
        let line = try XCTUnwrap(reports.all.first)
        XCTAssertTrue(line.hasPrefix("Host CLI: Fixture: failed: "), line)
        XCTAssertTrue(line.contains("Connection refused"), line)
        XCTAssertEqual(try connection.runScript("echo still connected"), "still connected\n")
    }
}
