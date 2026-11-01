import XCTest
@testable import MuxifyCore

/// A virus scanner holds each new file open, so the lease that every App Window and the CLI renew about once a second
/// must not write a file when its content stays the same.
final class EnvironmentRulesLeaseTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// The inode of each JSON file: an atomic write replaces a file with a new inode.
    private func inodes() throws -> [String: UInt64] {
        var result: [String: UInt64] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) where name.hasSuffix(".json") {
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)
            result[name] = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        }
        return result
    }

    func testARenewalWithTheSameFactsWritesNoFile() throws {
        let lease = try EnvironmentRulesLease(directory: directory)
        let settings = EnvironmentRuleSettings(config: Config())
        let viewing = EnvironmentViewing(client: "/dev/ttys001", window: "@1", visible: true)
        XCTAssertTrue(try lease.acquire(settings: settings))
        try lease.update(viewing, serverID: "server", clientPID: 7)
        let first = try inodes()
        XCTAssertEqual(first.count, 2, "the lease wrote no settings file or no reader file")

        XCTAssertTrue(try lease.acquire(settings: settings))
        try lease.update(viewing, serverID: "server", clientPID: 7)
        XCTAssertEqual(try inodes(), first, "a renewal with the same facts wrote a new file")

        try lease.update(EnvironmentViewing(client: "/dev/ttys001", window: "@2", visible: true), serverID: "server", clientPID: 7)
        let changed = try inodes()
        XCTAssertEqual(changed.filter { $0.key == "settings.json" }, first.filter { $0.key == "settings.json" })
        XCTAssertNotEqual(changed, first, "a change of the viewed Window wrote no new reader file")
    }

    func testANewOwnerWritesTheSettingsAgain() throws {
        let settings = EnvironmentRuleSettings(config: Config())
        var older: EnvironmentRulesLease? = try EnvironmentRulesLease(directory: directory)
        XCTAssertTrue(try older?.acquire(settings: settings) ?? false)
        var other = settings
        other.inPlay = 3
        let newer = try EnvironmentRulesLease(directory: directory)
        XCTAssertFalse(try newer.acquire(settings: other), "a second lease owns the rules while the first one lives")
        older = nil
        XCTAssertTrue(try newer.acquire(settings: other))
        XCTAssertEqual(newer.effectiveSettings(), other, "the new owner did not write its settings")
    }
}
