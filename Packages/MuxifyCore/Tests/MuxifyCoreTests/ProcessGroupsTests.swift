import XCTest
@testable import MuxifyCore

final class ProcessGroupsTests: XCTestCase {
    /// The app's children and the CPU of the ones that exited, as the kernel would give them.
    private final class FakeTable: ProcessTable {
        var processes: [Int32: ProcessUsage] = [:]
        var childPIDs: [Int32] = []
        var reapedChildren = ReapedChildren(all: 0, leftOut: 0)

        func children() -> [Int32] { childPIDs }
        func usage(of pid: Int32) -> ProcessUsage? { processes[pid] }
        func reaped() -> ReapedChildren { reapedChildren }

        func start(_ pid: Int32, _ name: String, cpu: TimeInterval = 0, child: Bool = true) {
            processes[pid] = ProcessUsage(pid: pid, name: name, cpu: cpu, footprint: 4 * 1_048_576)
            if child { childPIDs.append(pid) }
        }

        func run(_ pid: Int32, for cpu: TimeInterval) { processes[pid]?.cpu += cpu }

        /// The child exits and is waited for: its whole CPU joins the reaped total.
        func exit(_ pid: Int32, leftOut: Bool = false) {
            guard let process = processes.removeValue(forKey: pid) else { return }
            childPIDs.removeAll { $0 == pid }
            reapedChildren.all += process.cpu
            if leftOut { reapedChildren.leftOut += process.cpu }
        }
    }

    private let table = FakeTable()
    private var meter = ProcessGroupsMeter()

    private func read(webkit: [Int32] = [], tmux: Int32? = nil) -> [ProcessGroup: GroupUsage] {
        meter.read(table, webkit: webkit, tmux: tmux)
    }

    func testLiveAndExitedChildrenAreBothCountedAndSampleIsNot() throws {
        table.start(10, "tmux", cpu: 5)   // a control client from before the first read
        table.reapedChildren.all = 30   // children that exited before it
        XCTAssertNil(read()[.commands], "the first read is the baseline")

        // A second: the control client works, a git runs and exits, a sample starts.
        table.run(10, for: 0.1)
        table.start(20, "git")
        table.run(20, for: 0.3)
        table.exit(20)
        table.start(30, "sample", cpu: 0.4)
        var commands = try XCTUnwrap(read()[.commands])
        XCTAssertEqual(commands.cpu, 0.4, accuracy: 1e-9)
        XCTAssertEqual(commands.footprint, 4 * 1_048_576, "the live client, not sample")

        // An ssh is read alive, then exits: what was read of it is not counted twice. sample works on and exits.
        table.start(40, "ssh")
        table.run(40, for: 0.2)
        table.run(30, for: 0.9)
        XCTAssertEqual(try XCTUnwrap(read()[.commands]).cpu, 0.2, accuracy: 1e-9)
        table.run(40, for: 0.05)
        table.run(30, for: 0.5)
        table.exit(40)
        table.exit(30, leftOut: true)
        commands = try XCTUnwrap(read()[.commands])
        XCTAssertEqual(commands.cpu, 0.05, accuracy: 1e-9, "the ssh's last CPU, none of sample's")
        XCTAssertEqual(commands.footprint, 4 * 1_048_576)

        // A quiet second counts nothing.
        XCTAssertEqual(try XCTUnwrap(read()[.commands]).cpu, 0, accuracy: 1e-9)
    }

    func testAChildWaitedForBetweenTheTwoReadsIsCountedOnce() throws {
        _ = read()
        var total = 0.0
        func second() throws -> TimeInterval {
            let cpu = try XCTUnwrap(read()[.commands]).cpu
            total += cpu
            return cpu
        }
        table.start(50, "git")
        table.run(50, for: 0.2)
        XCTAssertEqual(try second(), 0.2, accuracy: 1e-9)
        // Listed alive, then waited for before the reaped total is read: the reaped total counts it ahead.
        let alive = table.processes[50]!
        table.exit(50)
        table.processes[50] = alive
        table.childPIDs.append(50)
        XCTAssertEqual(try second(), 0.2, accuracy: 1e-9)
        table.processes[50] = nil
        table.childPIDs = []
        XCTAssertEqual(try second(), 0, accuracy: 1e-9)
        // The next exited child pays it back, so over the seconds each child is counted once.
        table.start(51, "git")
        table.run(51, for: 0.3)
        table.exit(51)
        XCTAssertEqual(try second(), 0.1, accuracy: 1e-9)
        XCTAssertEqual(total, 0.2 + 0.3, accuracy: 1e-9)
    }

    func testAServerOrPageThatCannotBeReadIsLeftOut() throws {
        // No Local server and no Browser: neither group.
        var groups = read()
        XCTAssertNil(groups[.tmux])
        XCTAssertNil(groups[.webkit])

        // A pid it cannot read, such as another user's, is no figure either.
        groups = read(webkit: [70], tmux: 60)
        XCTAssertNil(groups[.tmux])
        XCTAssertNil(groups[.webkit])

        // The server is counted from its second read on, and is not a command.
        table.start(60, "tmux", cpu: 100, child: false)
        table.start(70, "com.apple.WebKit.WebContent", cpu: 50, child: false)
        groups = read(webkit: [70], tmux: 60)
        XCTAssertNil(groups[.tmux], "what it used before it was first read is not new")
        table.run(60, for: 0.05)
        table.run(70, for: 0.6)
        groups = read(webkit: [70, 71], tmux: 60)
        XCTAssertEqual(try XCTUnwrap(groups[.tmux]).cpu, 0.05, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(groups[.webkit]).cpu, 0.6, accuracy: 1e-9, "a page process it cannot read is left out")
        XCTAssertEqual(try XCTUnwrap(groups[.commands]).cpu, 0, accuracy: 1e-9)

        // The server stops.
        table.processes[60] = nil
        XCTAssertNil(read(webkit: [70], tmux: 60)[.tmux])
    }
}
