import XCTest
import MuxifyCore

@MainActor
final class SettingsModelTests: XCTestCase {
    private func setting(_ id: String) throws -> ConfigSetting {
        try XCTUnwrap(Config.settings.first { $0.id == id })
    }

    func testSaveWritesAChangeKeepsCommentsAndReloadsTheConfig() throws {
        let directory = try TestDirectory()
        let path = directory.url.appendingPathComponent("muxify/config.yaml").path
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try "sidebar:\n  # mine\n  agents_scope: all  # keep\n".write(toFile: path, atomically: true, encoding: .utf8)
        let store = ConfigStore(path: path)
        let model = SettingsModel(configStore: store)
        let scope = try setting("sidebar.agents_scope")
        XCTAssertEqual(model.field(scope).value, "all")

        model.set(scope, to: "window")
        model.set(try setting("ui.pulse"), to: "false")
        XCTAssertTrue(model.hasChanges)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "sidebar:\n  # mine\n  agents_scope: all  # keep\n")
        model.save()

        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8),
                       "sidebar:\n  # mine\n  agents_scope: window  # keep\n\nui:\n  pulse: false\n")
        XCTAssertFalse(model.hasChanges)
        XCTAssertEqual(store.config.sidebar.agentsScope[.topics], .window)
        XCTAssertFalse(store.config.pulse)
    }

    func testAListOrMappingFromItsControlsGoesUnderItsKey() throws {
        let directory = try TestDirectory()
        let path = directory.url.appendingPathComponent("config.yaml").path
        let store = ConfigStore(path: path)
        let model = SettingsModel(configStore: store)
        let lists = try setting("pick_lists")
        let tree = ConfigValue.map([.init(key: "add_session", value: .map([.init(key: "show", value: .list([.scalar("session-path"), .scalar("worktree")]))]))])
        model.set(lists, to: tree.yaml)
        model.set(try setting("remote_environments"), to: try setting("remote_environments").templateValue)
        model.save()
        XCTAssertTrue(try String(contentsOfFile: path, encoding: .utf8).hasPrefix("pick_lists:\n  add_session:\n    show: [session-path, worktree]\n"))
        XCTAssertEqual(store.problems, [])
        XCTAssertEqual(store.config.remoteEnvironments.map(\.name), ["Macbook Home"])
    }

    func testATypedChangeIsCheckedAfterAPause() async throws {
        let model = SettingsModel(configStore: ConfigStore(path: "/nonexistent/muxify/config.yaml"))
        let size = try setting("ui.font_size")
        model.set(size, to: "99")
        XCTAssertTrue(model.field(size).problems.isEmpty, "the check waits for a pause in typing")
        for _ in 0..<40 where model.field(size).problems.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(model.field(size).problems.count, 1)
    }

    func testAProblemShowsUnderItsSettingAndASyntaxErrorBlocksSave() throws {
        let store = ConfigStore(path: "/nonexistent/muxify/config.yaml")
        let model = SettingsModel(configStore: store)
        let size = try setting("ui.font_size")
        model.set(size, to: "99")
        model.checkNow()
        XCTAssertEqual(model.field(size).problems.count, 1)
        XCTAssertFalse(model.hasSyntaxError)

        model.set(size, to: "[1")
        model.save()
        XCTAssertTrue(model.hasSyntaxError, "Save checks the draft before it writes")
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.path))
        model.reset(size)
        model.checkNow()
        XCTAssertFalse(model.hasSyntaxError)
        XCTAssertFalse(model.hasChanges)
    }
}
