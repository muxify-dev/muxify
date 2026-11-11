import XCTest
@testable import MuxifyCore

final class ConfigValueTests: XCTestCase {
    private func setting(_ id: String) throws -> ConfigSetting {
        try XCTUnwrap(Config.settings.first { $0.id == id })
    }

    func testYAMLRoundTripsWithWordListsOnOneLine() throws {
        let value = try XCTUnwrap(ConfigValue(yaml: "- name: Go to…\n  sources: [topics, sessions]\n  keybinding: cmd+p"))
        XCTAssertEqual(value.yaml, "- name: Go to…\n  sources: [topics, sessions]\n  keybinding: cmd+p")
        XCTAssertEqual(ConfigValue.map([.init(key: "color", value: .scalar("#FFD54F"))]).yaml, "color: '#FFD54F'")
        XCTAssertEqual(ConfigValue.map([.init(key: "name", value: .scalar("x")), .init(key: "sources", value: .list([.scalar("a")]))]).blank.yaml,
                       "name: ''\nsources: []")
    }

    func testAPaletteItemKnowsItsKeysAndChoices() throws {
        let palettes = try setting("command_palettes")
        let item = palettes.shape(at: [.item(3)])
        XCTAssertFalse(item.userKeys)
        XCTAssertEqual(Set(item.keys), ["name", "keybinding", "sources", "order", "tiebreak", "show"])
        XCTAssertEqual(palettes.shape(at: [.item(3), .key("sources")]).choices, ["topics", "sessions", "windows", "agents", "commands"])
        XCTAssertEqual(palettes.shape(at: [.item(0), .key("order")]).choices, ["grouped", "ranked"])
        XCTAssertTrue(palettes.shape(at: [.item(0), .key("keybinding")]).isTrigger)
        XCTAssertTrue(palettes.shape(at: [.item(0), .key("show")]).choices.contains("session-path"))
    }

    func testPickListsKnowTheirListNames() throws {
        let lists = try setting("pick_lists")
        XCTAssertEqual(Array(lists.shape(at: []).keys.prefix(5)), ["add_session", "move", "move_session", "tags", "worktree_start"])
        XCTAssertTrue(lists.shape(at: [.key("add_session"), .key("show")]).choices.contains("worktree"))
        XCTAssertEqual(lists.shape(at: [.key("move"), .key("show")]).choices, ["topic"])
    }

    func testARemoteEnvironmentOffersItsCommentedKeys() throws {
        let item = try setting("remote_environments").shape(at: [.item(0)])
        XCTAssertEqual(item.keys, ["name", "host", "username", "port", "identity_file", "forward_agent"])
    }

    func testTagsAreTheUsersOwnKeys() throws {
        let tags = try setting("topics.tags")
        XCTAssertTrue(tags.shape(at: []).userKeys)
        XCTAssertEqual(tags.shape(at: [.key("mine")]).keys, ["color"])
    }

    func testATriggerSpellsAsTheConfigDoes() throws {
        XCTAssertEqual(try KeyTrigger("shift+cmd+t").spelling, "shift+cmd+t")
        XCTAssertEqual(try KeyTrigger("cmd+comma").spelling, "cmd+comma")
        XCTAssertEqual(try KeyTrigger("ctrl+alt+left_bracket").spelling, "ctrl+alt+left_bracket")
        XCTAssertEqual(try KeyTrigger("cmd+5").spelling, "cmd+5")
        XCTAssertEqual(try KeyTrigger("alt+cmd+up").spelling, "alt+cmd+up")
    }

    func testABlockValueOfOneLineGoesUnderItsKey() {
        var text = ConfigText("")
        text.set(["pick_lists"], to: "add_session:", block: true)
        XCTAssertEqual(text.text, "pick_lists:\n  add_session:\n")
        text.set(["pick_lists"], to: "[]", block: true)
        XCTAssertEqual(text.text, "pick_lists: []\n")
    }
}
