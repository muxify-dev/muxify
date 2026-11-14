import Foundation

/// A Host Server's own socket (ADR 0089). Programs on the Host send it one request line, as they send the Mac app's
/// socket (ADR 0057): a `BrowserAgentRequest` from `muxify browser`, or a `MacRequest` such as a view verb's
/// `select`. The server passes each to its Mac and writes the Mac's reply line back.
///
/// It sits beside tmux's socket, `<socket_path>.muxify-browser.<pid>`, in tmux's 0700 directory. Starting, it removes
/// every `.muxify-browser.*` socket there that refuses a connection, which a killed server left; stopping, it removes
/// its own. `@muxify_browser_socket` names it while its App Window consumes `@muxify_open`.
final class HostServerSocket: @unchecked Sendable {
    let path: String
    private let tmux: TmuxServer
    private let forward: @Sendable (MacRequest) async -> BrowserAgentReply
    private let log: (String) -> Void
    private let lock = NSLock()
    // `lock` guards these.
    private var listener: BrowserAgentListener?
    private var claimed = false
    private var stopped = false

    init(tmux: TmuxServer, server id: String, log: @escaping (String) -> Void = { _ in },
         forward: @escaping @Sendable (MacRequest) async -> BrowserAgentReply) {
        path = BrowserAgentChannel.socketPath(forTmuxSocket: tmux.socketPath, server: id)
        self.tmux = tmux
        self.log = log
        self.forward = forward
    }

    /// Listens, once. False while it cannot, such as before tmux first made its socket directory; the server tries
    /// again when it sees tmux running.
    @discardableResult
    func listen() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return false }
        if listener != nil { return true }
        Self.removeDeadSockets(beside: tmux.socketPath)
        let forward = forward
        do {
            listener = try BrowserAgentListener.lines(at: path) { line, respond in
                guard let request = Self.request(line) else {
                    return respond(.failure(message: "Muxify cannot read this request; update the CLI and the app together", exitCode: 2))
                }
                Task { respond(await forward(request)) }
            }
            log("muxify server: listens on \(path)")
            return true
        } catch {
            return false
        }
    }

    /// The App Window consumes `@muxify_open`: the option names this socket from now on.
    func claim() {
        lock.lock()
        claimed = true
        lock.unlock()
        guard listen() else { return }
        write(path)
    }

    /// The App Window no longer consumes `@muxify_open`.
    func release() {
        lock.lock()
        claimed = false
        lock.unlock()
        clearIfOwn()
    }

    /// What the option names now, from the server's reads: while it is empty, the consumer's server takes it.
    func noteOption(_ current: String?, serverRunning: Bool) {
        guard serverRunning else { return }
        lock.lock()
        let takes = claimed && !stopped && (current ?? "").isEmpty
        let listening = listener != nil
        lock.unlock()
        if !listening { listen() }
        if takes, listen() { write(path) }
    }

    /// The server exits: the socket goes, and the option with it if it still names this socket.
    func stop() {
        lock.lock()
        stopped = true
        let listener = listener
        self.listener = nil
        lock.unlock()
        listener?.stop()
        clearIfOwn()
    }

    // MARK: - Helpers

    /// A `MacRequest`, or the bare `BrowserAgentRequest` that `muxify browser` sends every socket.
    static func request(_ line: Data) -> MacRequest? {
        if let request = try? JSONDecoder().decode(MacRequest.self, from: line) { return request }
        return (try? JSONDecoder().decode(BrowserAgentRequest.self, from: line)).map(MacRequest.browser)
    }

    /// Removes each Host Server socket beside `tmuxSocket` that nobody listens on.
    static func removeDeadSockets(beside tmuxSocket: String) {
        let directory = (tmuxSocket as NSString).deletingLastPathComponent
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return }
        for name in names where name.contains(".muxify-browser.") {
            let path = (directory as NSString).appendingPathComponent(name)
            if BrowserAgentChannel.isHostServerSocket(path), BrowserAgentChannel.refusesConnection(path) { unlink(path) }
        }
    }

    private func write(_ value: String?) {
        _ = try? tmux.run(ViewCommandExecutor.arguments(for: .setBrowserSocket(path: value)))
    }

    private func clearIfOwn() {
        guard let current = try? tmux.run(["show-options", "-sqv", BrowserAgentChannel.option]),
              current.trimmingCharacters(in: .newlines) == path else { return }
        write(nil)
    }
}

extension ProtocolIncomingRequest {
    /// Ends a `browser` request with the Mac's reply. A `png` goes first as `ProtocolChunk` items of at most
    /// `HostProtocol.maxChunkBytes`, and its `end` carries an empty picture (ADR 0089).
    public func finish(browser reply: BrowserAgentReply) {
        guard case .png(let data) = reply else { return finish(reply) }
        guard stream(data) else { return }
        finish(BrowserAgentReply.png(Data()))
    }
}
