#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation
import XCTest

/// The test process's open file descriptors, as `/proc/self/fd` (Linux) or `/dev/fd` (macOS) lists them, each with
/// what it points at, so a leak names its pipes and sockets.
public enum OpenFileDescriptors {
    /// The open descriptors and what each points at, without the one that reads the list.
    public static func current() -> [Int32: String] {
        #if os(Linux)
        let folder = "/proc/self/fd"
        #else
        let folder = "/dev/fd"
        #endif
        guard let directory = opendir(folder) else { return [:] }
        let own = dirfd(directory)
        var numbers: [Int32] = []
        while let entry = readdir(directory) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if let number = Int32(name), number != own { numbers.append(number) }
        }
        closedir(directory)
        var described: [Int32: String] = [:]
        for number in numbers { described[number] = describe(number, in: folder) }
        // A descriptor that closed while the list was read is no longer open.
        return described.filter { fcntl($0.key, F_GETFD) != -1 }
    }

    /// The number of open descriptors.
    public static var count: Int { current().count }

    /// On Linux, the other processes that have `target`, such as a pipe that a child still holds: " (also in tmux
    /// 4242)", or "" when no other process has it.
    static func otherHolders(of target: String) -> String {
        #if os(Linux)
        guard target.hasPrefix("pipe:") || target.hasPrefix("socket:") else { return "" }
        let own = String(getpid())
        let holders = ((try? FileManager.default.contentsOfDirectory(atPath: "/proc")) ?? []).filter { Int($0) != nil && $0 != own }
            .filter { pid in
                let folder = "/proc/\(pid)/fd"
                return ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).contains { fd in
                    (try? FileManager.default.destinationOfSymbolicLink(atPath: "\(folder)/\(fd)")) == target
                }
            }
            .map { pid in
                let name = (try? String(contentsOfFile: "/proc/\(pid)/comm", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
                return "\(name ?? "?") \(pid)"
            }
        return holders.isEmpty ? "" : " (also in \(holders.joined(separator: ", ")))"
        #else
        return ""
        #endif
    }

    private static func describe(_ number: Int32, in folder: String) -> String {
        #if os(Linux)
        var target = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = readlink("\(folder)/\(number)", &target, target.count - 1)
        return length > 0 ? String(decoding: target.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self) : "?"
        #else
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        if fcntl(number, F_GETPATH, &path) != -1 { return String(cString: path) }
        var status = stat()
        guard fstat(number, &status) == 0 else { return "?" }
        switch status.st_mode & S_IFMT {
        case S_IFIFO: return "pipe"
        case S_IFSOCK: return "socket"
        case S_IFCHR: return "character device"
        default: return "kind \(status.st_mode & S_IFMT)"
        }
        #endif
    }
}

/// Fails a test class that ends with more open descriptors than it started with, after its own cleanup. A class that
/// runs real tmux starts a process for nearly every step, and a descriptor that each step leaves open adds up over a
/// run: on Linux the CLI test process reached about 1,355 of them, and it crashed in `Process.run()`, which reads every
/// open descriptor of the parent to close it in the child (CLIIntegrationTestCase says more).
///
/// The class calls `classStarted` from `class func setUp()` and `testEnded` from `invokeTest()` after
/// `super.invokeTest()`, which runs the test's setUp and tearDown. Each test is checked against the count when the
/// class started, so the last test checks how the class ends, and a leak names the test that left it: XCTest on Linux
/// drops a failure from `class func tearDown()`. After a leak the next tests count from it, so they fail only for their
/// own. Descriptors that close a moment after the cleanup, such as a pipe that a just-killed process held, get a few
/// seconds.
///
/// A thread's run loop is not counted: Foundation on Linux makes one, with an epoll, an eventfd and a timerfd, the first
/// time a thread starts a process, and keeps it as long as the thread lives.
public enum DescriptorCheck {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var starts: [ObjectIdentifier: [Int32: String]] = [:]

    /// Records the open descriptors when `testClass` starts.
    public static func classStarted(_ testClass: AnyClass) {
        _ = foundationStartedAProcess
        let open = counted()
        lock.lock()
        starts[ObjectIdentifier(testClass)] = open
        lock.unlock()
    }

    /// Fails the running test when the open descriptors outnumber those when `testClass` started.
    public static func testEnded(_ testClass: AnyClass, file: StaticString = #filePath, line: UInt = #line) {
        lock.lock()
        let start = starts[ObjectIdentifier(testClass)]
        lock.unlock()
        guard let start else { return }
        var open = counted()
        eventually("", timeout: 5, fail: ignoreTheTimeout) {
            open = counted()
            return open.count <= start.count
        }
        guard open.count > start.count else { return }
        // The next tests of the class count from here, so that they fail only for a leak of their own.
        lock.lock()
        starts[ObjectIdentifier(testClass)] = open
        lock.unlock()
        let new = open.filter { start[$0.key] != $0.value }.sorted { $0.key < $1.key }
            .map { "\($0.key) \($0.value)\(OpenFileDescriptors.otherHolders(of: $0.value))" }
        XCTFail("\(testClass) started with \(start.count) open file descriptors and has \(open.count) after its cleanup;"
                + " new: \(new.prefix(20).joined(separator: ", "))\(new.count > 20 ? ", ..." : "")", file: file, line: line)
    }

    /// Foundation opens descriptors for the life of the process with its first `Process`, such as the wakeup socket
    /// pair of its CFSocket thread on Linux. One process run before the first count puts them in every class's start.
    private static let foundationStartedAProcess: Void = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        guard (try? process.run()) != nil else { return }
        process.waitUntilExit()
    }()

    private static func counted() -> [Int32: String] {
        OpenFileDescriptors.current().filter { !runLoopKinds.contains($0.value) }
    }

    #if os(Linux)
    private static let runLoopKinds: Set<String> = ["anon_inode:[eventpoll]", "anon_inode:[eventfd]", "anon_inode:[timerfd]"]
    #else
    private static let runLoopKinds: Set<String> = []
    #endif
}
