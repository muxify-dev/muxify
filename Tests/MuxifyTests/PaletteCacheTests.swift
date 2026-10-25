import Observation
import XCTest
@testable import MuxifyCore

final class PaletteCacheTests: XCTestCase {
    @MainActor private final class Change { var observed = false }

    @MainActor func testResultsReuseDeadlinesUntilTheQueryChangesOrTheyExpire() throws {
        let store = WorkspaceStore(configStore: ConfigStore(path: "/nonexistent/muxify-cache-tests.yaml"))
        let palette = store.palette
        palette.replaceFlow(.snoozeUntil(["test"]))
        palette.query = "1m"
        let first = palette.results
        XCTAssertFalse(first.rows.isEmpty)
        XCTAssertEqual(palette.results, first)
        XCTAssertEqual(palette.results, first)
        palette.query = "2m"
        let second = palette.results
        XCTAssertNotEqual(second, first)
        XCTAssertEqual(palette.results, second)
        RunLoop.main.run(until: Date().addingTimeInterval(1.1))
        XCTAssertNotEqual(palette.results, second, "relative deadlines must follow time while the step stays open")
        palette.close(restoringFocus: false)
    }

    @MainActor func testAssigningAStoreInvalidatesAnEmptyResult() {
        let palette = CommandPalette()
        palette.replaceFlow(.snoozeUntil(["test"]))
        XCTAssertTrue(palette.results.rows.isEmpty)
        let store = WorkspaceStore(configStore: ConfigStore(path: "/nonexistent/muxify-cache-tests.yaml"))
        palette.store = store
        XCTAssertFalse(palette.results.rows.isEmpty)
        palette.close(restoringFocus: false)
    }

    @MainActor func testTypingDoesNotInvalidateTheSessionPathRows() {
        let store = WorkspaceStore(configStore: ConfigStore(path: "/nonexistent/muxify-cache-tests.yaml"))
        let changed = Change()
        withObservationTracking {
            _ = store.sessionPathRows
        } onChange: {
            MainActor.assumeIsolated { changed.observed = true }
        }
        store.palette.replaceFlow(.addSession(TopicRecord(id: "test", title: "Test")))
        for query in ["g", "ga", "gam", "game"] {
            store.palette.query = query
            _ = store.palette.results
            _ = store.palette.results
        }
        XCTAssertFalse(changed.observed)
        store.palette.close(restoringFocus: false)
    }
}
