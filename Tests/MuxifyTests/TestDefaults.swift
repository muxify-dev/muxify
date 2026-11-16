import MuxifyCore
import XCTest

extension XCTestCase {
    /// A UserDefaults suite of this test's own, so a `WorkspaceStore` or `AppWindows` it builds never reads or writes
    /// `UserDefaults.standard`, the user's or another test's. Its persistent domain is removed when the test ends.
    func isolatedDefaults() -> UserDefaults {
        let name = "muxify-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
}

extension XCTestCase {
    /// A visit store in a state folder of this test's own, so a `WorkspaceStore` or `AppWindows` it builds never
    /// reads or writes the user's `muxify.db`. The folder is removed when the test ends.
    func isolatedVisits() -> VisitStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("muxify-test-visits-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return VisitStore(paths: MuxifyPaths(environment: ["XDG_STATE_HOME": root.path], home: "/nonexistent"))
    }
}
