#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

/// The Host Server's side of the `repository` subscription (ADR 0085). It probes the folder at once, for the first
/// event, then again whenever its git directory changes and every `probeInterval` as a safety net, and sends an event
/// whenever HEAD or the probe's fingerprint changed since the event before. The git directory's watch is
/// non-recursive, as ADR 0072's set: the Worktree's own git directory (HEAD, the index), the common git directory and
/// its `refs/heads` (the refs). Edits in the working tree reach it through the probe's status checksum.
public final class RepositoryWatch: @unchecked Sendable {
    public let path: String
    private let reader: GitReader
    private let probeInterval: TimeInterval
    private let settle: TimeInterval
    private let onEvent: @Sendable (RepositoryEvent) -> Void
    /// Everything below runs on it.
    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?
    private var directories: GitDirectoryEvents?
    private var watched: [String] = []
    private var last: RepositoryProbe?
    private var checkPending = false
    private let lock = NSLock()
    private var stoppedStorage = false
    private var stopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stoppedStorage
    }

    public init(path: String, reader: GitReader = GitReader(), probeInterval: TimeInterval = 2, settle: TimeInterval = 0.05,
                onEvent: @escaping @Sendable (RepositoryEvent) -> Void) {
        self.path = path
        self.reader = reader
        self.probeInterval = probeInterval
        self.settle = settle
        self.onEvent = onEvent
        queue = DispatchQueue(label: "dev.muxify.repository-watch")
    }

    /// Probes at once, then on each change of the git directory and every `probeInterval`.
    public func start() {
        queue.async { [self] in
            guard !stopped, timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + probeInterval, repeating: probeInterval)
            timer.setEventHandler { [weak self] in self?.check() }
            timer.resume()
            self.timer = timer
            check()
        }
    }

    /// Sends nothing more, at once; its event handler may call it.
    public func stop() {
        lock.lock()
        stoppedStorage = true
        lock.unlock()
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            directories?.stop()
            directories = nil
        }
    }

    /// Whether the git directory's watch is set: the folder is in a repository, and this system has a watch.
    public var watchesGitDirectory: Bool {
        queue.sync { directories != nil }
    }

    /// A change of the git directory: probes once the changes stop for `settle`.
    private func gitDirectoryChanged() {
        guard !checkPending else { return }
        checkPending = true
        queue.asyncAfter(deadline: .now() + settle) { [weak self] in
            self?.checkPending = false
            self?.check()
        }
    }

    private func check() {
        guard !stopped else { return }
        let probe = reader.probe(path)
        guard !stopped, probe.head.isRepository != nil else { return }
        watch(probe)
        let previous = last
        last = probe
        guard let previous else { return onEvent(RepositoryEvent(probe.head, changed: false)) }
        if previous.head != probe.head || previous.fingerprint != probe.fingerprint {
            onEvent(RepositoryEvent(probe.head, changed: true))
        }
    }

    /// Watches the git directories of the repository just probed, when they are others.
    private func watch(_ probe: RepositoryProbe) {
        var folders: [String] = []
        for folder in [probe.gitDirectory, probe.commonDirectory, probe.commonDirectory.map { $0 + "/refs/heads" }] {
            if let folder, !folders.contains(folder) { folders.append(folder) }
        }
        guard folders != watched else { return }
        watched = folders
        directories?.stop()
        directories = folders.isEmpty ? nil : GitDirectoryEvents(folders: folders, queue: queue) { [weak self] in
            self?.gitDirectoryChanged()
        }
    }
}

/// Reports, on `queue`, that an entry of one of the folders was made, written, renamed or removed. Not recursive. Git
/// writes HEAD, the index and each ref as a lock file that it renames, so each write shows in its folder. It uses
/// inotify on Linux and a kqueue vnode watch on macOS; elsewhere it watches nothing and the probe alone serves.
final class GitDirectoryEvents {
    #if os(Linux)
    private var source: DispatchSourceRead?
    #elseif canImport(Darwin)
    private var sources: [DispatchSourceFileSystemObject] = []
    #endif

    init?(folders: [String], queue: DispatchQueue, changed: @escaping () -> Void) {
        #if os(Linux)
        let descriptor = muxifyInotifyInit1(Inotify.nonBlocking | Inotify.closeOnExec)
        guard descriptor >= 0 else { return nil }
        var watching = 0
        for folder in folders where muxifyInotifyAddWatch(descriptor, folder, Inotify.changes) >= 0 { watching += 1 }
        guard watching > 0 else {
            close(descriptor)
            return nil
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler {
            // Drains the events: which file changed matters less than that one did.
            var buffer = [UInt8](repeating: 0, count: 4096)
            while buffer.withUnsafeMutableBytes({ read(descriptor, $0.baseAddress, $0.count) }) > 0 {}
            changed()
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
        #elseif canImport(Darwin)
        for folder in folders {
            let descriptor = open(folder, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete],
                                                                   queue: queue)
            source.setEventHandler(handler: changed)
            source.setCancelHandler { close(descriptor) }
            source.resume()
            sources.append(source)
        }
        guard !sources.isEmpty else { return nil }
        #else
        return nil
        #endif
    }

    func stop() {
        #if os(Linux)
        source?.cancel()
        source = nil
        #elseif canImport(Darwin)
        sources.forEach { $0.cancel() }
        sources = []
        #endif
    }

    deinit { stop() }
}

#if os(Linux)
/// inotify, declared here: the static Linux SDK's C module does not promise `sys/inotify.h`.
private enum Inotify {
    static let nonBlocking: Int32 = 0o4000
    static let closeOnExec: Int32 = 0o2000000
    /// IN_MODIFY, IN_ATTRIB, IN_CLOSE_WRITE, IN_MOVED_FROM, IN_MOVED_TO, IN_CREATE and IN_DELETE.
    static let changes: UInt32 = 0x2 | 0x4 | 0x8 | 0x40 | 0x80 | 0x100 | 0x200
}

@_silgen_name("inotify_init1")
private func muxifyInotifyInit1(_ flags: Int32) -> Int32

@_silgen_name("inotify_add_watch")
private func muxifyInotifyAddWatch(_ descriptor: Int32, _ path: UnsafePointer<CChar>, _ mask: UInt32) -> Int32
#endif
