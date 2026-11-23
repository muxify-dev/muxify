import MuxifyTestSupport
import Observation
import XCTest

final class ObservedCacheTests: XCTestCase {
    @Observable @MainActor final class Source {
        var value = 1
    }

    @MainActor final class Box {
        var value: Int?
    }

    /// SwiftUI can update a view while a change is reported, before the new value is stored. A read of the cache at
    /// that moment must not keep the old value after the change is stored.
    @MainActor func testReadWhileAChangeIsReportedDoesNotKeepTheOldValue() {
        let source = Source()
        let cache = ObservedCache { source.value * 10 }
        let readDuringChange = Box()
        withObservationTracking { _ = cache.value } onChange: {
            MainActor.assumeIsolated { readDuringChange.value = cache.value }
        }

        source.value = 2

        XCTAssertEqual(readDuringChange.value, 10, "the read during the change sees the old value")
        // The value built during the change is dropped on the next turn of the main queue.
        waitForTheMainQueue()
        XCTAssertEqual(cache.value, 20)
    }

    @MainActor func testValueIsBuiltOnceUntilTheSourceChanges() {
        let source = Source()
        var builds = 0
        let cache = ObservedCache { builds += 1; return source.value }
        XCTAssertEqual(cache.value, 1)
        XCTAssertEqual(cache.value, 1)
        XCTAssertEqual(builds, 1)

        source.value = 3

        XCTAssertEqual(cache.value, 3)
        XCTAssertEqual(builds, 2)
    }
}
