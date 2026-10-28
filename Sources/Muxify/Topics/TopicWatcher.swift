import Foundation
import Observation
import MuxifyCore

/// The Topic records as the Sidebar shows them: the last read of the store, read again within 0.25 s of a
/// change on disk, made by this app or by another process.
@Observable
final class TopicWatcher {
    let store: TopicStore
    private(set) var records: [TopicRecord] = []
    private(set) var problems: [String] = []
    /// The records hold Snoozes or a Zen from an older Muxify, which `EnvironmentService.upgradeRecords` removes.
    private(set) var needsUpgrade = false
    @ObservationIgnored private var stamp = ""
    @ObservationIgnored private var timer: Timer?

    init(store: TopicStore = TopicStore(paths: MuxifyPaths())) {
        self.store = store
        reload()
    }

    deinit { timer?.invalidate() }

    func start() {
        guard timer == nil else { return }
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, self.store.stamp() != self.stamp else { return }
            self.reload()
        }
    }

    /// A read that fails keeps the last records, so the Sidebar does not empty while another process writes.
    func reload() {
        let stamp = store.stamp()
        let contents: TopicContents
        do { contents = try store.read() }
        catch {
            Diagnostics.report("topics: \(error)")
            return
        }
        records = contents.records
        needsUpgrade = contents.needsUpgrade
        problems = contents.problems
        for problem in problems { Diagnostics.report("topics: \(problem)") }
        self.stamp = stamp
    }

    /// Writes through the store and reads the result at once, so the Sidebar does not wait for the timer.
    @discardableResult
    func write<T>(locks: [SessionLock] = [], _ body: (inout TopicTransaction) throws -> T) throws -> T {
        defer { reload() }
        return try store.write(locks: locks, body)
    }
}
