import Darwin
import Foundation
import MuxifyCore
import MuxifyTestSupport

/// A remote host for a test of the remote shell protocol: a HOME, a `bin` whose `tmux` runs a tmux server of the test's
/// own, and an environment that reaches neither the user's server, HOME nor tmux config. Its deinit kills the server.
final class TestRemoteHost {
    let root: TestDirectory
    let home: URL
    let bin: URL
    /// The `tmux` in `bin`.
    let shim: URL
    let socket: String
    let environment: [String: String]
    private let runner = CommandRunner()

    init() throws {
        let tmux = try requireTmux()
        root = try TestDirectory()
        home = root.url.appendingPathComponent("home")
        bin = root.url.appendingPathComponent("bin")
        shim = bin.appendingPathComponent("tmux")
        socket = root.url.appendingPathComponent("t").path
        let fm = FileManager.default
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        // A real remote process cannot inherit the local logger's pipe FDs.
        // macOS script keeps extra descriptors when nesting PTYs; close them
        // before tmux starts a daemon that could otherwise retain our pipes.
        try ("#!/bin/bash\nfor ((fd=3; fd<255; fd++)); do eval \"exec $fd>&-\"; done\nexec " + Tmux.shellQuote(tmux) + " -S " + Tmux.shellQuote(socket) + " -f /dev/null \"$@\"\n")
            .write(to: shim, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
        var environment = ProcessInfo.processInfo.environment
        environment["TMUX_TMPDIR"] = root.url.path
        environment["HOME"] = home.path
        environment["PATH"] = bin.path + ":/usr/bin:/bin:/usr/sbin:/sbin"
        environment["TERM"] = "xterm-256color"
        environment["LC_ALL"] = "C"
        environment["TMUX"] = nil
        environment["TMUX_PANE"] = nil
        environment["SSH_TTY"] = nil
        self.environment = environment
    }

    deinit { _ = try? raw(["kill-server"]) }

    /// Runs tmux on the host's server. A command that kills or detaches runs only once tmux names the host's socket.
    func raw(_ args: [String]) throws -> String {
        if ["kill-server", "kill-pane", "detach-client"].contains(args.first ?? "") {
            let actual = try run(CommandInvocation(executable: shim.path, arguments: ["display-message", "-p", "#{socket_path}"]))
            guard actual.trimmingCharacters(in: .whitespacesAndNewlines) == socket else { throw TmuxError.notReady }
        }
        return try run(CommandInvocation(executable: shim.path, arguments: ["-u"] + args))
    }

    /// Runs `invocation` in the host's environment.
    func run(_ invocation: CommandInvocation) throws -> String {
        try runner.run(invocation, environment: environment)
    }

    /// Ends a process the test started: SIGTERM, then SIGKILL after a second.
    func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        if !eventually("", timeout: 1, fail: { _, _, _ in }, until: { !process.isRunning }) {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }
}
