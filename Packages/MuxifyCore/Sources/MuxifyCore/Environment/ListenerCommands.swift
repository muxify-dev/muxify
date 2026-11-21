import Foundation

/// The commands that the publisher sends through its control Client, from any thread. It sends them and returns at
/// once: nothing waits for tmux to answer them.
final class ListenerCommands: @unchecked Sendable {
    private let lock = NSLock()
    // `lock` guards these.
    private var client: TmuxControlClient?
    /// Lines sent while no Client was attached, that the next Client takes first.
    private var held: [String] = []

    /// `client` replaces the one before, and takes the held lines first.
    func attach(_ client: TmuxControlClient) {
        lock.lock()
        defer { lock.unlock() }
        self.client = client
        for line in held { client.send(line) }
        held = []
    }

    /// The Client has gone: lines sent now go to the next one only when they are held.
    func detach() {
        lock.lock()
        defer { lock.unlock() }
        client = nil
    }

    /// Whether a Client takes lines now.
    var isAttached: Bool {
        lock.lock()
        defer { lock.unlock() }
        return client != nil
    }

    /// Sends the lines, in order, without a wait. False when no Client takes them now: then `hold` keeps them for the
    /// next Client, and without it they are skipped.
    @discardableResult
    func send(_ lines: [String], hold: Bool = false) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let client else {
            if hold { held += lines }
            return false
        }
        for line in lines { client.send(line) }
        return true
    }
}
