import Foundation
import XCTest
@testable import MuxifyCore

/// The watch behind the Host Server's `config` subscription: inotify on Linux (`make test-linux`), FSEvents on a Mac.
final class FolderWatcherTests: XCTestCase {
    private final class Count: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func add() { lock.lock(); value += 1; lock.unlock() }
        var current: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func wait(_ message: String, seconds: TimeInterval = 5, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() {
            guard Date() < deadline else { return XCTFail(message) }
            Thread.sleep(forTimeInterval: 0.02)
        }
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
        // FSEvents reports from the moment its stream starts; give it that moment.
        Thread.sleep(forTimeInterval: 0.3)
        let before = count.current

        let handle = try FileHandle(forWritingTo: file)
        handle.seekToEndOfFile()
        handle.write(Data("sidebar: {}\n".utf8))
        try handle.close()
        wait("an edit in place fired nothing") { count.current > before }

        queue.sync { watcher.stop() }
        Thread.sleep(forTimeInterval: 0.3)
        let stopped = count.current
        try "ui: {}\n".write(to: file, atomically: true, encoding: .utf8)
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(count.current, stopped, "a stopped watch fired")
    }
}
