import Observation
import XCTest

final class ObservedUpdateTests: XCTestCase {
    @Observable @MainActor final class Source {
        var value = 1
        var other = 1
    }

    @MainActor private func turn() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    @MainActor func testRunUpdatesAtOnce() {
        let source = Source()
        var read: [Int] = []
        let update = ObservedUpdate { read.append(source.value) }

        update.run()

        XCTAssertEqual(read, [1])
    }

    /// A change is reported before the new value is stored, so an update at that moment would read the old one.
    @MainActor func testManyChangesInOneTurnGiveOneUpdateWithTheNewState() {
        let source = Source()
        var read: [Int] = []
        let update = ObservedUpdate { read.append(source.value + source.other) }
        update.run()

        source.value = 2
        source.other = 5
        source.value = 3
        XCTAssertEqual(read, [2], "the update ran while the change was reported")
        turn()

        XCTAssertEqual(read, [2, 8])
    }

    @MainActor func testAChangeAfterAnUpdateGivesTheNextUpdate() {
        let source = Source()
        var read: [Int] = []
        let update = ObservedUpdate { read.append(source.value) }
        update.run()
        source.value = 2
        turn()

        source.value = 3
        turn()

        XCTAssertEqual(read, [1, 2, 3])
    }

    /// The view runs its update itself when a value from the Sidebar changes. The tracking of the run before still
    /// reports the next change, and that must not give a second update.
    @MainActor func testAChangeAfterTwoRunsGivesOneUpdate() {
        let source = Source()
        var updates = 0
        let update = ObservedUpdate { _ = source.value; updates += 1 }
        update.run()
        update.run()

        source.value = 2
        turn()

        XCTAssertEqual(updates, 3)
    }

    @MainActor func testNoUpdateAfterTheOwnerIsGone() {
        let source = Source()
        var updates = 0
        var update: ObservedUpdate? = ObservedUpdate { _ = source.value; updates += 1 }
        update?.run()

        source.value = 2
        update = nil
        turn()

        XCTAssertEqual(updates, 1)
    }
}
