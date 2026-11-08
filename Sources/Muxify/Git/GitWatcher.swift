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

/// Probes a repository on a Remote Environment, where FSEvents cannot see: every `interval`, over the owned ssh
/// connection, one script reads HEAD, the index's modification time and a hash of the status, and the Git View reads
/// again only when one of them changed since the last probe. It needs only `git` and `sh` on the remote machine and
/// leaves nothing running there. A failed probe, as with the connection down, reports nothing; the next one retries.
final class GitRemoteProbe: GitWatcher {
    /// Runs a script with its arguments on the Environment's machine and calls back on the main thread:
    /// `WorkspaceStore.runGitScript`.
    typealias Run = (_ script: String, _ arguments: [String],
                     _ completion: @escaping (Result<String, Error>) -> Void) -> Void

    /// Takes the top folder. Prints a section, `probe`, with HEAD's commit and branch, the index's modification time
    /// (GNU `stat`, else BSD) and a checksum of the status; nothing when the folder is gone or in no repository.
    /// `GIT_OPTIONAL_LOCKS=0`, so `git status` never rewrites the index and changes its time on every probe.
    static let script = """
    cd "$1" 2>/dev/null || exit 0
    export GIT_OPTIONAL_LOCKS=0
    index=$(git rev-parse --git-path index 2>/dev/null) || exit 0
    printf '\\036probe\\n'
    git rev-parse -q --verify HEAD 2>/dev/null
    git symbolic-ref -q HEAD 2>/dev/null
    stat -c %y "$index" 2>/dev/null || stat -f %Fm "$index" 2>/dev/null
    git -c core.quotepath=off status --porcelain=v1 --branch -z --untracked-files=all 2>/dev/null | cksum
    """

    /// What a probe read, or nil when it read nothing.
    static func value(of result: Result<String, Error>) -> String? {
        guard case .success(let output) = result else { return nil }
        return GitRepository.sections(output)["probe"]
    }

    let interval: TimeInterval
    private let run: Run
    private var timer: Timer?
    private var watched: GitWatchedRepository?
    private var changed: (() -> Void)?
    /// What the last probe that read anything read: a change since is reported.
    private var last: String?
    private var isProbing = false
    /// Counts the starts and stops, so a probe that ends after one changes nothing.
    private var generation = 0

    init(interval: TimeInterval = 2, run: @escaping Run) {
        self.interval = interval
        self.run = run
    }

    /// Probes at once, for the values the next probes are compared with, then every `interval`.
    func start(_ repository: GitWatchedRepository, changed: @escaping () -> Void) {
        self.changed = changed
        guard timer == nil || repository != watched else { return }
        stopTimer()
        watched = repository
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.probe() }
        probe()
    }

    func stop() {
        stopTimer()
        changed = nil
    }

    /// One probe at a time: a tick while one runs, as over a slow connection, starts none.
    func probe() {
        guard let watched, !isProbing else { return }
        isProbing = true
        let generation = generation
        run(Self.script, [watched.root]) { [weak self] result in
            guard let self, self.generation == generation else { return }
            self.isProbing = false
            guard let value = Self.value(of: result) else { return }
            let last = self.last
            self.last = value
            if let last, last != value { self.changed?() }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        watched = nil
        last = nil
        isProbing = false
        generation += 1
    }

    deinit { timer?.invalidate() }
}
