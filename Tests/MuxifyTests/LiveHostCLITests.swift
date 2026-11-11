import XCTest
import os
@testable import MuxifyCore

/// Opt-in test of the Host CLI on a real Linux or macOS host, gated like `LiveSSHTests`. It serves `build/host-cli/`
/// from this Mac, runs the app's install over the production SSH script lane, then the phone's commands with the
/// installed `muxify`. Its `HOME` and tmux server live in a fresh remote temporary directory, not the user's.
/// `make test-live-linux` runs it on throwaway OrbStack machines.
final class LiveHostCLITests: XCTestCase {
    private static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func testTheAppInstallsTheHostCLIAndThePhonesCommandsRunWithIt() throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["MUXIFY_SSH_TEST_HOST"], let username = env["MUXIFY_SSH_TEST_USER"] else {
            throw XCTSkip("Set MUXIFY_SSH_TEST_HOST and MUXIFY_SSH_TEST_USER to test a real SSH host")
        }
        let assets = Self.repository.appendingPathComponent("build/host-cli")
        let missing = ["version", "muxify-linux-aarch64", "muxify-linux-x86_64", "muxify-darwin-arm64"]
            .filter { !FileManager.default.fileExists(atPath: assets.appendingPathComponent($0).path) }
        guard missing.isEmpty else {
            return XCTFail("build/host-cli lacks \(missing.joined(separator: ", ")): run make host-cli")
        }
        let versionLine = try String(contentsOf: assets.appendingPathComponent("version"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let published = String(versionLine.dropFirst("muxify ".count))

        let environment = RemoteEnvironment(
            name: "Live test", host: host, username: username,
            port: env["MUXIFY_SSH_TEST_PORT"].flatMap(Int.init),
            identityFile: env["MUXIFY_SSH_TEST_IDENTITY"]
        )
        let directory = try TestDirectory()
        defer { withExtendedLifetime(directory) {} }
        let runner = CommandRunner()
        var rawOptions = ["-l", username,
                          "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                          "-o", "PreferredAuthentications=publickey", "-o", "PasswordAuthentication=no",
                          "-o", "KbdInteractiveAuthentication=no", "-o", "ConnectTimeout=10"]
        if let key = environment.identityFile { rawOptions += ["-i", key, "-o", "IdentitiesOnly=yes"] }
        if let port = environment.port { rawOptions += ["-p", String(port)] }
        func raw(_ script: String) throws -> String {
            try runner.run(CommandInvocation(executable: "/usr/bin/ssh", arguments: rawOptions + [
                "--", host, "exec /bin/sh -c " + Tmux.shellQuote(script),
            ]))
        }

        // The machine fetches from this Mac. OrbStack's host.orb.internal reaches the Mac's loopback, so the
        // default serves only there; another host needs the Mac's address and a server on every interface.
        let serveHost = env["MUXIFY_SSH_TEST_SERVE_HOST"] ?? "host.orb.internal"
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        server.arguments = ["python3", "-u", "-m", "http.server", "0", "--directory", assets.path,
                            "--bind", serveHost == "host.orb.internal" ? "127.0.0.1" : "0.0.0.0"]
        let serverOutput = Pipe()
        server.standardOutput = serverOutput
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer {
            kill(server.processIdentifier, SIGTERM)
            server.waitUntilExit()
        }
        var banner = ""
        while !banner.contains("\n") {
            let chunk = serverOutput.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            banner += String(decoding: chunk, as: UTF8.self)
        }
        let port = try XCTUnwrap(banner.range(of: #"port (\d+)"#, options: .regularExpression)
            .map { banner[$0].dropFirst("port ".count) }, "python3 -m http.server did not start: \(banner)")
        let baseURL = "http://\(serveHost):\(port)/"

        // Auth and host verification must already work without prompts. Never approve a new host key.
        let root = "/tmp/muxify-live-" + UUID().uuidString.lowercased()
        let home = root + "/home"
        _ = try raw("mkdir -m 700 " + Tmux.shellQuote(root) + " && mkdir " + Tmux.shellQuote(home))
        let prefix = "export HOME=" + Tmux.shellQuote(home) + " TMUX_TMPDIR=" + Tmux.shellQuote(root)
            + " LC_ALL=C; unset TMUX TMUX_PANE; "
        defer {
            // Only this test's server: its socket must be inside the test's directory.
            _ = try? raw(prefix + "if socket=$(tmux display -p '#{socket_path}' 2>/dev/null); then "
                         + "case $socket in " + Tmux.shellQuote(root) + "/*) tmux kill-server ;; esac; fi; "
                         + "rm -rf " + Tmux.shellQuote(root))
        }

        // The production script lane needs the connection's SSH master; the shim gives every remote script this
        // test's HOME and tmux directory and leaves the lane's options and script text as they are.
        let isolatedCommand = "exec env -u TMUX -u TMUX_PANE HOME=" + Tmux.shellQuote(home)
            + " TMUX_TMPDIR=" + Tmux.shellQuote(root) + " LC_ALL=C "
        let shim = directory.url.appendingPathComponent("ssh")
        try """
        #!/bin/bash
        args=("$@")
        last=$((${#args[@]} - 1))
        if [[ "${args[last]}" == "exec /bin/sh -c "* ]]; then
            args[last]=\(Tmux.shellQuote(isolatedCommand))"${args[last]#exec }"
        fi
        exec /usr/bin/ssh "${args[@]}"

        """.write(to: shim, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
        let connection = try TmuxConnection(environment: environment, sshExecutable: shim.path)
        let remote = try XCTUnwrap(connection.remote)
        let master = Process()
        master.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        master.arguments = rawOptions + ["-o", "ControlPath=" + remote.socketPath, "-M", "-N",
                                         "-o", "ControlPersist=no", "--", host]
        master.standardInput = FileHandle.nullDevice
        master.standardOutput = FileHandle.nullDevice
        master.standardError = FileHandle.nullDevice
        try master.run()
        defer {
            connection.retire()
            kill(master.processIdentifier, SIGTERM)
            master.waitUntilExit()
            connection.cleanup()
        }
        let masterDeadline = Date().addingTimeInterval(15)
        while (try? runner.run(remote.control("check"))) == nil, master.isRunning, Date() < masterDeadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertNoThrow(try runner.run(remote.control("check")), "the SSH master did not start")

        func install() throws -> String {
            let reported = expectation(description: "install reported")
            let line = OSAllocatedUnfairLock<String?>(initialState: nil)
            HostCLI.install(over: connection, environmentName: environment.name, baseURL: baseURL) { report in
                line.withLock { $0 = report }
                reported.fulfill()
            }
            wait(for: [reported], timeout: HostCLI.timeout + 10)
            return try XCTUnwrap(line.withLock { $0 })
        }
        XCTAssertEqual(try install(), "Host CLI: Live test: installed \(published)")
        XCTAssertEqual(try raw(prefix + "\"$HOME/.local/bin/muxify\" --version"), versionLine + "\n")
        XCTAssertEqual(try install(), "Host CLI: Live test: current \(published)")

        // The phone's commands, as it runs them over SSH, against this test's tmux server.
        let work = home + "/work/app"
        _ = try raw(prefix + "mkdir -p \"$HOME/.config/muxify\" " + Tmux.shellQuote(work)
                    + " && printf 'topics:\\n  tags:\\n    backend: {}\\n' > \"$HOME/.config/muxify/config.yaml\""
                    + " && git -C " + Tmux.shellQuote(work) + " init -q"
                    + " && tmux -f /dev/null new-session -d -s main -c \"$HOME\"")
        struct Run { let status: Int32; let output: String }
        func muxify(_ arguments: [String]) throws -> Run {
            let command = prefix + "cd \"$HOME\" && exec \"$HOME/.local/bin/muxify\" "
                + arguments.map(Tmux.shellQuote).joined(separator: " ")
            do {
                return Run(status: 0, output: try raw(command))
            } catch TmuxError.failed(let status, let stderr) {
                return Run(status: status, output: stderr)
            }
        }
        func json(_ arguments: [String], naming topic: String? = nil) throws -> [String: Any] {
            let run = try muxify(arguments)
            XCTAssertEqual(run.status, 0, "muxify \(arguments.joined(separator: " ")): \(run.output)")
            let value = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(run.output.utf8)) as? [String: Any],
                                      "muxify \(arguments.joined(separator: " ")) printed \(run.output)")
            if let topic {
                XCTAssertTrue(names(value, topic), "muxify \(arguments.joined(separator: " ")) does not name \(topic): \(run.output)")
            }
            return value
        }
        _ = try json(["environment", "show", "--json"])
        let created = try json(["topic", "new", "Live Host CLI", "--json"])
        let topic = try XCTUnwrap((created["changed"] as? [String: Any])?["topic_id"] as? String, "\(created)")
        _ = try json(["environment", "show", "--json"], naming: topic)
        _ = try json(["topic", "show", "--json", "--topic", topic], naming: topic)
        _ = try json(["topic", "rename", "Renamed live", "--topic", topic, "--json"], naming: topic)
        _ = try json(["topic", "note", "A live note", "--topic", topic, "--json"], naming: topic)
        _ = try json(["topic", "note", "--clear", "--topic", topic, "--json"], naming: topic)
        _ = try json(["topic", "tag", "set", "backend", "--topic", topic, "--json"], naming: topic)
        _ = try json(["topic", "add-session", work, "--topic", topic, "--json"], naming: topic)
        _ = try json(["topic", "session-paths", "--topic", topic, "--json"], naming: topic)
        _ = try json(["topic", "settle", "--topic", topic, "--json"], naming: topic)
        _ = try json(["topic", "reopen", "--topic", topic, "--json"], naming: topic)
        _ = try json(["topic", "settle", "--topic", topic, "--json"], naming: topic)
        let fresh = try json(["topic", "start-fresh", "--topic", topic, "--json"], naming: topic)
        let window = try XCTUnwrap((fresh["changed"] as? [String: Any])?["window"] as? String, "\(fresh)")

        let url = "http://example.com/live"
        let opened = try muxify(["browser", "open", url, "--window", window])
        XCTAssertEqual(opened.status, 0, opened.output)
        XCTAssertEqual(try raw(prefix + "tmux show-option -wqv -t " + Tmux.shellQuote(window) + " " + Tmux.openOption)
            .trimmingCharacters(in: .whitespacesAndNewlines), url)
        let tabs = try muxify(["browser", "tabs", "--window", window, "--json"])
        XCTAssertEqual(tabs.status, 1, tabs.output)
        print("Live Host CLI passed on \(username)@\(host) (\(try raw("uname -m").trimmingCharacters(in: .whitespacesAndNewlines))): installed and current \(published), and the phone's commands")
    }

    /// Whether `value` holds the string `id` anywhere.
    private func names(_ value: Any, _ id: String) -> Bool {
        switch value {
        case let string as String: return string == id
        case let array as [Any]: return array.contains { names($0, id) }
        case let object as [String: Any]: return object.values.contains { names($0, id) }
        default: return false
        }
    }
}
