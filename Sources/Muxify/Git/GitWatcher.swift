import CoreServices
import Foundation

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

/// Tells the Git View that its repository may have changed, so it reads it again (ADR "The Git View watches a local
/// repository and probes a remote one"). The Git View starts it while it is open and current and stops it when it
/// closes or is suspended; it debounces and spaces the reads itself. Calls come on the main thread.
protocol GitWatcher: AnyObject {
    /// Reports changes to `repository` by calling `changed` on the main thread. Started again with another
    /// repository, it watches that one instead.
    func start(_ repository: GitWatchedRepository, changed: @escaping () -> Void)
    /// Reports nothing more until started again.
    func stop()
}

/// Watches a repository in the Local Environment with FSEvents, on its folders and everything in them.
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
