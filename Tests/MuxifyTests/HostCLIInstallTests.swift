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

    // MARK: - Chain B, chain D and the Debug app's own build

    /// A Linux x86_64 Host whose curl fails on every URL, as one without internet does, run here in a temporary
    /// HOME. The fixture keeps a copy of what each upload sends at `upload.gz`.
    private func offlineHost(in root: URL, environment: [String: String] = [:]) throws -> TmuxConnection {
        let tools = root.appendingPathComponent("tools")
        try executable("#!/bin/sh\nexit 6\n", at: tools.appendingPathComponent("curl"))
        try executable("""
        #!/bin/sh
        case $1 in -s) echo Linux ;; -m) echo x86_64 ;; *) exec /usr/bin/uname "$@" ;; esac

        """, at: tools.appendingPathComponent("uname"))
        let exports = environment.sorted { $0.key < $1.key }.map { "export \($0.key)=\(Tmux.shellQuote($0.value))" }
        let ssh = root.appendingPathComponent("ssh")
        try executable("""
        #!/bin/bash
        unset TMUX TMUX_PANE
        export HOME=\(Tmux.shellQuote(root.appendingPathComponent("home").path))
        export PATH=\(Tmux.shellQuote(tools.path + ":/usr/bin:/bin"))
        \(exports.joined(separator: "\n"))
        for arg do command=$arg; done
        if [[ "$command" == *"gzip -dc"* ]]; then
            /usr/bin/tee \(Tmux.shellQuote(root.appendingPathComponent("upload.gz").path)) | /bin/sh -c "$command"
            exit "${PIPESTATUS[1]}"
        fi
        exec /bin/sh -c "$command"

        """, at: ssh)
        return try TmuxConnection(environment: RemoteEnvironment(name: "Fixture", host: "unused", username: "unused"),
                                  sshExecutable: ssh.path)
    }

    /// `cli-latest` with a Linux x86_64 asset at the returned `file://` base URL. The asset prints `version` and
    /// otherwise runs `body`, by default naming the path it runs from.
    @discardableResult
    private func publishLinux(in root: URL, version: String = "muxify abc1234 200",
                              body: String = "echo \"server from $0\"") throws -> String {
        let assets = root.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try "\(version)\n".write(to: assets.appendingPathComponent("version"), atomically: true, encoding: .utf8)
        try executable(asset(version: version, body: body), at: assets.appendingPathComponent("muxify-linux-x86_64"))
        return "file://" + assets.path + "/"
    }

    private func asset(version: String, body: String) -> String {
        "#!/bin/sh\nif [ \"$1\" = --version ]; then echo \(Tmux.shellQuote(version)); exit 0; fi\n\(body)\n"
    }

    private func output(_ invocation: CommandInvocation) throws -> String {
        try CommandRunner().run(invocation, timeout: 20)
    }

    func testAHostThatCannotDownloadGetsTheBinaryFromTheMacAndTheServerStartsFromIt() throws {
        let root = try TestDirectory()
        let connection = try offlineHost(in: root.url)
        defer { connection.retire(); connection.cleanup() }
        let base = try publishLinux(in: root.url)
        var reports: [String] = []

        let ready = HostCLIChain.run(over: connection, environmentName: "Fixture", baseURL: base, debug: nil,
                                     report: { reports.append($0) })

        let installed = root.url.appendingPathComponent("home/.local/bin/muxify")
        XCTAssertEqual(ready, HostCLIReady(line: "uploaded abc1234 200 to \(installed.path)"))
        XCTAssertEqual(reports, ["Host CLI: Fixture: failed: cannot fetch \(base)version",
                                 "Host CLI: Fixture: from the Mac: uploaded abc1234 200 to \(installed.path)"])
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installed.path))
        XCTAssertEqual(try Data(contentsOf: installed),
                       try Data(contentsOf: root.url.appendingPathComponent("assets/muxify-linux-x86_64")))
        let sent = try Data(contentsOf: root.url.appendingPathComponent("upload.gz"))
        XCTAssertEqual(Array(sent.prefix(2)), [0x1f, 0x8b], "the bytes cross the master gzipped")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: installed.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, ["muxify"], "the temp file was moved into place")
        XCTAssertEqual(try output(XCTUnwrap(connection.remote).serverInvocation()), "server from \(installed.path)\n")
    }

    func testAHostWithAnUpToDateMuxifyGetsNothingFromTheMac() throws {
        let root = try TestDirectory()
        let connection = try offlineHost(in: root.url)
        defer { connection.retire(); connection.cleanup() }
        let base = try publishLinux(in: root.url)
        try executable(asset(version: "muxify abc1234 200", body: "exit 1"), at: root.url.appendingPathComponent("tools/muxify"))

        let ready = HostCLIChain.run(over: connection, environmentName: "Fixture", baseURL: base, debug: nil, report: { _ in })
        XCTAssertEqual(ready, HostCLIReady(line: "current abc1234 200"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.url.appendingPathComponent("upload.gz").path))
    }

    @MainActor
    func testWhenTheMacCannotFetchEitherTheWindowShowsSessionsOnlyWithTheChainsLine() async throws {
        let root = try TestDirectory()
        let connection = try offlineHost(in: root.url)
        defer { connection.retire(); connection.cleanup() }
        let base = "file://" + root.url.appendingPathComponent("unpublished").path + "/"
        let link = HostEnvironmentLink(
            environmentName: "Fixture", inner: FakeEnvironmentLink(isOnThisMac: false, features: [.git]),
            nonce: { nil }, helloTimeout: 10,
            openChannel: { path in try HostServerChannel.process(XCTUnwrap(connection.remote).serverInvocation(executable: path)) },
            install: { done in
                DispatchQueue.global().async {
                    done(HostCLIChain.run(over: connection, environmentName: "Fixture", baseURL: base, debug: nil, report: { _ in }))
                }
            },
            masterAlive: { true }, hostCLIVersion: { _ in nil })
        var unavailable: HostServerUnavailable?
        let subscription = link.subscribe { if case .serverUnavailable(let reason) = $0 { unavailable = reason } }
        defer { subscription.cancel() }
        try link.connect()

        link.installHostCLI(environmentName: "Fixture")
        let deadline = Date().addingTimeInterval(20)
        while unavailable == nil, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }

        let line = "failed: cannot fetch \(base)version; from the Mac: failed: cannot fetch \(base)version"
        XCTAssertEqual(unavailable, .notInstalled(line))
        XCTAssertEqual(unavailable?.reason, "the Host CLI could not be installed (\(line))")
    }

    func testADebugAppUploadsItsMatchingBuildToItsOwnFolderAndKeepsTheThreeNewest() throws {
        let root = try TestDirectory()
        let connection = try offlineHost(in: root.url)
        defer { connection.retire(); connection.cleanup() }
        let base = try publishLinux(in: root.url)
        let build = root.url.appendingPathComponent("checkout/build/host-cli")
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        try "muxify abc1234 200\n".write(to: build.appendingPathComponent("version"), atomically: true, encoding: .utf8)
        try executable(asset(version: "muxify abc1234 200", body: "echo \"debug server from $0\""),
                       at: build.appendingPathComponent("muxify-linux-x86_64"))
        let debug = try XCTUnwrap(DebugHostCLI.matching(sourceRoot: root.url.appendingPathComponent("checkout").path,
                                                        build: "muxify abc1234 200"))
        let folder = root.url.appendingPathComponent("home/.local/share/muxify/server")
        for (index, name) in ["muxify-0000001", "muxify-0000002", "muxify-0000003", "muxify-0000004"].enumerated() {
            try executable("#!/bin/sh\n", at: folder.appendingPathComponent(name))
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(Double(index - 10) * 60)],
                                                  ofItemAtPath: folder.appendingPathComponent(name).path)
        }

        let ready = HostCLIChain.run(over: connection, environmentName: "Fixture", baseURL: base, debug: debug, report: { _ in })

        let uploaded = folder.appendingPathComponent("muxify-abc1234")
        XCTAssertEqual(ready, HostCLIReady(line: "the Debug build abc1234", server: uploaded.path))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)),
                       ["muxify-abc1234", "muxify-0000004", "muxify-0000003"], "all but the three newest go")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: uploaded.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.url.appendingPathComponent("home/.local/bin").path),
                       "the Debug path never writes the Host CLI")
        XCTAssertEqual(try output(XCTUnwrap(connection.remote).serverInvocation(executable: uploaded.path)),
                       "debug server from \(uploaded.path)\n")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: build.path).sorted(),
                       ["muxify-linux-x86_64", "version"], "the checkout's build folder is left as it was")
    }

    func testWithoutAMatchingBuildADebugAppUsesTheInstallChain() throws {
        let root = try TestDirectory()
        let checkout = root.url.appendingPathComponent("checkout")
        let build = checkout.appendingPathComponent("build/host-cli")
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        try "muxify fff0000 100\n".write(to: build.appendingPathComponent("version"), atomically: true, encoding: .utf8)

        XCTAssertNil(DebugHostCLI.matching(sourceRoot: checkout.path, build: "muxify abc1234 200"), "another sha")
        XCTAssertNil(DebugHostCLI.matching(sourceRoot: root.url.path, build: "muxify fff0000 100"), "no build/host-cli")
        XCTAssertNil(DebugHostCLI.matching(sourceRoot: nil, build: "muxify fff0000 100"), "a build with no source root")
        XCTAssertNil(DebugHostCLI.matching(sourceRoot: checkout.path, build: "muxify dev 0"), "an unstamped app")
        XCTAssertEqual(DebugHostCLI.matching(sourceRoot: checkout.path, build: "muxify fff0000 100")?.sha, "fff0000")

        // A matching build with no binary for the Host's platform falls back as well.
        let connection = try offlineHost(in: root.url)
        defer { connection.retire(); connection.cleanup() }
        let base = try publishLinux(in: root.url)
        let ready = HostCLIChain.run(over: connection, environmentName: "Fixture", baseURL: base,
                                     debug: DebugHostCLI(folder: build, sha: "fff0000"), report: { _ in })
        let installed = root.url.appendingPathComponent("home/.local/bin/muxify")
        XCTAssertEqual(ready, HostCLIReady(line: "uploaded abc1234 200 to \(installed.path)"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.url.appendingPathComponent("home/.local/share/muxify/server").path))
    }

    func testADebugAppsInfoPlistCarriesItsSourceRoot() throws {
        let app = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("Muxify.app")
        let bundle = try XCTUnwrap(Bundle(url: app), "no Muxify.app beside the tests at \(app.path)")
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = try XCTUnwrap(AppBuild.sourceRoot(in: bundle), "a Debug build carries MuxifySourceRoot")
        XCTAssertEqual(URL(fileURLWithPath: root).resolvingSymlinksInPath().path, repository.resolvingSymlinksInPath().path)
    }

    /// The Host Server runs from `~/.local/bin/muxify`, which wraps this build's own CLI, against a throwaway tmux
    /// server. An update then replaces that file while the server runs.
    @MainActor
    func testALiveHostServerKeepsServingWhenTheHostsMuxifyIsReplaced() async throws {
        let tmuxBinary = try requireTmux()
        let cli = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("Muxify.app/Contents/Resources/bin/muxify")
        guard FileManager.default.isExecutableFile(atPath: cli.path) else { return XCTFail("no muxify at \(cli.path)") }
        let root = try TestDirectory()
        // A short run directory: tmux's socket path must fit in 104 bytes.
        let run = URL(fileURLWithPath: "/tmp/mxi-" + UUID().uuidString.prefix(8), isDirectory: true)
        let socketFolder = run.appendingPathComponent("tmux-\(getuid())")
        try FileManager.default.createDirectory(at: socketFolder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let socket = socketFolder.appendingPathComponent("default").path
        let tmux = TmuxServer(socketPath: socket, configPath: "/dev/null")
        defer {
            if let actual = try? tmux.run(["display-message", "-p", "#{socket_path}"]),
               actual.trimmingCharacters(in: .whitespacesAndNewlines) == socket {
                _ = try? tmux.run(["kill-server"])
            }
            try? FileManager.default.removeItem(at: run)
        }
        try tmux.run(["new-session", "-d", "-s", "work", "-x", "120", "-y", "40", "-c", root.url.path])

        // The Host's tmux is this one, its state lives in its HOME, and its tmux server is the throwaway one.
        try FileManager.default.createDirectory(at: root.url.appendingPathComponent("tools"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root.url.appendingPathComponent("tools/tmux").path,
                                                   withDestinationPath: tmuxBinary)
        let home = root.url.appendingPathComponent("home").path
        let connection = try offlineHost(in: root.url, environment: [
            "TMUX_TMPDIR": run.path, "XDG_STATE_HOME": home + "/.local/state", "XDG_CONFIG_HOME": home + "/.config",
            "XDG_CACHE_HOME": home + "/.cache", "MUXIFY_CONFIG": home + "/.config/muxify/config.yaml",
        ])
        defer { connection.retire(); connection.cleanup() }
        let serve = "exec \(Tmux.shellQuote(cli.path)) \"$@\""
        let base = try publishLinux(in: root.url, body: serve)
        var channels = 0
        var installs = 0
        let link = HostEnvironmentLink(
            environmentName: "Fixture", inner: FakeEnvironmentLink(isOnThisMac: false, features: [.git]),
            nonce: { nil }, helloTimeout: 10, pingInterval: 0.3,
            openChannel: { path in
                channels += 1
                return try HostServerChannel.process(XCTUnwrap(connection.remote).serverInvocation(executable: path))
            },
            install: { done in
                DispatchQueue.global().async {
                    done(HostCLIChain.run(over: connection, environmentName: "Fixture", baseURL: base, debug: nil, report: { _ in }))
                    // After the link's own hop to the main queue, so the link has acted on the result.
                    DispatchQueue.main.async { installs += 1 }
                }
            },
            masterAlive: { true }, hostCLIVersion: { _ in nil })
        var changes = 0
        let subscription = link.subscribe { if case .changed = $0 { changes += 1 } }
        defer { subscription.cancel(); _ = link.sessionsOnlyLink() }
        try link.connect()

        link.installHostCLI(environmentName: "Fixture")
        try await waitUntil("the Host Server from ~/.local/bin/muxify did not serve") { link.features.contains(.topics) }
        let installed = root.url.appendingPathComponent("home/.local/bin/muxify")
        let firstInode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: installed.path)[.systemFileNumber] as? Int)

        // cli-latest moves on, and the next install replaces the file under the running server.
        try publishLinux(in: root.url, version: "muxify def5678 300", body: serve)
        link.installHostCLI(environmentName: "Fixture")
        try await waitUntil("the second install did not finish") { installs == 2 }
        XCTAssertEqual(try output(CommandInvocation(executable: installed.path, arguments: ["--version"])), "muxify def5678 300\n")
        XCTAssertNotEqual(try FileManager.default.attributesOfItem(atPath: installed.path)[.systemFileNumber] as? Int, firstInode,
                          "the install's mv gave the file a new inode")

        let before = changes
        try tmux.run(["new-session", "-d", "-s", "later", "-c", root.url.path])
        try await waitUntil("the running server stopped publishing after the update") { changes > before }
        XCTAssertTrue(link.features.contains(.topics))
        XCTAssertEqual(channels, 1, "the Mac never restarts a live server because a newer binary appeared")
    }

    private func waitUntil(_ message: String, seconds: TimeInterval = 20, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else { return XCTFail(message) }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
