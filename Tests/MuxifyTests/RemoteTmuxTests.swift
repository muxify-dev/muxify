import XCTest
@testable import MuxifyCore
import MuxifyTestSupport

/// Executes the real remote shell protocol against an isolated tmux socket.
/// No network, default tmux server, user config or real HOME is touched.
final class RemoteTmuxTests: XCTestCase {
    func testBootstrapClientTargetingLiteralArgumentsAndServerRestart() throws {
        let tmux = try requireTmux()
        let host = try TestRemoteHost()
        defer { withExtendedLifetime(host) {} }
        let root = host.root
        let home = host.home
        let fm = FileManager.default
        let ssh = try RemoteSSH(environment: RemoteEnvironment(name: "test", host: "unused", username: "unused"),
                                temporaryDirectory: root.url)
        func remote(_ args: [String]) throws -> String {
            try host.run(CommandInvocation(executable: "/bin/sh", arguments: ["-c", ssh.command(args).arguments.last!]))
        }
        let terminal = Process()
        terminal.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        terminal.arguments = ["-q", "/dev/null", "/bin/sh", "-c", ssh.bootstrap(newSession: .init(name: "main", folder: home.path))]
        terminal.environment = host.environment
        let log = root.url.appendingPathComponent("terminal.log")
        fm.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        let terminalInput = Pipe()
        terminal.standardInput = terminalInput
        terminal.standardOutput = output
        terminal.standardError = output
        try terminal.run()
        defer { host.stop(terminal) }

        var marker: [String] = []
        var snapshot: TmuxSnapshot?
        // The assert below reports a timeout, with the Terminal's output.
        eventually("", fail: { _, _, _ in }) {
            marker = ((try? remote(["show-option", "-sqv", ssh.markerOption])) ?? "")
                .trimmingCharacters(in: .newlines).components(separatedBy: Tmux.separator)
            snapshot = try? Tmux.readSnapshot(using: remote)
            guard marker.count == 5, let pid = Int(marker[0]) else { return false }
            return snapshot?.clients.contains(where: { $0.pid == pid && $0.tty == marker[1] && !$0.isControl }) == true
        }
        XCTAssertEqual(marker.count, 5, (try? String(contentsOf: log, encoding: .utf8)) ?? "No terminal output")
        guard marker.count == 5 else { return }
        let initial = try XCTUnwrap(snapshot)
        let own = try XCTUnwrap(initial.clients.first { $0.pid == Int(marker[0]) && $0.tty == marker[1] })
        let features = try remote(["list-clients", "-F", "#{client_tty} #{client_termfeatures}"])
        let ownFeatures = try XCTUnwrap(features.split(separator: "\n").first { $0.hasPrefix(own.tty + " ") })
        XCTAssertTrue(ownFeatures.split(separator: " ").last?.split(separator: ",").contains("RGB") == true)
        XCTAssertEqual(marker[2], home.path)
        XCTAssertEqual(marker[4], "remote")
        XCTAssertEqual(initial.windows.first?.sessionName, "main")
        let paneDirectory = try XCTUnwrap(initial.windows.first?.path)
        XCTAssertEqual(URL(fileURLWithPath: paneDirectory).resolvingSymlinksInPath().path, home.resolvingSymlinksInPath().path)

        let otherSession = try host.raw(["new-session", "-d", "-s", "other", "-P", "-F", "#{session_id}", "-c", home.path])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let other = Process()
        other.executableURL = URL(fileURLWithPath: tmux)
        other.arguments = ["-S", host.socket, "-u", "-C", "attach-session", "-f", "read-only,no-output,ignore-size", "-t", otherSession]
        other.environment = host.environment
        let otherInput = Pipe()
        other.standardInput = otherInput
        other.standardOutput = FileHandle.nullDevice
        other.standardError = FileHandle.nullDevice
        try other.run()
        defer { host.stop(other) }
        eventually("the other control Client did not attach") {
            (try? Tmux.readSnapshot(using: remote).clients.contains { $0.pid == Int(other.processIdentifier) }) == true
        }

        let name = "quotes ' ; $(echo wrong) 😃"
        let window = try remote(["new-window", "-d", "-P", "-F", "#{window_id}", "-t", "\(own.sessionID):", "-n", name])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try remote(["switch-client", "-c", own.tty, "-t", "\(own.sessionID):\(window)"])
        let updated = try Tmux.readSnapshot(using: remote)
        XCTAssertEqual(updated.windows.first { $0.id == window }?.name, name)
        XCTAssertEqual(updated.clients.first { $0.pid == own.pid }?.windowID, window)
        XCTAssertEqual(updated.clients.first { $0.pid == Int(other.processIdentifier) }?.sessionID, otherSession)
        XCTAssertTrue(updated.clients.first { $0.pid == Int(other.processIdentifier) }?.isControl == true)
        XCTAssertEqual(try remote(["display-message", "-p", "-t", window, "#{window_id}"])
            .trimmingCharacters(in: .whitespacesAndNewlines), window)

        host.stop(terminal)
        XCTAssertNoThrow(try host.raw(["has-session", "-t", "=main"]))
        XCTAssertThrowsError(try remote(["switch-client", "-c", own.tty, "-t", otherSession]))
        XCTAssertEqual(try Tmux.readSnapshot(using: host.raw).clients.first { $0.pid == Int(other.processIdentifier) }?.sessionID, otherSession)

        _ = try host.raw(["kill-server"])
        _ = try host.raw(["new-session", "-d", "-s", "replacement", "-c", home.path])
        XCTAssertThrowsError(try remote(["rename-window", "-t", "@0", "wrong-server"]))
        XCTAssertNotEqual(try host.raw(["display-message", "-p", "-t", "@0", "#{window_name}"])
            .trimmingCharacters(in: .whitespacesAndNewlines), "wrong-server")
        withExtendedLifetime((terminalInput, otherInput)) {}
    }

    func testMissingMasterCannotFallBackToAnIndependentSshConnection() throws {
        let root = try TestDirectory()
        defer { withExtendedLifetime(root) {} }
        let ssh = try RemoteSSH(environment: RemoteEnvironment(name: "missing", host: "127.0.0.1", username: "unused"),
                                temporaryDirectory: root.url)
        // ProxyCommand=false exits locally before any SSH handshake/authentication.
        XCTAssertThrowsError(try CommandRunner().run(ssh.command(["list-sessions"]), timeout: 3)) {
            guard case .failed(let status, _) = $0 as? TmuxError else { return XCTFail("Expected fail-closed SSH, got \($0)") }
            XCTAssertEqual(status, 255)
        }
    }

    func testClosingSessionsReportsSurvivorsAndOnlyStartASessionCreatesOne() throws {
        let host = try TestRemoteHost()
        defer { withExtendedLifetime(host) {} }
        let root = host.root
        let home = host.home
        let fm = FileManager.default
        // Execute the production SSH remote command on this isolated socket,
        // including PTY merging and the production local output/snapshot logger.
        let fakeSSH = host.bin.appendingPathComponent("ssh")
        try "#!/bin/sh\nfor arg do command=$arg; done\nexec /usr/bin/script -q /dev/null /bin/sh -c \"$command\" 2>&1 3>&- 4>&-\n"
            .write(to: fakeSSH, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeSSH.path)
        var terminals: [Process] = []
        var inputs: [Pipe] = []
        var outputs: [FileHandle] = []
        var logs: [Int32: URL] = [:]
        defer {
            terminals.forEach(host.stop)
            outputs.forEach { try? $0.close() }
            withExtendedLifetime(inputs) {}
        }
        func connect(target: String? = nil, picksLatestSession: Bool = true,
                     newSession: RemoteSSH.NewSession? = nil) throws -> (RemoteSSH, Process) {
            let ssh = try RemoteSSH(environment: RemoteEnvironment(name: "test", host: "unused", username: "unused"),
                                    temporaryDirectory: root.url, sshExecutable: fakeSSH.path)
            let terminal = Process()
            terminal.executableURL = URL(fileURLWithPath: "/usr/bin/script")
            terminal.arguments = ["-q", "/dev/null", "/bin/sh", "-c", ssh.terminalCommand(target: target, picksLatestSession: picksLatestSession,
                                                                                                      newSession: newSession)]
            terminal.environment = host.environment
            let input = Pipe()
            terminal.standardInput = input
            let log = root.url.appendingPathComponent(UUID().uuidString + ".log")
            fm.createFile(atPath: log.path, contents: nil)
            let output = try FileHandle(forWritingTo: log)
            terminal.standardOutput = output
            terminal.standardError = output
            try terminal.run()
            logs[terminal.processIdentifier] = log
            terminals.append(terminal)
            inputs.append(input)
            outputs.append(output)
            return (ssh, terminal)
        }
        func ready(_ ssh: RemoteSSH) throws -> TmuxSnapshot {
            var ready: TmuxSnapshot?
            eventually("the connection's Terminal Client did not attach") {
                guard let snapshot = try? Tmux.readSnapshot(using: host.raw),
                      let marker = try? host.raw(["show-option", "-sqv", ssh.markerOption]),
                      let pid = Int(marker.components(separatedBy: Tmux.separator)[0]),
                      snapshot.clients.contains(where: { $0.pid == pid }) else { return false }
                ready = snapshot
                return true
            }
            guard let ready else { throw TmuxError.notReady }
            return ready
        }
        func exited(_ terminal: Process, owner: RemoteSSH) throws {
            // The assert below reports a timeout, with the Terminal's output.
            eventually("", fail: { _, _, _ in }) { !terminal.isRunning }
            let log = logs[terminal.processIdentifier].flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "No terminal output"
            XCTAssertFalse(terminal.isRunning, "SSH status: \(String(describing: owner.exitStatus)); output: \(log.suffix(2000))")
            if terminal.isRunning { throw TmuxError.timedOut }
            terminal.waitUntilExit()
        }

        let (empty, emptyTerminal) = try connect()
        try exited(emptyTerminal, owner: empty)
        XCTAssertEqual(empty.closedSnapshot?.windows.count, 0)
        XCTAssertThrowsError(try host.raw(["has-session"]), "The first connection must not create main")

        let project = home.appendingPathComponent("project")
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        let (first, firstTerminal) = try connect(newSession: RemoteSSH.NewSession(name: "project", folder: project.path))
        let started = try XCTUnwrap(try ready(first).windows.first)
        XCTAssertEqual(started.sessionName, "project")
        XCTAssertEqual(URL(fileURLWithPath: started.path).resolvingSymlinksInPath(), project.resolvingSymlinksInPath())
        let otherTarget = try host.raw(["new-session", "-d", "-s", "other", "-P", "-F", "#{session_id}:#{window_id}", "-c", home.path])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try host.raw(["detach-client", "-t", try XCTUnwrap(try ready(first).clients.first { !$0.isControl }?.tty)])
        try exited(firstTerminal, owner: first)
        XCTAssertEqual(try host.raw(["show-option", "-sqv", first.markerOption]).trimmingCharacters(in: .newlines), "")
        XCTAssertEqual(first.closedSnapshot?.windows.count, 2, "Intentional detach preserves both Sessions")

        let (again, againTerminal) = try connect(newSession: RemoteSSH.NewSession(name: "project", folder: home.path))
        XCTAssertEqual(try ready(again).clients.first { !$0.isControl }?.sessionID, started.sessionID, "A Session of that name is gone to")
        XCTAssertEqual(try host.raw(["list-sessions", "-F", "#{session_name}"]).split(separator: "\n").sorted(), ["other", "project"])
        _ = try host.raw(["detach-client", "-t", try XCTUnwrap(try ready(again).clients.first { !$0.isControl }?.tty)])
        try exited(againTerminal, owner: again)

        let (second, secondTerminal) = try connect(target: otherTarget, picksLatestSession: false)
        _ = try ready(second)
        // A UTF-8 name holds bytes that Ghostty reads as C1 controls; the report must not break out of its DCS.
        _ = try host.raw(["rename-window", "-t", started.id, "✳ agent"])
        // The listener stays attached to a Session, so it ends itself once the bootstrap clears the marker.
        // Over real SSH the master, and so the Terminal, waits for it.
        let listener = Process()
        let listenerCommand = second.command(["-C", "attach-session", "-f", "no-output,ignore-size"])
        listener.executableURL = URL(fileURLWithPath: listenerCommand.executable)
        listener.arguments = listenerCommand.arguments
        listener.environment = host.environment
        let listenerInput = Pipe()
        listener.standardInput = listenerInput
        listener.standardOutput = FileHandle.nullDevice
        listener.standardError = FileHandle.nullDevice
        try listener.run()
        defer { host.stop(listener); withExtendedLifetime(listenerInput) {} }
        eventually("The listener attached") { (try? ready(second))?.clients.contains(where: \.isControl) ?? false }
        _ = try host.raw(["kill-pane", "-t", otherTarget])
        try exited(secondTerminal, owner: second)
        eventually("The listener ends itself when its Terminal Client ends") { !listener.isRunning }
        let survivors = try XCTUnwrap(second.closedSnapshot)
        XCTAssertEqual(survivors.windows.map(\.sessionName), ["project"])
        XCTAssertEqual(survivors.windows.map(\.name), ["✳ agent"])
        let terminalOutput = try Data(contentsOf: try XCTUnwrap(logs[secondTerminal.processIdentifier]))
        let reportStart = try XCTUnwrap(terminalOutput.range(of: Data("\u{1B}Pmuxify;".utf8)))
        let reportBytes = terminalOutput[reportStart.upperBound...]
        XCTAssertFalse(reportBytes.contains { (0x80...0x9F).contains($0) }, "No C1 byte inside the report's DCS")
        XCTAssertTrue(survivors.windows.allSatisfy(\.isRemote))
        XCTAssertEqual(survivors.windows.first?.homeDirectory, home.path)
        XCTAssertFalse(try String(contentsOf: second.directory.appendingPathComponent("snapshot"), encoding: .utf8).contains("[exited]"))

        let (last, lastTerminal) = try connect(target: "\(started.sessionID):\(started.id)", picksLatestSession: false)
        _ = try ready(last)
        _ = try host.raw(["kill-pane", "-t", started.id])
        try exited(lastTerminal, owner: last)
        XCTAssertEqual(last.closedSnapshot?.windows.count, 0)
        XCTAssertFalse(last.closedSnapshot?.serverRunning ?? true)
        XCTAssertThrowsError(try host.raw(["has-session"]))

        let (recovery, recoveryTerminal) = try connect(picksLatestSession: false)
        try exited(recoveryTerminal, owner: recovery)
        XCTAssertEqual(recovery.closedSnapshot?.windows.count, 0)
        XCTAssertThrowsError(try host.raw(["has-session"]), "Automatic recovery must not recreate main")

        let (reconnect, reconnectTerminal) = try connect()
        try exited(reconnectTerminal, owner: reconnect)
        XCTAssertThrowsError(try host.raw(["has-session"]), "An explicit reconnect must not create main")

        let (restarted, _) = try connect(newSession: RemoteSSH.NewSession(name: "home", folder: home.path))
        let restored = try ready(restarted)
        XCTAssertEqual(restored.windows.map(\.sessionName), ["home"])
        XCTAssertEqual(URL(fileURLWithPath: try XCTUnwrap(restored.windows.first?.path)).resolvingSymlinksInPath(), home.resolvingSymlinksInPath())
    }
}
