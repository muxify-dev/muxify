import XCTest
@testable import MuxifyCore

final class EnvironmentWatchProtocolTests: XCTestCase {
    func testDeltaUsesPublishedBaseAcrossAdmissionGapsAndClearsOptionalValues() throws {
        let module = UUID()
        var before = state(module, 4)
        before.ruleSettings = EnvironmentRuleSettings(config: Config())
        before.ruleFailure = .tmux(.timedOut)
        var next = state(module, 17)
        next.existingWorktrees = ["/remote/worktree"]
        let encoded = try JSONEncoder().encode(EnvironmentStateDelta(from: before, to: next))
        let delta = try JSONDecoder().decode(EnvironmentStateDelta.self, from: encoded)
        let applied = try XCTUnwrap(delta.applying(to: before))
        XCTAssertEqual(applied.revision, next.revision)
        XCTAssertEqual(applied.existingWorktrees, ["/remote/worktree"])
        XCTAssertNil(applied.ruleSettings)
        XCTAssertNil(applied.ruleFailure)
        XCTAssertNil(delta.applying(to: state(module, 5)))
        XCTAssertNil(delta.applying(to: state(UUID(), 4)))
    }

    @MainActor func testReaderWaitsForFreshViewingInventory() throws {
        let reader = EnvironmentReader()
        let module = UUID()
        var received: [EnvironmentState] = []
        reader.read(context: { () }) { state, _ in
            received.append(state)
        }
        reader.awaitSynchronization()
        reader.accept(state(module, 1))
        XCTAssertTrue(received.isEmpty)
        reader.synchronized(EnvironmentRevision(moduleID: module, number: 5))
        reader.accept(state(module, 3))
        XCTAssertTrue(received.isEmpty)
        reader.accept(state(module, 8))
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received[0].revision.number, 8)
        reader.accept(state(module, 10))
        XCTAssertEqual(received.map(\.revision.number), [8, 10])
    }

    func testSlowOutputCoalescesFullState() async throws {
        let pipe = Pipe()
        let writer = EnvironmentWatchOutputWriter(output: pipe.fileHandleForWriting) { XCTFail("Unexpected output failure") }
        let module = UUID()
        var huge = state(module, 1)
        huge.ruleFailure = .other(String(repeating: "x", count: 1024 * 1024))
        writer.publish(huge)
        try await Task.sleep(for: .milliseconds(50))
        writer.publish(state(module, 2))
        writer.publish(state(module, 3))
        writer.publish(state(module, 20))
        let finished = expectation(description: "writer drains")
        writer.finish { try? pipe.fileHandleForWriting.close(); finished.fulfill() }
        let output = await Task.detached { pipe.fileHandleForReading.readDataToEndOfFile() }.value
        await fulfillment(of: [finished], timeout: 3)
        let lines = try output.split(separator: 10).map { try JSONDecoder().decode(EnvironmentWatchOutput.self, from: Data($0)) }
        let states = lines.compactMap { line -> EnvironmentState? in if case .full(let state) = line { return state }; return nil }
        XCTAssertEqual(states.last?.revision.number, 20)
        XCTAssertLessThanOrEqual(lines.count, 2)
    }

    private func state(_ module: UUID, _ number: UInt64) -> EnvironmentState {
        EnvironmentState(revision: EnvironmentRevision(moduleID: module, number: number),
            inventory: .current(TmuxSnapshot(windows: [], clients: [], panes: [], serverRunning: false)),
            records: .current(TopicContents()))
    }
}
