import Foundation
import XCTest
@testable import MuxifyCore
import MuxifyTestSupport

/// The watch behind the Host Server's `config` subscription: inotify on Linux (`make test-linux`), FSEvents on a Mac.
final class FolderWatcherTests: XCTestCase {
    private final class Count: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func add() { lock.lock(); value += 1; lock.unlock() }
        var current: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    func testTheWatchFiresOnAnEditInPlaceOfAFileInItsFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mxw-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("config.yaml")
        try "ui: {}\n".write(to: file, atomically: true, encoding: .utf8)
        let queue = DispatchQueue(label: "test.folder-watcher")
        let count = Count()
        let watcher = FolderWatcher(queue: queue) { count.add() }
        let changed = queue.sync { watcher.watch([folder.path]) }
        XCTAssertTrue(changed)
        XCTAssertFalse(queue.sync { watcher.watch([folder.path]) }, "the same folders are no change")
        let before = count.current

        // FSEvents reports from a moment after its stream starts, and says nothing of when that is: the file is
        // edited in place again until the watch fires.
        try eventually("an edit in place fired nothing") {
            if count.current > before { return true }
            let handle = try FileHandle(forWritingTo: file)
            handle.seekToEndOfFile()
            handle.write(Data("sidebar: {}\n".utf8))
            try handle.close()
            return false
        }

        // The watch's events run on `queue`, so none comes after the stop.
        queue.sync { watcher.stop() }
        let stopped = count.current
        try "ui: {}\n".write(to: file, atomically: true, encoding: .utf8)
        // absence: a stopped watch fires nothing for a write.
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(count.current, stopped, "a stopped watch fired")
    }
}
