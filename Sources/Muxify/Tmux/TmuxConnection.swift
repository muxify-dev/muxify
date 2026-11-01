import Foundation
import MuxifyCore

extension TmuxServer {
    /// The local server the app works on. A verify run's server starts without the user's tmux config: its
    /// hooks act on the app's clients and leave errors in the throwaway server's Panes.
    static let app: TmuxServer = {
        #if DEBUG
        if TestDriver.isRunning { return TmuxServer(configPath: "/dev/null") }
        #endif
        return .local
    }()
}

/// A Remote Environment's server for the requests that need no Topic record.
extension TmuxConnection: TmuxRunning {}

/// The tmux execution seam. Every operation captures this immutable target;
/// changing the active Environment never retargets work already in flight.
final class TmuxConnection: @unchecked Sendable {
    private let id = UUID()
    let remote: RemoteSSH?
    private let runner = CommandRunner()
    private let queue = DispatchQueue(label: "muxify.tmux.connection", qos: .userInitiated)
    private let attachmentQueue = DispatchQueue(label: "muxify.attachments", qos: .userInitiated)
    private let lock = NSLock()
    private var retired = false

    init(environment: RemoteEnvironment?, sshExecutable: String = "/usr/bin/ssh") throws {
        remote = try environment.map { try RemoteSSH(environment: $0, sshExecutable: sshExecutable) }
    }

    var isRemote: Bool { remote != nil }

    var rulesScope: EnvironmentRulesScope {
        if let environment = remote?.environment {
            return .remoteFallback(host: "\(environment.username)@\(environment.host):\(environment.port ?? 22)")
        }
        return .local(socketPath: TmuxServer.app.socketPath)
    }

    func invocation(_ args: [String]) throws -> CommandInvocation {
        if let remote { return remote.command(args) }
        return try TmuxServer.app.invocation(args)
    }

    func run(_ args: [String]) throws -> String {
        lock.lock()
        let stopped = retired
        lock.unlock()
        guard !stopped else { throw TmuxError.cancelled }
        return try runner.run(invocation(args))
    }

    /// Runs a /bin/sh `script` on the Environment's machine: over the SSH
    /// master for a Remote Environment, else here. Off the tmux queue, so a
    /// slow script never holds up tmux commands.
    func runScriptAsync(_ script: String, arguments: [String] = [], timeout: TimeInterval = 20,
                        completion: @escaping (Result<String, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try self.runScript(script, arguments: arguments, timeout: timeout) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// `ScriptRunning`, for the Muxify Worktree scripts of a Remote Environment.
    func runScript(_ script: String, arguments: [String], timeout: TimeInterval) throws -> String {
        try runScript(script, arguments: arguments, timeout: timeout, inputFile: nil)
    }

    /// `runScriptAsync` for a caller that is already off the main thread.
    func runScript(_ script: String, arguments: [String] = [], timeout: TimeInterval = 20, inputFile: URL? = nil) throws -> String {
        lock.lock()
        let stopped = retired
        lock.unlock()
        guard !stopped else { throw TmuxError.cancelled }
        let invocation = remote?.script(script, arguments: arguments)
            ?? CommandInvocation(executable: "/bin/sh", arguments: ["-c", script, "muxify"] + arguments)
        return try runner.run(invocation, timeout: timeout, inputFile: inputFile)
    }

    /// Resolve the actual Pane of this Client before the upload, independently
    /// of the Sidebar's polling snapshot. A slow upload never blocks tmux reads.
    struct PreparedPaste {
        let pane: PaneID
        let text: String
    }

    func prepareAttachments(_ attachments: TerminalAttachments, client: String,
                            completion: @escaping (Result<PreparedPaste, Error>) -> Void) {
        queue.async {
            let target = Result { try self.run(["display-message", "-p", "-c", client, "#{pane_id}"])
                .trimmingCharacters(in: .newlines) }
            self.attachmentQueue.async {
                let result = Result {
                    defer { if self.isRemote { attachments.removeLocalCopy() } }
                    let pane = try target.get()
                    guard let pane = PaneID(rawValue: pane) else { throw TmuxError.notReady }
                    var words: [String] = []
                    for item in attachments.items {
                        switch item {
                        case .text(let text): words.append(text)
                        case .file(let file):
                            let path = self.isRemote
                                ? try self.runScript(TerminalAttachments.uploadScript, arguments: [file.lastPathComponent],
                                                     timeout: 120, inputFile: file)
                                : file.path
                            guard path.hasPrefix("/") else { throw TmuxError.notReady }
                            words.append(path.contains("\n") || path.contains("\r")
                                         ? Tmux.shellQuote(path) : GhosttyInput.shellEscape(path))
                        }
                    }
                    return PreparedPaste(pane: pane, text: words.joined(separator: " "))
                }
                DispatchQueue.main.async { completion(result) }
            }
        }
    }

    /// Runs a /bin/sh `script` as `runScriptAsync` does, but in a pseudo-terminal with the C locale, over SSH
    /// with a remote PTY for a Remote Environment, so git's and ssh's credential prompts go to `onPrompt`
    /// (`TerminalCommand`). Returns the command, to answer or cancel, or nil after completing with the error.
    @discardableResult
    func startTerminalScript(_ script: String, arguments: [String] = [], timeout: TimeInterval,
                             onPrompt: @escaping (GitCredentialPrompt) -> Void,
                             completion: @escaping (Result<String, Error>) -> Void) -> TerminalCommand? {
        lock.lock()
        let stopped = retired
        lock.unlock()
        let exports = TerminalCommand.locale.keys.sorted().map { "\($0)=\(TerminalCommand.locale[$0]!)" }.joined(separator: " ")
        let script = "export \(exports)\n" + script
        do {
            guard !stopped else { throw TmuxError.cancelled }
            let invocation = remote?.terminalScript(script, arguments: arguments)
                ?? CommandInvocation(executable: "/bin/sh", arguments: ["-c", script, "muxify"] + arguments)
            return try TerminalCommand(invocation, timeout: timeout, onPrompt: onPrompt, completion: completion)
        } catch {
            DispatchQueue.main.async { completion(.failure(error)) }
            return nil
        }
    }

    func snapshot() throws -> TmuxSnapshot {
        guard let remote else {
            do { return stamped(try Tmux.readSnapshot(using: run)) }
            catch InventoryReadFailure.noServer {
                return TmuxSnapshot(windows: [], clients: [], panes: [], serverRunning: false)
            }
        }
        do { _ = try runner.run(remote.control("check"), timeout: 1) }
        catch TmuxError.timedOut { throw InventoryReadFailure.timedOut }
        catch TmuxError.cancelled { throw TmuxError.cancelled }
        catch { throw TmuxError.notReady }
        let marker = try readRemote(["show-option", "-sqv", remote.markerOption])
            .trimmingCharacters(in: .newlines).components(separatedBy: Tmux.separator)
        guard marker.count == 5, marker[4] == "remote", let pid = Int(marker[0]), !marker[1].isEmpty else { throw TmuxError.notReady }
        var snapshot = try Tmux.readSnapshot(using: readRemote)
        guard let client = snapshot.clients.first(where: { $0.pid == pid && $0.tty == marker[1] && !$0.isControl }) else {
            throw TmuxError.notReady
        }
        snapshot.ownClientTTY = client.tty
        snapshot.homeDirectory = marker[2]
        for index in snapshot.windows.indices {
            snapshot.windows[index].homeDirectory = marker[2]
            snapshot.windows[index].hostName = marker[3]
            snapshot.windows[index].isRemote = true
        }
        return stamped(snapshot)
    }

    private func readRemote(_ arguments: [String]) throws -> String {
        do { return try run(arguments) }
        catch TmuxError.failed(255, _) { throw InventoryReadFailure.connectionLost }
        catch let error as TmuxError {
            if let failure = InventoryReadFailure(error) { throw failure }
            throw error
        }
    }

    private func stamped(_ value: TmuxSnapshot) -> TmuxSnapshot {
        var snapshot = value
        for index in snapshot.windows.indices {
            snapshot.windows[index].sourceID = "\(id.uuidString):\(snapshot.serverID ?? "")"
        }
        return snapshot
    }

    var closedSnapshot: TmuxSnapshot? { remote?.closedSnapshot.map(stamped) }

    func terminalCommand(_ plan: EnvironmentAttachment) throws -> String {
        if let remote { return remote.terminalCommand(target: plan.target, createSessionIfNeeded: plan.createSessionIfNeeded) }
        return try invocation(["-u", "attach-session"] + (plan.target.map { ["-t", $0] } ?? [])).commandLine
    }

    /// This read does not wait for the module queue. Each command in the probe has a one-second deadline.
    func attachmentReady(tty: String?) -> Bool {
        let probe = CommandRunner()
        do {
            let expectedTTY: String
            let expectedPID: Int?
            if let remote {
                _ = try probe.run(remote.control("check"), timeout: 1)
                let marker = try probe.run(remote.command(["show-option", "-sqv", remote.markerOption]), timeout: 1)
                    .trimmingCharacters(in: .newlines).components(separatedBy: Tmux.separator)
                guard marker.count == 5, marker[4] == "remote", let pid = Int(marker[0]) else { return false }
                expectedTTY = marker[1]
                expectedPID = pid
            } else {
                guard let tty else { return false }
                expectedTTY = tty
                expectedPID = nil
            }
            let rows = try probe.run(invocation(["list-clients", "-F", "#{client_tty}\t#{client_pid}\t#{client_control_mode}"]), timeout: 1)
            return rows.split(separator: "\n").contains { row in
                let fields = row.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                return fields.count == 3 && fields[0] == expectedTTY && fields[2] == "0"
                    && (expectedPID == nil || Int(fields[1]) == expectedPID)
            }
        } catch { return false }
    }

    /// Call after required Environment writes finish.
    func retire() {
        lock.lock()
        guard !retired else { lock.unlock(); return }
        retired = true
        lock.unlock()
        runner.cancel()
        let finalRunner = CommandRunner()
        if let remote {
            _ = try? finalRunner.run(remote.control("exit"), timeout: 1)
        }
    }

    func cleanup() { remote?.cleanup() }
}

extension TmuxConnection: ScriptRunning {}
