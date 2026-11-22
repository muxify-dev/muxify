import Foundation
import XCTest
@testable import MuxifyCore

/// Probe Panes on a throwaway tmux server that ask for the background as programs do, and another screen that writes
/// its own Colour Reports, for the tests of the Colour Reports (ADR 0098): the publisher's and the Host Server's.
struct ColourProbes {
    let directory: URL
    let server: TmuxServer
    var socket: String { server.socketPath }

    static let light = TerminalColours(background: TerminalColour(red: 0xfb, green: 0xf1, blue: 0xc7),
                                       foreground: TerminalColour(red: 0x3c, green: 0x38, blue: 0x36))
    static let dark = TerminalColours(background: TerminalColour(red: 0x10, green: 0x10, blue: 0x10),
                                      foreground: TerminalColour(red: 0xee, green: 0xee, blue: 0xee))

    /// A Session whose Pane runs a program that waits for the file `go`, then asks for the background (OSC 11) as
    /// Claude Code does, and writes the answer's colour, or `none` after a second without one, to the returned file.
    /// A second answer file is for one more probe Pane.
    func probe(session: String) throws -> (String, String) {
        let python = "/usr/bin/python3"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: python), "no python3 for the probe")
        let script = directory.appendingPathComponent("probe.py").path
        try """
            import os, re, select, sys, termios, tty, time
            answer, go = sys.argv[1], sys.argv[2]
            tty.setraw(0)
            while not os.path.exists(go): time.sleep(0.02)
            os.write(1, b'\\x1b]11;?\\x1b\\\\')
            reply, end = b'', time.time() + 1
            while time.time() < end and not reply.endswith(b'\\x1b\\\\'):
                if select.select([0], [], [], 0.05)[0]: reply += os.read(0, 256)
            found = re.search(rb'rgb:[0-9a-f/]+', reply)
            open(answer + '.part', 'w').write(found.group().decode() if found else 'none')
            os.rename(answer + '.part', answer)
            time.sleep(30)
            """.write(toFile: script, atomically: true, encoding: .utf8)
        let first = directory.appendingPathComponent(session + "-1").path
        let second = directory.appendingPathComponent(session + "-2").path
        try server.run(["new-session", "-d", "-s", session, "-x", "80", "-y", "24", probeCommand(first)])
        return (first, second)
    }

    /// A Session of `panes` probe Panes, each in a Window of its own, and their answer files.
    func probes(session: String, panes: Int) throws -> [String] {
        let first = try probe(session: session).0
        return try [first] + (2...panes).map { index in
            let answer = directory.appendingPathComponent("\(session)-\(index)").path
            try server.run(["new-window", "-d", "-t", session + ":", probeCommand(answer)])
            return answer
        }
    }

    /// A probe Pane's command, which asks once the file `go` is there.
    func probeCommand(_ answer: String, go: String = "go") -> String {
        "/usr/bin/python3 \(directory.appendingPathComponent("probe.py").path) \(answer) \(directory.appendingPathComponent(go).path)"
    }

    /// Lets every probe that waits for `name` ask.
    func go(_ name: String = "go") throws {
        try "".write(toFile: directory.appendingPathComponent(name).path, atomically: true, encoding: .utf8)
    }

    /// A Session whose Pane runs a program that turns on mode 2031, as Claude Code does, and logs each colour-scheme
    /// notice to the returned file: `ready` once mode 2031 is on, then `dark`, or `light` and the background (OSC 11)
    /// it asked for at once.
    func themeProbe(session: String) throws -> String {
        let python = "/usr/bin/python3"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: python), "no python3 for the probe")
        let script = directory.appendingPathComponent("theme.py").path
        try """
            import os, re, select, sys, tty, time
            log = sys.argv[1]
            tty.setraw(0)
            os.write(1, b'\\x1b[?2031h')
            pending = b''
            def note(text):
                with open(log, 'a') as f: f.write(text + '\\n')
            note('ready')
            while True:
                if select.select([0], [], [], 0.05)[0]: pending += os.read(0, 256)
                notice = re.search(rb'\\x1b\\[\\?997;([12])n', pending)
                if not notice: continue
                pending = pending[notice.end():]
                if notice.group(1) == b'1':
                    note('dark')
                    continue
                os.write(1, b'\\x1b]11;?\\x1b\\\\')
                end = time.time() + 1
                while time.time() < end and not re.search(rb'rgb:[0-9a-f/]+', pending):
                    if select.select([0], [], [], 0.05)[0]: pending += os.read(0, 256)
                found = re.search(rb'rgb:[0-9a-f/]+', pending)
                note('light ' + (found.group().decode() if found else 'none'))
                pending = pending[found.end():] if found else b''
            """.write(toFile: script, atomically: true, encoding: .utf8)
        let log = directory.appendingPathComponent(session + "-notices").path
        try server.run(["new-session", "-d", "-s", session, "-x", "80", "-y", "24", "\(python) \(script) \(log)"])
        return log
    }

    func lines(_ path: String) -> [String] {
        ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    /// The Sessions of the control Clients; none when no server runs.
    func controlClients() -> [String] {
        ((try? server.run(["list-clients", "-f", "#{client_control_mode}", "-F", "#{session_name}"])) ?? "")
            .split(separator: "\n").map(String.init)
    }

    /// The Terminal's Client, whose input is `client`'s, tells tmux the colour scheme of its terminal, as Ghostty does
    /// when asked: `1` dark, `2` light.
    static func terminalSays(_ scheme: Int, through client: Process?) throws {
        let input = try XCTUnwrap(client?.standardInput as? Pipe)
        input.fileHandleForWriting.write(Data("\u{1b}[?997;\(scheme)n".utf8))
    }

    /// Another screen, as Muxify Mobile is: a control Client in `session`, attached with `flags`, writes `dark` to every
    /// Pane of the Session and detaches once `afterAttach` returns, which lets the publisher read it.
    func screenWritesAndDetaches(in session: String, flags: String?, afterAttach: () async -> Void) async throws {
        let binary = try XCTUnwrap(server.binary)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["-S", socket, "-f", "/dev/null", "-C", "attach-session", "-t", session] + (flags.map { ["-f", $0] } ?? [])
        var environment = ProcessInfo.processInfo.environment
        environment["TMUX"] = nil
        environment["TMUX_PANE"] = nil
        process.environment = environment
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let before = controlClients().count
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        try await Self.wait("the screen did not attach") { controlClients().count == before + 1 }
        await afterAttach()
        let panes = try server.run(["list-panes", "-s", "-t", "=" + session, "-F", "#{pane_id}"])
            .split(separator: "\n").map(String.init)
        let lines = ColourReport.commands(panes: panes, colours: Self.dark).map { $0 + "\n" }.joined()
        input.fileHandleForWriting.write(Data(lines.utf8))
        try input.fileHandleForWriting.close()
        try await Self.wait("the screen did not detach") { controlClients().count == before }
        try await Task.sleep(nanoseconds: 500_000_000)
    }

    static func wait(_ message: String, seconds: TimeInterval = 10, until done: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while try await !done() {
            guard Date() < deadline else { return XCTFail(message) }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
