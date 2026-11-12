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
