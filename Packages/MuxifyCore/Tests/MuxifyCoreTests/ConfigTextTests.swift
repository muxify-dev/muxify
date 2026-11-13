import XCTest
@testable import MuxifyCore

final class ConfigTextTests: XCTestCase {
    private let file = """
    # my config
    sidebar:
        # mine
        agents: true   # keep
        agents_scope: all

    sessions:
        paths:
        - path: ~/work/*
          depth: 1
        - path: /root/work

    """

    func testReadsInlineAndBlockValues() {
        let text = ConfigText(file)
        XCTAssertEqual(text.value(at: ["sidebar", "agents"]), "true")
        XCTAssertEqual(text.value(at: ["sidebar", "agents_scope"]), "all")
        XCTAssertEqual(text.value(at: ["sessions", "paths"]), "- path: ~/work/*\n  depth: 1\n- path: /root/work")
        XCTAssertNil(text.value(at: ["sidebar", "panes"]))
        XCTAssertNil(text.value(at: ["ui"]))
    }

    func testSetReplacesOnlyTheValueAndKeepsComments() {
        var text = ConfigText(file)
        text.set(["sidebar", "agents"], to: "false")
        XCTAssertEqual(text.text, file.replacingOccurrences(of: "agents: true   # keep", with: "agents: false  # keep"))
    }

    func testSetReplacesABlockValue() {
        var text = ConfigText(file)
        text.set(["sessions", "paths"], to: "- path: ~/code")
        XCTAssertTrue(text.text.hasSuffix("sessions:\n    paths:\n        - path: ~/code\n"))
        text.set(["sessions", "paths"], to: "- path: ~/a\n- path: ~/b")
        XCTAssertTrue(text.text.hasSuffix("sessions:\n    paths:\n        - path: ~/a\n        - path: ~/b\n"))
        XCTAssertEqual(text.value(at: ["sessions", "paths"]), "- path: ~/a\n- path: ~/b")
    }

    func testSetAddsAMissingKeyUnderItsSectionWithTheFilesIndentation() {
        var text = ConfigText(file)
        text.set(["sidebar", "panes"], to: "true")
        XCTAssertTrue(text.text.contains("    agents_scope: all\n    panes: true\n\nsessions:"))
    }

    func testSetAddsMissingSectionsAtTheEnd() {
        var text = ConfigText(file)
        text.set(["ui", "status_line", "enabled"], to: "false")
        XCTAssertTrue(text.text.hasSuffix("- path: /root/work\n\nui:\n    status_line:\n        enabled: false\n"))
        var empty = ConfigText("")
        empty.set(["ui", "pulse"], to: "false")
        XCTAssertEqual(empty.text, "ui:\n  pulse: false\n")
    }

    func testSetRefusesAKeyUnderAFlowMapping() {
        var text = ConfigText("hints:\n  cards: { always: true }\n")
        XCTAssertFalse(text.set(["hints", "cards", "hold"], to: "false"))
        XCTAssertEqual(text.text, "hints:\n  cards: { always: true }\n")
    }

    func testRemoveTakesTheKeyAndAnEmptiedSection() {
        var text = ConfigText(file)
        text.remove(["sidebar", "agents_scope"])
        XCTAssertNil(text.value(at: ["sidebar", "agents_scope"]))
        XCTAssertEqual(text.value(at: ["sidebar", "agents"]), "true")
        text.remove(["sidebar", "agents"])
        XCTAssertNil(text.value(at: ["sidebar"]))
        XCTAssertFalse(text.text.contains("sidebar:"))
        text.remove(["sessions", "paths"])
        XCTAssertEqual(text.text, "# my config\n    # mine\n\n")
    }

    func testAHashInsideQuotesIsPartOfTheValue() {
        let text = ConfigText("ui:\n  find_colors:\n    match: '#FFD54F' # yellow\n")
        XCTAssertEqual(text.value(at: ["ui", "find_colors", "match"]), "'#FFD54F'")
    }

    func testLineRangeCountsFromOne() {
        let text = ConfigText(file)
        XCTAssertEqual(text.lineRange(of: ["sidebar", "agents"]), 4...4)
        XCTAssertEqual(text.lineRange(of: ["sessions", "paths"]), 8...11)
    }
}

final class ConfigSettingTests: XCTestCase {
    private func setting(_ id: String) -> ConfigSetting? {
        Config.settings.first { $0.id == id }
    }

    func testTheUncommentedTemplateLoadsWithNoProblems() throws {
        let config = try Config.load(path: "/template.yaml") { $0 == "/template.yaml" ? Config.templateYAML : "" }.get()
        XCTAssertEqual(config.problems, [])
    }

    func testSettingsComeFromTheTemplate() throws {
        let fontSize = try XCTUnwrap(setting("ui.font_size"))
        XCTAssertEqual(fontSize.templateValue, "12")
        XCTAssertTrue(fontSize.isDefault)
        XCTAssertTrue(fontSize.help.contains("Interface font size"))
        XCTAssertTrue(try XCTUnwrap(setting("ui.status_line.session.wrap")).isBool)
        XCTAssertNotNil(setting("sidebar.formats.window.title"))
        XCTAssertNotNil(setting("keybindings.toggle_sidebar"))
        XCTAssertNotNil(setting("keybindings.find.close"))
        XCTAssertEqual(try XCTUnwrap(setting("hints.hold_delay")).help, "seconds; 0 shows at once; false disables hold Hints")
    }

    func testListsAndMapsOfTheUsersOwnKeysAreOneSetting() throws {
        XCTAssertTrue(try XCTUnwrap(setting("sessions.paths")).isBlock)
        let palettes = try XCTUnwrap(setting("command_palettes"))
        XCTAssertTrue(palettes.isBlock)
        XCTAssertTrue(palettes.templateValue.hasPrefix("- name: Commands"))
        XCTAssertTrue(palettes.help.hasPrefix("A palette opens with its sources selected"))
        XCTAssertTrue(try XCTUnwrap(setting("sessions.aliases")).isBlock)
        XCTAssertTrue(try XCTUnwrap(setting("topics.tags")).isBlock)
        XCTAssertNil(setting("topics.tags.work.color"))
    }

    func testAValueFromAFixedListHasChoices() throws {
        XCTAssertEqual(try XCTUnwrap(setting("git_view.display")).choices, ["popup", "fullscreen"])
        XCTAssertEqual(try XCTUnwrap(setting("sidebar.window_tooltips")).choices, ["off", "truncated", "always"])
        XCTAssertEqual(try XCTUnwrap(setting("sidebar.agents_scope")).choices, ["active", "window", "all"])
        XCTAssertEqual(try XCTUnwrap(setting("ui.font_size")).choices, [])
        XCTAssertEqual(try XCTUnwrap(setting("ui.focus_marker_color")).choices, [])
        XCTAssertEqual(try XCTUnwrap(setting("keybindings.open_settings")).templateValue, "cmd+comma")
        // A Muxify keybind acts before the Terminal, so Ghostty's own cmd+, (open_config) never gets it.
        XCTAssertEqual(Keybinds.defaults.action(for: try KeyTrigger("cmd+comma"), focus: .terminal), .openSettings)
    }

    func testTheUpdateSectionIsAToggleAndAChannelPicker() throws {
        let check = try XCTUnwrap(setting("update.check"))
        XCTAssertTrue(check.isBool)
        XCTAssertTrue(check.isDefault)
        let channel = try XCTUnwrap(setting("update.channel"))
        XCTAssertEqual(channel.choices, ["stable", "tip"])
        // Unset, it is the build's own channel, so the menu shows Not set and stable is only an example.
        XCTAssertFalse(channel.isDefault)
        XCTAssertTrue(channel.help.contains("tip offers every Tip Build"))
        XCTAssertTrue(channel.help.contains("Unset, a Release reads stable and a Tip"))
    }

    func testAnExampleIsNotADefault() throws {
        XCTAssertFalse(try XCTUnwrap(setting("ghostty.config_file")).isDefault)
        XCTAssertTrue(try XCTUnwrap(setting("topics.in_play")).isDefault)
        XCTAssertTrue(try XCTUnwrap(setting("browser.vim_keys")).isDefault)
        XCTAssertTrue(try XCTUnwrap(setting("keybindings.toggle_sidebar")).isDefault)
    }
}
