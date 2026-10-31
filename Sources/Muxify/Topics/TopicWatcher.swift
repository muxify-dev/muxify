import Foundation
import Observation
import MuxifyCore

/// The Topic records as the Sidebar shows them: the last read of the store, read again within 0.25 s of a
/// change on disk, made by this app or by another process.
///
/// Every read and write runs on one serial queue, never on the main thread: a file open can wait for seconds on
/// an Endpoint Security client such as a virus scanner, and the app must not freeze while it does. The queue keeps
/// them in the order they were asked for, and the records each one leaves show on the main thread in that order.
/// It is shared across those two threads: the observed properties change only on the main thread, and `stamp` only
/// on the queue.
@Observable
final class TopicWatcher: @unchecked Sendable {
    let store: TopicStore
    private(set) var records: [TopicRecord] = []
    private(set) var openPlaces: [OpenPlace] = []
    private(set) var problems: [String] = []
    /// The records hold Snoozes or a Zen from an older Muxify, which `EnvironmentService.upgradeRecords` removes.
    private(set) var needsUpgrade = false
    @ObservationIgnored private let queue = DispatchQueue(label: "dev.muxify.topic-records", qos: .userInitiated)
    /// The stamp of the last good read. Only `queue` touches it.
    @ObservationIgnored private var stamp = ""
    @ObservationIgnored private var timer: Timer?
    /// A timer read waits in the queue. While a file open stalls, the ticks after it add no more reads.
    @ObservationIgnored private var timerReadQueued = false

    /// The first read is on the calling thread, so the app starts with the records and not with an empty list.
    init(store: TopicStore = TopicStore(paths: MuxifyPaths())) {
        self.store = store
        if let contents = read(ifChanged: false) { show(contents) }
    }

    deinit { timer?.invalidate() }

    func start() {
        guard timer == nil else { return }
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, !timerReadQueued else { return }
            timerReadQueued = true
            queue.async { self.showOnMain(self.read(ifChanged: true)) { self.timerReadQueued = false } }
        }
    }

    /// Reads the records again. They show a moment later, and the caller does not wait.
    func reload() {
        queue.async { self.showOnMain(self.read(ifChanged: false)) }
    }

    /// Reads the records again and returns once they show, after every write asked for before.
    func reloaded() async {
        await withCheckedContinuation { continuation in
            queue.async { self.showOnMain(self.read(ifChanged: false)) { continuation.resume() } }
        }
    }

    /// Returns once every read and write asked for before has shown what it left. It reads nothing itself.
    func caughtUp() async {
        await withCheckedContinuation { continuation in
            queue.async { self.showOnMain(nil) { continuation.resume() } }
        }
    }

    /// Writes through the store, then reads the result, and returns once it shows.
    @discardableResult
    func write<T>(locks: [SessionLock] = [], _ body: @escaping (inout TopicTransaction) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let result = Result { try self.store.write(locks: locks, body) }
                self.showOnMain(self.read(ifChanged: false)) { continuation.resume(with: result) }
            }
        }
    }

    /// On `queue`, or in `init`. Nil when the stamp has not changed, or when the read failed: a failed read keeps
    /// the last records, so the Sidebar does not empty while another process writes.
    private func read(ifChanged: Bool) -> TopicContents? {
        let stamp = store.stamp()
        guard !ifChanged || stamp != self.stamp else { return nil }
        do {
            let contents = try store.read()
            self.stamp = stamp
            for problem in contents.problems { Diagnostics.report("topics: \(problem)") }
            return contents
        } catch {
            Diagnostics.report("topics: \(error)")
            return nil
        }
    }

    private func showOnMain(_ contents: TopicContents?, then done: @escaping () -> Void = {}) {
        DispatchQueue.main.async {
            if let contents { self.show(contents) }
            done()
        }
    }

    /// Sets only what changed, so a read that finds the same records builds no view again.
    private func show(_ contents: TopicContents) {
        if records != contents.records { records = contents.records }
        if openPlaces != contents.openPlaces { openPlaces = contents.openPlaces }
        if needsUpgrade != contents.needsUpgrade { needsUpgrade = contents.needsUpgrade }
        if problems != contents.problems { problems = contents.problems }
    }
}
