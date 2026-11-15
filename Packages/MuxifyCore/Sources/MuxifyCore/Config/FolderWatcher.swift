import Foundation
#if canImport(CoreServices)
import CoreServices
#endif
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Hears changes to the files in a set of folders: inotify on Linux, FSEvents on a Mac (as ADR 0072's Git watcher).
/// It only says that something changed; the caller reads again and compares. Its calls and its events run on `queue`.
final class FolderWatcher: @unchecked Sendable {
    private let queue: DispatchQueue
    private let changed: () -> Void
    private var folders: Set<String> = []
    #if os(Linux)
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var watches: [Int32] = []
    #elseif canImport(CoreServices)
    private var stream: FSEventStreamRef?
    #endif

    init(queue: DispatchQueue, changed: @escaping () -> Void) {
        self.queue = queue
        self.changed = changed
    }

    /// Watches `folders` in place of the folders before. On `queue`. Returns whether the set changed.
    @discardableResult
    func watch(_ folders: Set<String>) -> Bool {
        guard folders != self.folders else { return false }
        self.folders = folders
        start()
        return true
    }

    /// Stops hearing. On `queue`.
    func stop() {
        folders = []
        stopWatching()
    }

    deinit { stopWatching() }

    #if os(Linux)
    private static let mask = Inotify.changes | Inotify.folderGone

    private func start() {
        if fd < 0 {
            fd = Inotify.initialize()
            guard fd >= 0 else { return }
            let fd = fd
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in
                // Drains every waiting event, then says once that something changed.
                var buffer = [UInt8](repeating: 0, count: 4096)
                while buffer.withUnsafeMutableBytes({ read(fd, $0.baseAddress, $0.count) }) > 0 {}
                self?.changed()
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            self.source = source
        }
        for watch in watches { _ = Inotify.removeWatch(fd, watch) }
        watches = folders.sorted().map { Inotify.addWatch(fd, $0, Self.mask) }.filter { $0 >= 0 }
    }

    private func stopWatching() {
        source?.cancel()
        source = nil
        fd = -1
        watches = []
    }
    #elseif canImport(CoreServices)
    /// The watched folders, compared as folders (ADR 0022): FSEvents names `/tmp` as `/private/tmp`.
    private var watchedFolders: Set<Folder> = []

    private func start() {
        stopWatching()
        guard !folders.isEmpty else { return }
        watchedFolders = Set(folders.map(Folder.local))
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let changed = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            // FSEvents watches a whole tree; inotify, and this, only the folder's own files.
            let folders = watcher.watchedFolders
            if changed.contains(where: { folders.contains(.local($0)) || folders.contains(.local(($0 as NSString).deletingLastPathComponent)) }) {
                watcher.changed()
            }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagFileEvents
                                             | kFSEventStreamCreateFlagUseCFTypes)
        guard let stream = FSEventStreamCreate(nil, callback, &context, folders.sorted() as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        self.stream = stream
    }

    private func stopWatching() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
    #else
    private func start() {}
    private func stopWatching() {}
    #endif
}
