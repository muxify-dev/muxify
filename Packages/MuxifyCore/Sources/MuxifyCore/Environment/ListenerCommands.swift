import Foundation

/// The commands that the publisher sends through its control Client, from any thread, and the wait for tmux to run
/// them. Control mode answers each command line of the Client with one `%begin` … `%end` block, or `%begin` …
/// `%error`, in the order sent, and flags 1 mark a command from this Client. The Client's first command, the
/// `new-session` on its command line, answers with flags 0, so the count starts after it.
final class ListenerCommands: @unchecked Sendable {
    private let condition = NSCondition()
    // `condition` guards these.
    private var client: TmuxControlClient?
    private var number = 0
    private var sent = 0
    private var answered = 0

    /// `client` replaces the one before; `number` tells its lines from those of a Client that it replaced.
    func attach(_ client: TmuxControlClient, number: Int) {
        condition.lock()
        defer { condition.unlock() }
        self.client = client
        self.number = number
        sent = 0
        answered = 0
        condition.broadcast()
    }

    /// The Client has gone: a wait for its answers ends now.
    func detach() {
        condition.lock()
        defer { condition.unlock() }
        client = nil
        number += 1
        condition.broadcast()
    }

    /// Returns once a Client is attached, after at most `timeout`. False when none came in time.
    func waitForClient(timeout: TimeInterval) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while client == nil {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }

    /// Counts the answers in lines of Client `number`.
    func heard(_ lines: [String], number: Int) {
        let answers = lines.filter { line in
            (line.hasPrefix("%end ") || line.hasPrefix("%error ")) && line.split(separator: " ").last == "1"
        }.count
        guard answers > 0 else { return }
        condition.lock()
        defer { condition.unlock() }
        guard number == self.number else { return }
        answered += answers
        condition.broadcast()
    }

    /// Sends the lines without a wait. False when no Client takes them.
    @discardableResult
    func send(_ lines: [String]) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return post(lines) != nil
    }

    /// Sends the lines and returns once tmux has answered the last of them, after at most `timeout`. False when no
    /// Client took them or no answer came in time.
    @discardableResult
    func sendAndWait(_ lines: [String], timeout: TimeInterval) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard let last = post(lines) else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        let number = self.number
        while answered < last, number == self.number {
            guard condition.wait(until: deadline) else { return false }
        }
        return answered >= last && number == self.number
    }

    /// With `condition` held: the count of sent lines after the last of them, or nil when no Client takes them.
    private func post(_ lines: [String]) -> Int? {
        guard let client else { return nil }
        guard !lines.isEmpty else { return sent }
        for line in lines { client.send(line) }
        sent += lines.count
        return sent
    }
}
