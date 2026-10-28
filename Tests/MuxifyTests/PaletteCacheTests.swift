import Observation
import XCTest
@testable import MuxifyCore

final class PaletteCacheTests: XCTestCase {
    @MainActor private final class Change { var observed = false }

    @MainActor func testAssigningAStoreInvalidatesAnEmptyResult() {
        let palette = CommandPalette()
        palette.toggle(CommandPaletteConfig(name: "Commands", triggers: [], sources: [.commands]))
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
