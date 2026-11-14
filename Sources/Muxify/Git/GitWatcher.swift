import CoreServices
import Foundation
import MuxifyCore

/// The folders of a repository that change when it does: the Worktree's top folder, with its files and, in the main
/// checkout, its git directory (HEAD, index), and the common git directory, with the refs, which for a linked
/// Worktree lies outside the tree and holds the Worktree's own git directory.
struct GitWatchedRepository: Equatable {
    var root: String
    var commonDirectory: String

    init(root: String, commonDirectory: String) {
        self.root = root
        self.commonDirectory = commonDirectory
    }

    init(_ snapshot: GitSnapshot) {
        self.init(root: snapshot.root, commonDirectory: snapshot.commonDirectory)
    }

    /// Each folder once: a common git directory inside the top folder is watched with it.
    var folders: [String] {
        let root = root.hasSuffix("/") ? String(root.dropLast()) : root
        guard !commonDirectory.isEmpty, commonDirectory != root, !commonDirectory.hasPrefix(root + "/") else { return [root] }
        return [root, commonDirectory]
    }
}

/// Tells the Git View that its repository may have changed, so it reads it again (ADR 0072, ADR 0085). The Git View starts it while it is open and current and stops it when it
/// closes or is suspended; it debounces and spaces the reads itself. Calls come on the main thread.
protocol GitWatcher: AnyObject {
    /// Reports changes to `repository` by calling `changed` on the main thread. Started again with another
    /// repository, it watches that one instead.
    func start(_ repository: GitWatchedRepository, changed: @escaping () -> Void)
    /// Reports nothing more until started again.
    func stop()
}

/// Watches a repository in the Local Environment with FSEvents, on its folders and everything in them: what feeds the
/// Local link's `repository` subscription.
final class GitFileWatcher: GitWatcher {
    private var stream: FSEventStreamRef?
    private var watched: GitWatchedRepository?
    private var changed: (() -> Void)?

    func start(_ repository: GitWatchedRepository, changed: @escaping () -> Void) {
        self.changed = changed
        guard stream == nil || repository != watched else { return }
        stopStream()
        watched = repository
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<GitFileWatcher>.fromOpaque(info).takeUnretainedValue().changed?()
        }
        // The Git View debounces; FSEvents only gathers what comes within 50 ms, and reports the first event at once.
        guard let stream = FSEventStreamCreate(nil, callback, &context, repository.folders as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)) else { return }
        // Events come on the main queue, where stop runs, so none comes after it.
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        self.stream = stream
    }

    func stop() {
        stopStream()
        changed = nil
    }

    private func stopStream() {
        watched = nil
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stopStream() }
}

/// The Git View's watcher in every Environment: the `repository` subscription of the repository's top folder through
/// the store's link (ADR 0085). FSEvents feeds it for the Local Environment, the Host Server's watch for a Host. Each
/// event that says the repository changed reports it.
final class RepositoryWatcher: GitWatcher {
    typealias Watch = @MainActor (_ path: String, _ onEvent: @escaping (RepositoryEvent) -> Void) -> EnvironmentSubscription

    private let watchRepository: Watch
    private var subscription: EnvironmentSubscription?
    private var watched: GitWatchedRepository?
    private var changed: (() -> Void)?

    init(_ watchRepository: @escaping Watch) {
        self.watchRepository = watchRepository
    }

    func start(_ repository: GitWatchedRepository, changed: @escaping () -> Void) {
        self.changed = changed
        guard subscription == nil || repository != watched else { return }
        stopSubscription()
        watched = repository
        subscription = MainActor.assumeIsolated {
            watchRepository(repository.root) { [weak self] event in
                if event.changed { self?.changed?() }
            }
        }
    }

    func stop() {
        stopSubscription()
        changed = nil
    }

    private func stopSubscription() {
        watched = nil
        guard let subscription else { return }
        self.subscription = nil
        MainActor.assumeIsolated { subscription.cancel() }
    }
}

/// The `repository` subscription of a folder in the Local Environment: one probe for the first event and the folders,
/// then ADR 0072's FSEvents watcher on them, and one HEAD read once it watches. Each change it hears is an event at once, with HEAD as it was; HEAD is read
/// again at most once a second, and an event follows when it moved. A folder in no repository is not watched: the
/// header reads it again when its Window's folder changes.
@MainActor
final class LocalRepositoryWatch {
    let path: String
    private let onEvent: (RepositoryEvent) -> Void
    private let files = GitFileWatcher()
    private var head: GitHeadRead = .unknown
    private var stopped = false
    private var readingHead = false
    private var headWanted = false
    private var lastHeadRead: TimeInterval?

    init(path: String, onEvent: @escaping (RepositoryEvent) -> Void) {
        self.path = path
        self.onEvent = onEvent
    }

    func start() {
        let path = path
        Task { [weak self] in
            let probe = await Task.detached(priority: .userInitiated) { GitReader().probe(path) }.value
            self?.started(probe)
        }
    }

    func stop() {
        stopped = true
        files.stop()
    }

    private func started(_ probe: RepositoryProbe) {
        guard !stopped, probe.head.isRepository != nil else { return }
        head = probe.head
        onEvent(RepositoryEvent(probe.head, changed: false))
        guard let root = probe.root else { return }
        files.start(GitWatchedRepository(root: root, commonDirectory: probe.commonDirectory ?? "")) { [weak self] in
            MainActor.assumeIsolated { self?.filesChanged() }
        }
        // HEAD may have moved between the probe and the watcher's start, which FSEvents never reports.
        readHead()
    }

    private func filesChanged() {
        guard !stopped else { return }
        onEvent(RepositoryEvent(head, changed: true))
        readHead()
    }

    /// One HEAD read at a time, each at least a second after the last.
    private func readHead() {
        headWanted = true
        guard !readingHead else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let lastHeadRead, now - lastHeadRead < 1 {
            readingHead = true
            DispatchQueue.main.asyncAfter(deadline: .now() + (1 - (now - lastHeadRead))) { [weak self] in
                MainActor.assumeIsolated {
                    self?.readingHead = false
                    self?.readHead()
                }
            }
            return
        }
        headWanted = false
        readingHead = true
        lastHeadRead = now
        let path = path
        Task { [weak self] in
            let read = await Task.detached(priority: .utility) { GitReader().head(path) }.value
            self?.didRead(read)
        }
    }

    private func didRead(_ read: GitHeadRead) {
        readingHead = false
        guard !stopped else { return }
        if read.isRepository != nil, read != head {
            head = read
            onEvent(RepositoryEvent(read, changed: true))
        }
        if headWanted { readHead() }
    }
}
