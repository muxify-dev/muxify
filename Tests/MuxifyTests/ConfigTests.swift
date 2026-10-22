import AppKit
import XCTest
@testable import MuxifyCore

final class ConfigTests: XCTestCase {
    private let root = "/cfg/muxify/config.yaml"

    private func load(_ files: [String: String]) throws -> Config {
        try Config.load(path: root, fontFamilies: { ["Test Sans", "Test Mono"] }) { files[$0] }.get()
    }

    private func load(_ text: String) throws -> Config {
        try load([root: text])
    }

    private func trigger(_ string: String) -> KeyTrigger {
        try! KeyTrigger(string)
    }

    func testManualReadDefaultsAndConfigurableShortcut() throws {
        let defaults = try load("")
        XCTAssertTrue(defaults.notifications.manualRead)
        XCTAssertEqual(defaults.keybinds.action(for: trigger("cmd+shift+r")), .markRead)
        XCTAssertTrue(Config.template.contains("#   manual_read: true"))
        XCTAssertTrue(Config.template.contains("#   mark_read: cmd+shift+r"))
        let custom = try load("notifications:\n  manual_read: false\nkeybindings:\n  mark_read: ctrl+alt+r")
        XCTAssertFalse(custom.notifications.manualRead)
        XCTAssertNil(custom.keybinds.action(for: trigger("cmd+shift+r")))
        XCTAssertEqual(custom.keybinds.action(for: trigger("ctrl+alt+r")), .markRead)
        XCTAssertTrue(custom.problems.isEmpty)
        let invalid = try load("notifications:\n  manual_read: sometimes")
        XCTAssertTrue(invalid.notifications.manualRead)
        XCTAssertEqual(invalid.problems.map(\.message), ["notifications.manual_read: expected a boolean"])
        XCTAssertNil(try load("keybindings:\n  mark_read: []").keybinds.firstTrigger(for: .markRead))
    }

    func testVimKeysAreOnByDefaultAndOnlyTheLocalConfigTurnsThemOff() throws {
        XCTAssertTrue(try load("").browser.vimKeys)
        XCTAssertTrue(Config.template.contains("#   vim_keys: true"))
        let off = try load("browser:\n  vim_keys: false")
        XCTAssertFalse(off.browser.vimKeys)
        XCTAssertTrue(off.problems.isEmpty)
        let invalid = try load("browser:\n  vim_keys: maybe\n  find: true")
        XCTAssertTrue(invalid.browser.vimKeys)
        XCTAssertEqual(invalid.problems.map(\.message), ["browser.vim_keys: expected a boolean", "unknown key \"browser.find\""])
        let remote = try Config.load(path: root, isRemote: true) { _ in "browser:\n  vim_keys: false" }.get()
        XCTAssertTrue(remote.browser.vimKeys)
        XCTAssertTrue(remote.problems.isEmpty)
    }

    func testUnreadAndAllReadBindingsCanBeRemappedOrDisabled() throws {
        let defaults = try load("")
        XCTAssertEqual(defaults.keybinds.action(for: trigger("cmd+shift+u")), .markUnread)
        XCTAssertNil(defaults.keybinds.firstTrigger(for: .markAllRead))
        XCTAssertTrue(Config.template.contains("#   mark_unread: cmd+shift+u"))
        let custom = try load("keybindings:\n  mark_unread: ctrl+alt+u\n  mark_all_read: ctrl+alt+r\n  command_palette:\n    mark_unread: ctrl+u")
        XCTAssertTrue(custom.problems.isEmpty)
        XCTAssertEqual(custom.keybinds.action(for: trigger("ctrl+alt+u")), .markUnread)
        XCTAssertEqual(custom.keybinds.action(for: trigger("ctrl+alt+r")), .markAllRead)
        XCTAssertNil(custom.keybinds.action(for: trigger("cmd+shift+u")))
        XCTAssertNil(try load("keybindings:\n  mark_unread: []").keybinds.firstTrigger(for: .markUnread))
    }

    func testMuxifyConfigChoosesTheConfigFileElseTheXDGPath() {
        func path(_ environment: [String: String]) -> String { MuxifyPaths(environment: environment, home: "/Users/me").configFile.path }
        XCTAssertEqual(path([:]), "/Users/me/.config/muxify/config.yaml")
        XCTAssertEqual(path(["XDG_CONFIG_HOME": "/xdg"]), "/xdg/muxify/config.yaml")
        XCTAssertEqual(path(["XDG_CONFIG_HOME": "/xdg", "MUXIFY_CONFIG": "/tmp/testing.yaml"]), "/tmp/testing.yaml")
        XCTAssertEqual(path(["MUXIFY_CONFIG": "~/personal.yaml"]), "/Users/me/personal.yaml")
        XCTAssertEqual(path(["XDG_CONFIG_HOME": "/xdg", "MUXIFY_CONFIG": ""]), "/xdg/muxify/config.yaml", "an empty value is unset")
        XCTAssertEqual(path(["XDG_CONFIG_HOME": ""]), "/Users/me/.config/muxify/config.yaml", "an empty value is unset")
    }

    func testCommandsTakesTheSwitchersKeyAndAnOldOpenSwitcherIsAProblemThatNamesGoTo() throws {
        let config = try load("")
        XCTAssertEqual(config.commandPalettes.first?.name, "Commands")
        XCTAssertEqual(config.commandPalettes.first?.triggers, [trigger("cmd+shift+p")])
        XCTAssertEqual(config.commandPalettes.last?.name, "Go to…")
        XCTAssertEqual(config.commandPalettes.last?.triggers, [trigger("cmd+p")])
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
                                                  timestamp: 0, windowNumber: 0, context: nil,
                                                  characters: "P", charactersIgnoringModifiers: "p",
                                                  isARepeat: false, keyCode: 0x23))
        XCTAssertEqual(try XCTUnwrap(KeyTrigger(event)), trigger("cmd+shift+p"))
        XCTAssertNil(ConfigAction(rawValue: "open_switcher"))
        XCTAssertFalse(Config.template.contains("open_switcher"))
        XCTAssertEqual(config.keybinds.firstTrigger(for: .moveSession), trigger("cmd+shift+m"))
        XCTAssertTrue(Config.template.contains("#   move_session: cmd+shift+m"))
        XCTAssertEqual(config.keybinds.action(for: trigger("cmd+shift+a")), .addSessionToTopic)
        XCTAssertTrue(Config.template.contains("#   add_session_to_topic: cmd+shift+a"))
        XCTAssertTrue(config.problems.isEmpty)
        let old = try load("keybindings:\n  open_switcher: cmd+p")
        XCTAssertEqual(old.problems.map(\.message),
                       ["open_switcher is gone: the Go to… Command Palette replaces the Switcher; bind it in command_palettes"])
    }

    func testARemovedKeybindingNameIsAProblemThatNamesItsReplacement() throws {
        let config = try load("keybindings:\n  toggle_focus: cmd+e\n  move_pane: cmd+shift+t")
        XCTAssertEqual(config.problems, [ConfigProblem(path: root, line: 2, message: "toggle_focus is gone: use toggle_maximize")])
        XCTAssertNil(config.keybinds.action(for: trigger("cmd+e")), "a removed name still binds its trigger")
        XCTAssertEqual(config.keybinds.firstTrigger(for: .toggleMaximize), trigger("shift+cmd+enter"))
        XCTAssertEqual(config.keybinds.action(for: trigger("cmd+shift+t")), .movePane)
        XCTAssertFalse(Config.template.contains("toggle_focus"))
    }

    func testARemovedPaletteNameIsAProblemEvenWhereTheGlobalScopeUsesIt() throws {
        let config = try load("""
        keybindings:
          move_window: ctrl+cmd+w
          command_palette:
            move_window: alt+9
            suggest_title: alt+r
        """)
        XCTAssertEqual(config.problems, [
            ConfigProblem(path: root, line: 4, message: "move_window is gone: use choose_window"),
            ConfigProblem(path: root, line: 5, message: "suggest_title is gone: use suggest_topic_title"),
        ])
        XCTAssertEqual(config.keybinds.action(for: trigger("ctrl+cmd+w")), .moveWindow)
        XCTAssertNil(config.paletteKeybinds.action(for: trigger("alt+9")))
        XCTAssertEqual(config.paletteKeybinds.firstTrigger(for: .chooseWindow), trigger("alt+2"))
        XCTAssertEqual(config.paletteKeybinds.firstTrigger(for: .suggestTopicTitle), trigger("alt+s"))
    }

    func testLayoutAndFocusDefaults() throws {
        let config = try load("")
        let expected: [(ConfigAction, [String])] = [
            (.toggleMaximize, ["shift+cmd+enter"]),
            (.toggleMaximizeTerminal, ["alt+cmd+j"]),
            (.toggleMaximizeBrowser, ["alt+cmd+b"]),
            (.focusTerminal, ["cmd+shift+j", "ctrl+backquote", "ctrl+0", "alt+0"]),
            (.focusBrowser, ["cmd+shift+b"]),
            (.movePane, ["cmd+shift+t"]),
            (.moveWindow, []),
            (.moveSession, ["cmd+shift+m"]),
            (.toggleZen, ["shift+alt+cmd+s"]),
            (.toggleTerminal, ["cmd+j"]),
            (.toggleBrowser, ["cmd+b"]),
        ]
        for (action, spellings) in expected {
            XCTAssertEqual(config.keybinds.triggers[action] ?? [], spellings.map(trigger), action.rawValue)
        }
        XCTAssertEqual(config.paletteKeybinds.triggers[.suggestTopicTitle], [trigger("alt+s")])
        XCTAssertNil(config.keybinds.action(for: trigger("alt+cmd+t")), "the old Maximize Terminal default is still bound")
        XCTAssertEqual(config.problems, [])
    }

    func testSettleCanBeBoundAndClearedAndTheRemovedActionsAreUnknown() throws {
        let defaults = try load("")
        XCTAssertNil(defaults.keybinds.firstTrigger(for: .settleTopic))
        XCTAssertTrue(Config.template.contains("#   settle_topic: []"))
        XCTAssertFalse(Config.template.contains("show_settled"))
        XCTAssertFalse(Config.template.contains("go_to_topic"))
        let config = try load("keybindings:\n  settle_topic: cmd+shift+s")
        XCTAssertEqual(config.keybinds.action(for: trigger("cmd+shift+s")), .settleTopic)
        XCTAssertTrue(config.problems.isEmpty)
        let cleared = try load("keybindings:\n  settle_topic: []")
        XCTAssertNil(cleared.keybinds.firstTrigger(for: .settleTopic))
        XCTAssertTrue(cleared.problems.isEmpty)
        let removed = try load("keybindings:\n  go_to_topic: cmd+o\n  show_settled: ctrl+cmd+s")
        XCTAssertEqual(removed.problems.map(\.message).sorted(), ["unknown action \"go_to_topic\"", "unknown action \"show_settled\""])
        XCTAssertNil(removed.keybinds.action(for: trigger("cmd+o")))
    }

    func testMovePaneActionDefaultsAndKeyDispatch() throws {
        XCTAssertEqual(ConfigAction(rawValue: "move_pane"), .movePane)
        let config = try load("")
        let key = trigger("cmd+shift+t")
        XCTAssertEqual(config.keybinds.firstTrigger(for: .movePane), key)
        XCTAssertEqual(key.symbol, "⇧⌘T")
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
                                                  timestamp: 0, windowNumber: 0, context: nil,
                                                  characters: "T", charactersIgnoringModifiers: "t",
                                                  isARepeat: false, keyCode: 0x11))
        XCTAssertEqual(config.keybinds.action(for: try XCTUnwrap(KeyTrigger(event))), .movePane)
        XCTAssertTrue(Config.template.contains("#   move_pane: cmd+shift+t"))
        XCTAssertTrue(config.problems.isEmpty)
    }

    func testMovePaneCanBeRemappedDisabledAndClaimedByAnotherAction() throws {
        let remapped = try load("keybindings:\n  move_pane: ctrl+cmd+t")
        XCTAssertEqual(remapped.keybinds.action(for: trigger("ctrl+cmd+t")), .movePane)
        XCTAssertNil(remapped.keybinds.action(for: trigger("cmd+shift+t")))
        XCTAssertTrue(remapped.problems.isEmpty)
        let disabled = try load("keybindings:\n  move_pane: []")
        XCTAssertNil(disabled.keybinds.firstTrigger(for: .movePane))
        XCTAssertNil(disabled.keybinds.action(for: trigger("cmd+shift+t")))
        XCTAssertTrue(disabled.problems.isEmpty)
        let claimed = try load("keybindings:\n  new_topic: cmd+shift+t")
        XCTAssertEqual(claimed.keybinds.action(for: trigger("cmd+shift+t")), .newTopic)
        XCTAssertNil(claimed.keybinds.firstTrigger(for: .movePane))
        XCTAssertTrue(claimed.problems.isEmpty)
    }

    func testSidebarViewsDefaultToTrueAndAcceptBooleans() throws {
        XCTAssertEqual(try load("").sidebar, Config.Sidebar(topics: true, sessions: true))
        XCTAssertEqual(try load("").sidebar.agents, .init(nil), "the View menu decides")
        XCTAssertNil(try load("").sidebar.panes, "the View menu decides")
        let config = try load("sidebar:\n  topics: false\n  sessions: true\n  agents: false\n  panes: true")
        XCTAssertEqual(config.sidebar, Config.Sidebar(topics: false, sessions: true, agents: .init(false), panes: true))
        XCTAssertTrue(config.problems.isEmpty)
        XCTAssertTrue(Config.template.contains("#   topics: true"))
        XCTAssertTrue(Config.template.contains("#   sessions: true"))
        XCTAssertTrue(Config.template.contains("#   agents: true"))
        XCTAssertTrue(Config.template.contains("#   panes: false"))
    }

    func testSidebarWrongTypesReportProblemsAndKeepDefaults() throws {
        for value in ["1", "null", "[]", "wrong", "\"false\"", "'true'"] {
            let config = try load("sidebar:\n  topics: \(value)\n  sessions: \(value)\n  agents: \(value)\n  panes: \(value)")
            XCTAssertEqual(config.sidebar, Config.Sidebar(), value)
            XCTAssertEqual(config.problems.count, 4, value)
            XCTAssertEqual(config.problems.first?.line, 2, value)
        }
        XCTAssertEqual(try load("sidebar: []").problems.count, 1)
        XCTAssertEqual(try load("sidebar:\n  other: true").problems.count, 1)
    }

    func testAgentsScopeDefaultsToActiveAndAcceptsAll() throws {
        XCTAssertEqual(try load("").sidebar.agentsScope, .init(.active))
        XCTAssertEqual(try load("sidebar:\n  topics: false").sidebar.agentsScope, .init(.active))
        for (value, scope) in [("active", Config.Sidebar.AgentsScope.active), ("all", .all), ("'all'", .all)] {
            let config = try load("sidebar:\n  agents_scope: \(value)")
            XCTAssertEqual(config.sidebar.agentsScope, .init(scope), value)
            XCTAssertEqual(config.problems, [], value)
        }
        XCTAssertTrue(Config.template.contains("#   agents_scope: active"))
    }

    func testAgentsAndAgentsScopeTakeAValueForEachSidebarMode() throws {
        let config = try load("""
        sidebar:
          agents:
            sessions: false
          agents_scope:
            topics: all
            sessions: active
        """)
        XCTAssertEqual(config.problems, [])
        XCTAssertNil(config.sidebar.agents[.topics], "a mode left out stays with the View menu")
        XCTAssertEqual(config.sidebar.agents[.sessions], false)
        XCTAssertEqual(config.sidebar.agentsScope[.topics], .all)
        XCTAssertEqual(config.sidebar.agentsScope[.sessions], .active)
        XCTAssertTrue(Config.template.contains("#   #   sessions: false"))
    }

    func testAPerModeValueOfTheWrongTypeOrAnUnknownModeReportsAProblemAndKeepsTheOtherMode() throws {
        let config = try load("""
        sidebar:
          agents:
            topics: yes please
            sessions: true
          agents_scope:
            topics: every
            panes: all
        """)
        XCTAssertNil(config.sidebar.agents[.topics])
        XCTAssertEqual(config.sidebar.agents[.sessions], true)
        XCTAssertEqual(config.sidebar.agentsScope, .init(.active))
        XCTAssertEqual(config.problems.map(\.message), [
            "sidebar.agents.topics: expected a boolean",
            "sidebar.agents_scope.topics: expected active, window or all",
            "unknown key \"sidebar.agents_scope.panes\"",
        ])
        XCTAssertEqual(config.problems.map(\.line), [3, 6, 7])
    }

    func testAgentsScopeOtherValuesReportAProblemAndKeepActive() throws {
        for value in ["All", "every", "true", "1", "null", "[]"] {
            let config = try load("sidebar:\n  agents_scope: \(value)")
            XCTAssertEqual(config.sidebar.agentsScope, .init(.active), value)
            XCTAssertEqual(config.problems.map(\.message), ["sidebar.agents_scope: expected active, window or all"], value)
            XCTAssertEqual(config.problems.first?.line, 2, value)
        }
    }

    func testCardTitlesWrapUnlessTitlesWrapIsFalse() throws {
        XCTAssertTrue(try load("").sidebar.wrapsTitles)
        let config = try load("sidebar:\n  titles:\n    wrap: false")
        XCTAssertFalse(config.sidebar.wrapsTitles)
        XCTAssertEqual(config.problems, [])
        XCTAssertTrue(Config.template.contains("#   titles:\n#     wrap: true"))
        let bad = try load("sidebar:\n  titles:\n    wrap: 'false'\n    cut: true")
        XCTAssertTrue(bad.sidebar.wrapsTitles)
        XCTAssertEqual(bad.problems.map(\.message), ["sidebar.titles.wrap: expected a boolean", "unknown key \"sidebar.titles.cut\""])
        XCTAssertEqual(bad.problems.map(\.line), [3, 4])
        XCTAssertEqual(try load("sidebar:\n  titles: false").problems.map(\.message), ["sidebar.titles: expected a mapping"])
    }

    func testMissingOrEmptyFileGivesTheDefaults() throws {
        for config in [try load([:]), try load(""), try load("# nothing here\n\n")] {
            XCTAssertEqual(config.keybinds.action(for: trigger("cmd+s")), .toggleSidebar)
            XCTAssertEqual(config.keybinds.action(for: trigger("ctrl+cmd+s")), .toggleSidebar)
            XCTAssertEqual(config.keybinds.action(for: trigger("cmd+b")), .toggleBrowser)
            XCTAssertEqual(config.keybinds.action(for: trigger("cmd+n")), .newAppWindow)
            XCTAssertEqual(config.keybinds.action(for: trigger("ctrl+backquote")), .focusTerminal)
            XCTAssertEqual(config.keybinds.firstTrigger(for: .focusTerminal), trigger("cmd+shift+j"))
            XCTAssertNil(config.keybinds.action(for: trigger("cmd+backquote")))
            XCTAssertNil(config.keybinds.action(for: trigger("cmd+shift+backquote")))
            XCTAssertEqual(config.keybinds.action(for: trigger("cmd+shift+b")), .focusBrowser)
            XCTAssertEqual(config.keybinds.firstTrigger(for: .toggleSidebar), trigger("cmd+s"))
            XCTAssertEqual(config.headerHeight, 30)
            XCTAssertEqual(config.sidebarTypography, SidebarTypography())
            XCTAssertNil(config.ghosttyConfigFile)
            XCTAssertEqual(config.problems, [])
        }
    }

    func testHeaderHeightAcceptsWholeAndFractionalPoints() throws {
        for height in [24.0, 26, 28, 28.5, 30, 40, 128] {
            let config = try load("ui:\n  header_height: \(height)")
            XCTAssertEqual(config.headerHeight, height)
            XCTAssertEqual(config.keybinds, .defaults)
            XCTAssertEqual(config.problems, [])
        }
    }

    func testSidebarTypographyDefaultsPreserveExistingConfig() throws {
        for text in ["ui: {}", "ui:\n  sidebar: {}", "ui:\n  header_height: 26",
                     "ui:\n  sidebar:\n    font_size: 12\n    font_family: system"] {
            let config = try load(text)
            XCTAssertEqual(config.sidebarTypography, SidebarTypography(), text)
            XCTAssertEqual(config.problems, [], text)
            XCTAssertEqual(config.keybinds, .defaults, text)
        }
    }

    func testSidebarSizeAcceptsPositiveWholeAndFractionalPoints() throws {
        for size in [0.5, 8, 12, 12.5, 18, 24, 128, 1e6] {
            let config = try load("ui:\n  header_height: 26\n  sidebar:\n    font_size: \(size)")
            XCTAssertEqual(config.sidebarTypography.fontSize, size)
            XCTAssertEqual(config.sidebarTypography.fontFamily, "system")
            XCTAssertEqual(config.headerHeight, 26)
            XCTAssertEqual(config.problems, [])
        }
    }

    func testInvalidSidebarSizeFallsBackWithoutBlockingFamilyOrOtherSettings() throws {
        for value in ["0", "-1", ".inf", "-.inf", ".nan", "1e309", "wrong", "true", "false",
                      "", "null", "~", "[12]", "{size: 12}", "\"12\"", "!!str 12"] {
            let config = try load("""
            ui:
              header_height: 26
              sidebar:
                font_size: \(value)
                font_family: Test Sans
            keybindings:
              toggle_sidebar: cmd+e
            """)
            XCTAssertEqual(config.sidebarTypography, SidebarTypography(fontSize: 12, fontFamily: "Test Sans"), value)
            XCTAssertEqual(config.headerHeight, 26, value)
            XCTAssertEqual(config.keybinds.firstTrigger(for: .toggleSidebar), trigger("cmd+e"), value)
            XCTAssertEqual(config.problems, [
                ConfigProblem(path: root, line: 4, message: "ui.sidebar.font_size: expected a finite number greater than zero points"),
            ], value)
        }
    }

    func testSidebarFamilyUsesCanonicalCaseAndTrimsWhitespace() throws {
        for (value, expected) in [("system", "system"), ("\" SyStEm \"", "system"),
                                  ("Test Sans", "Test Sans"), ("\" test SANS \"", "Test Sans"),
                                  ("'TEST MONO'", "Test Mono")] {
            let config = try load("ui:\n  sidebar:\n    font_family: \(value)")
            XCTAssertEqual(config.sidebarTypography, SidebarTypography(fontSize: 12, fontFamily: expected))
            XCTAssertEqual(config.problems, [])
        }
    }

    func testSidebarFamilyRequiresARealNonemptyYamlString() throws {
        for value in ["", "null", "~", "false", "true", "123", "12.5", "[]", "{}", "\"\"", "'   '",
                      "\"Test\\nSans\"", "\"Test\\tSans\"", "!!int 12"] {
            let config = try load("ui:\n  sidebar:\n    font_family: \(value)\n    font_size: 18")
            XCTAssertEqual(config.sidebarTypography, SidebarTypography(fontSize: 18), value)
            XCTAssertEqual(config.problems, [
                ConfigProblem(path: root, line: 3, message: "ui.sidebar.font_family: expected a nonempty font family name"),
            ], value)
        }
        // Numeric/boolean-looking strings remain strings, not coerced scalars.
        for value in ["\"123\"", "\"true\"", "!!str 123"] {
            let config = try Config.load(path: root, fontFamilies: { ["123", "true"] }) {
                _ in "ui:\n  sidebar:\n    font_family: \(value)"
            }.get()
            XCTAssertTrue(["123", "true"].contains(config.sidebarTypography.fontFamily))
            XCTAssertEqual(config.problems, [])
        }
    }

    func testUnavailableSidebarFamilyFallsBackWithoutBlockingSize() throws {
        for name in ["Missing Font", "TestSans-Regular", "/fonts/Test.ttf"] {
            let config = try load("ui:\n  sidebar:\n    font_family: \" \(name) \"\n    font_size: 18")
            XCTAssertEqual(config.sidebarTypography, SidebarTypography(fontSize: 18))
            XCTAssertEqual(config.problems, [
                ConfigProblem(path: root, line: 3, message: "ui.sidebar.font_family: font family \"\(name)\" is not installed"),
            ])
        }
    }

    func testSidebarMappingAndUnknownKeysKeepValidSiblings() throws {
        for value in ["12", "[]", "null", "system"] {
            let config = try load("ui:\n  sidebar: \(value)\n  header_height: 26")
            XCTAssertEqual(config.sidebarTypography, SidebarTypography())
            XCTAssertEqual(config.headerHeight, 26)
            XCTAssertEqual(config.problems, [ConfigProblem(path: root, line: 2, message: "ui.sidebar: expected a mapping")])
        }
        let config = try load("ui:\n  sidebar:\n    font_size: 18\n    font_weight: bold\n    font_family: Test Mono")
        XCTAssertEqual(config.sidebarTypography, SidebarTypography(fontSize: 18, fontFamily: "Test Mono"))
        XCTAssertEqual(config.problems, [ConfigProblem(path: root, line: 4, message: "unknown key \"ui.sidebar.font_weight\"")])
    }

    func testSidebarReloadRetainsLastGoodOnSyntaxErrorsAndResetsRemovedValues() throws {
        var loaded = LoadedConfig()
        func update(_ text: String?) {
            loaded.update(with: Config.load(path: root, fontFamilies: { ["Test Sans"] }) { _ in text })
        }
        let custom = "ui:\n  sidebar:\n    font_size: 18\n    font_family: Test Sans"
        update(custom)
        XCTAssertEqual(loaded.config.sidebarTypography, SidebarTypography(fontSize: 18, fontFamily: "Test Sans"))
        for badYaml in ["ui: [", "ui:\n  sidebar:\n    font_size: 18\n    font_size: 24"] {
            update(badYaml)
            XCTAssertEqual(loaded.config.sidebarTypography, SidebarTypography(fontSize: 18, fontFamily: "Test Sans"))
            XCTAssertEqual(loaded.problems.count, 1)
        }
        update("ui:\n  sidebar:\n    font_size: wrong\n    font_family: Test Sans")
        XCTAssertEqual(loaded.config.sidebarTypography, SidebarTypography(fontFamily: "Test Sans"))
        update("ui:\n  sidebar:\n    font_size: 24\n    font_family: Missing")
        XCTAssertEqual(loaded.config.sidebarTypography, SidebarTypography(fontSize: 24))
        update("ui:\n  sidebar:\n    font_size: false\n    font_family: null")
        XCTAssertEqual(loaded.config.sidebarTypography, SidebarTypography())
        XCTAssertEqual(loaded.problems.count, 2)
        for removed in ["ui:\n  sidebar: {}", "ui: {}", "keybindings: {}", "", nil] {
            update(custom)
            update(removed)
            XCTAssertEqual(loaded.config.sidebarTypography, SidebarTypography())
            XCTAssertEqual(loaded.problems, [])
        }
    }

    func testNewAppWindowCanBeRemappedDisabledOrHaveItsDefaultClaimed() throws {
        let remapped = try load("keybindings:\n  new_app_window: [cmd+shift+n, ctrl+cmd+n]")
        XCTAssertNil(remapped.keybinds.action(for: trigger("cmd+n")))
        XCTAssertEqual(remapped.keybinds.action(for: trigger("cmd+shift+n")), .newAppWindow)
        XCTAssertEqual(remapped.keybinds.action(for: trigger("ctrl+cmd+n")), .newAppWindow)
        XCTAssertTrue(remapped.keybinds.suppressesDefaultAppWindowShortcut(trigger("cmd+n")))
        let disabled = try load("keybindings:\n  new_app_window: []")
        XCTAssertNil(disabled.keybinds.firstTrigger(for: .newAppWindow))
        XCTAssertTrue(disabled.keybinds.suppressesDefaultAppWindowShortcut(trigger("cmd+n")))
        let claimed = try load("keybindings:\n  toggle_browser: cmd+n")
        XCTAssertEqual(claimed.keybinds.action(for: trigger("cmd+n")), .toggleBrowser)
        XCTAssertNil(claimed.keybinds.firstTrigger(for: .newAppWindow))
        XCTAssertFalse(claimed.keybinds.suppressesDefaultAppWindowShortcut(trigger("cmd+n")))
        XCTAssertFalse(Keybinds.defaults.suppressesDefaultAppWindowShortcut(trigger("cmd+n")))
        for config in [remapped, disabled, claimed] { XCTAssertTrue(config.problems.isEmpty) }
    }

    func testInvalidHeaderHeightUsesTheDefaultAndReportsTheLine() throws {
        for value in ["23.99", "0", "-1", ".inf", "-.inf", ".nan", "1e309", "wrong", "false", "", "null", "[28]", "{height: 28}", "\"28\""] {
            let config = try load("ui:\n  header_height: \(value)\nkeybindings:\n  toggle_sidebar: cmd+e")
            XCTAssertEqual(config.headerHeight, 30, value)
            XCTAssertEqual(config.keybinds.firstTrigger(for: .toggleSidebar), trigger("cmd+e"), value)
            XCTAssertEqual(config.problems, [
                ConfigProblem(path: root, line: 2, message: "ui.header_height: expected a finite number of at least 24 points"),
            ], value)
        }
    }

    func testUIPulseTurnsEveryPulseOffAndReportsAValueThatIsNotABoolean() throws {
        XCTAssertTrue(try load("").pulse)
        XCTAssertFalse(try load("ui:\n  pulse: false").pulse)
        let bad = try load("ui:\n  pulse: sometimes")
        XCTAssertTrue(bad.pulse)
        XCTAssertEqual(bad.problems, [ConfigProblem(path: root, line: 2, message: "ui.pulse: expected a boolean")])
    }

    func testAgentColorsDefaultToGrayBlueRedOrange() throws {
        let colors = try load("").agentColors
        XCTAssertEqual(colors[.working], .single(.system(.gray)))
        XCTAssertEqual(colors[.done], .single(.system(.blue)))
        XCTAssertEqual(colors[.failed], .single(.system(.red)))
        XCTAssertEqual(colors[.blocked], .single(.system(.orange)))
    }

    func testAgentColorsTakeASystemColorNameOrAQuotedHexValue() throws {
        let config = try load("""
        ui:
          agent_colors:
            working: Teal
            done: '#3366FF'
            failed: "#a1b2c3"
        """)
        XCTAssertEqual(config.problems, [])
        XCTAssertEqual(config.agentColors[.working], .single(.system(.teal)))
        XCTAssertEqual(config.agentColors[.done], .single(.rgb(red: 0x33, green: 0x66, blue: 0xff)))
        XCTAssertEqual(config.agentColors[.failed], .single(.rgb(red: 0xa1, green: 0xb2, blue: 0xc3)))
        XCTAssertEqual(config.agentColors[.blocked], .single(.system(.orange)))
        for name in SystemColorName.allCases {
            XCTAssertEqual(try load("ui:\n  agent_colors:\n    done: \(name.rawValue)").agentColors[.done], .single(.system(name)))
        }
    }

    func testAnInvalidAgentColorKeepsTheDefaultAndAnUnknownKeyIsAProblem() throws {
        let config = try load("""
        ui:
          agent_colors:
            working: accent
            done: #3366ff
            failed: '#12345'
            blocked: 7
            idle: gray
        """)
        XCTAssertEqual(config.agentColors, AgentColors())
        let expected = "expected one of blue, orange, red, green, yellow, purple, pink, teal, gray, or a quoted '#RRGGBB', "
            + "or a mapping with light and dark"
        XCTAssertEqual(config.problems, [
            ConfigProblem(path: root, line: 3, message: "ui.agent_colors.working: " + expected),
            ConfigProblem(path: root, line: 4, message: "ui.agent_colors.done: " + expected),
            ConfigProblem(path: root, line: 5, message: "ui.agent_colors.failed: " + expected),
            ConfigProblem(path: root, line: 6, message: "ui.agent_colors.blocked: " + expected),
            ConfigProblem(path: root, line: 7, message: "unknown key \"ui.agent_colors.idle\""),
        ])
    }

    func testAnAgentColorCanBeAPairForLightAndDarkAppearance() throws {
        let config = try load("""
        ui:
          agent_colors:
            done: {light: '#3366ff', dark: Teal}
            failed:
              dark: '#a1b2c3'
              light: red
        """)
        XCTAssertEqual(config.problems, [])
        XCTAssertEqual(config.agentColors[.done], .pair(light: .rgb(red: 0x33, green: 0x66, blue: 0xff), dark: .system(.teal)))
        XCTAssertEqual(config.agentColors[.failed], .pair(light: .system(.red), dark: .rgb(red: 0xa1, green: 0xb2, blue: 0xc3)),
                       "key order does not matter")
    }

    func testABadColorPairIsAProblemWithItsLineAndKeepsTheDefault() throws {
        let config = try load("""
        ui:
          agent_colors:
            working: {light: blue}
            done: {light: blue, dark: blue, dim: gray}
            failed: {light: accent, dark: blue}
            blocked: {}
        """)
        XCTAssertEqual(config.agentColors, AgentColors(), "a pair with a problem leaves the color out")
        let expected = "expected one of blue, orange, red, green, yellow, purple, pink, teal, gray, or a quoted '#RRGGBB'"
        XCTAssertEqual(config.problems.map { "\($0.line): \($0.message)" }, [
            "3: ui.agent_colors.working: missing dark",
            "4: unknown key \"ui.agent_colors.done.dim\"",
            "5: ui.agent_colors.failed.light: " + expected,
            "6: ui.agent_colors.blocked: missing light and dark",
        ])
    }

    func testFocusTerminalCanBeRemappedToMultipleShortcutsOrDisabled() throws {
        let remapped = try load("keybindings:\n  focus_terminal: [ctrl+cmd+t, cmd+backquote]")
        XCTAssertNil(remapped.keybinds.action(for: trigger("ctrl+backquote")))
        XCTAssertEqual(remapped.keybinds.action(for: trigger("ctrl+cmd+t")), .focusTerminal)
        XCTAssertEqual(remapped.keybinds.action(for: trigger("cmd+backquote")), .focusTerminal)
        XCTAssertEqual(remapped.keybinds.firstTrigger(for: .focusTerminal), trigger("ctrl+cmd+t"))

        let disabled = try load("keybindings:\n  focus_terminal: []")
        XCTAssertNil(disabled.keybinds.firstTrigger(for: .focusTerminal))
        XCTAssertNil(disabled.keybinds.action(for: trigger("ctrl+backquote")))
        XCTAssertNil(disabled.keybinds.action(for: trigger("cmd+backquote")))
        for config in [remapped, disabled] {
            XCTAssertEqual(config.keybinds.action(for: trigger("cmd+b")), .toggleBrowser)
            XCTAssertEqual(config.problems, [])
        }
    }

    func testFocusTerminalDefaultCanBeClaimedByAnotherAction() throws {
        let config = try load("keybindings:\n  toggle_browser: ctrl+backquote")
        XCTAssertEqual(config.keybinds.action(for: trigger("ctrl+backquote")), .toggleBrowser)
        XCTAssertEqual(config.keybinds.triggers[.focusTerminal], [trigger("cmd+shift+j"), trigger("ctrl+0"), trigger("alt+0")])
        XCTAssertEqual(config.problems, [])
    }

    func testFocusTerminalReportsShortcutConflicts() throws {
        let config = try load("""
        keybindings:
          toggle_browser: ctrl+cmd+t
          focus_terminal: [ctrl+cmd+t, ctrl+backquote]
        """)
        XCTAssertEqual(config.keybinds.action(for: trigger("ctrl+cmd+t")), .toggleBrowser)
        XCTAssertEqual(config.keybinds.firstTrigger(for: .focusTerminal), trigger("ctrl+backquote"))
        XCTAssertEqual(config.problems, [
            ConfigProblem(path: root, line: 3, message: "ctrl+cmd+t is already bound to toggle_browser"),
        ])
    }

    func testUISectionRequiresAMappingAndReportsUnknownKeys() throws {
        XCTAssertEqual(try load("ui: 28").problems, [
            ConfigProblem(path: root, line: 1, message: "ui: expected a mapping"),
        ])
        let config = try load("ui:\n  header_height: 26\n  header_width: 80")
        XCTAssertEqual(config.headerHeight, 26)
        XCTAssertEqual(config.problems, [
            ConfigProblem(path: root, line: 3, message: "unknown key \"ui.header_width\""),
        ])
    }

    func testHeaderHeightReloadAndSyntaxErrorRecovery() throws {
        var loaded = LoadedConfig()
        loaded.update(with: Config.load(path: root) { _ in "ui:\n  header_height: 26" })
        XCTAssertEqual(loaded.config.headerHeight, 26)
        loaded.update(with: Config.load(path: root) { _ in "ui: [" })
        XCTAssertEqual(loaded.config.headerHeight, 26)
        XCTAssertEqual(loaded.problems.count, 1)
        loaded.update(with: Config.load(path: root) { _ in "ui:\n  header_height: 32" })
        XCTAssertEqual(loaded.config.headerHeight, 32)
        XCTAssertEqual(loaded.problems, [])
        loaded.update(with: Config.load(path: root) { _ in "keybindings: {}" })
        XCTAssertEqual(loaded.config.headerHeight, 30)
        loaded.update(with: Config.load(path: root) { _ in "ui:\n  header_height: 26" })
        loaded.update(with: Config.load(path: root) { _ in nil })
        XCTAssertEqual(loaded.config.headerHeight, 30)
    }

    func testNumberedWindowKeybindingsDefaultToCommandOneThroughNine() throws {
        let actions: [ConfigAction] = [
            .selectWindow1, .selectWindow2, .selectWindow3,
            .selectWindow4, .selectWindow5, .selectWindow6,
            .selectWindow7, .selectWindow8, .selectWindow9,
        ]
        for config in [try load([:]), try load("")] {
            for (offset, action) in actions.enumerated() {
                let key = trigger("cmd+\(offset + 1)")
                XCTAssertEqual(config.keybinds.action(for: key), action)
                XCTAssertEqual(config.keybinds.firstTrigger(for: action), key)
            }
        }
    }

    func testNumberedWindowKeybindingsCanBeRemappedOrDisabled() throws {
        let config = try load("""
        keybindings:
          select_window_1: [alt+1, ctrl+cmd+digit_1]
          select_window_2: []
        """)
        XCTAssertNil(config.keybinds.action(for: trigger("cmd+1")))
        XCTAssertNil(config.keybinds.action(for: trigger("cmd+2")))
        XCTAssertEqual(config.keybinds.action(for: trigger("alt+1")), .selectWindow1)
        XCTAssertEqual(config.keybinds.action(for: trigger("ctrl+cmd+1")), .selectWindow1)
        XCTAssertEqual(config.keybinds.firstTrigger(for: .selectWindow1), trigger("alt+1"))
        XCTAssertNil(config.keybinds.firstTrigger(for: .selectWindow2))
        XCTAssertEqual(config.keybinds.action(for: trigger("cmd+3")), .selectWindow3)
        XCTAssertEqual(config.problems, [])
    }

    func testNumberedWindowDefaultsCanBeClaimedByAnotherAction() throws {
        let config = try load("""
        keybindings:
          toggle_browser: cmd+1
        """)
        XCTAssertEqual(config.keybinds.action(for: trigger("cmd+1")), .toggleBrowser)
        XCTAssertNil(config.keybinds.firstTrigger(for: .selectWindow1))
        XCTAssertEqual(config.keybinds.action(for: trigger("cmd+2")), .selectWindow2)
        XCTAssertEqual(config.problems, [])
    }

    func testNumberedWindowKeybindingsReportConflicts() throws {
        let config = try load("""
        keybindings:
          select_window_1: cmd+e
          select_window_2: cmd+e
        """)
        XCTAssertEqual(config.keybinds.action(for: trigger("cmd+e")), .selectWindow1)
        XCTAssertNil(config.keybinds.firstTrigger(for: .selectWindow2))
        XCTAssertEqual(config.problems, [
            ConfigProblem(path: root, line: 3, message: "cmd+e is already bound to select_window_1"),
        ])
    }

    func testNextAndPreviousStepActionsAreUnboundByDefault() throws {
        let config = try load([:])
        for action in [ConfigAction.selectNextWindow, .selectPrevWindow, .selectNextTopicWindow, .selectPrevTopicWindow,
                       .selectNextSession, .selectPrevSession, .selectNextTopic, .selectPrevTopic] {
            XCTAssertEqual(config.keybinds.triggers[action], [])
            XCTAssertNil(config.keybinds.firstTrigger(for: action))
        }
        XCTAssertNil(config.keybinds.action(for: trigger("ctrl+cmd+right")))
        XCTAssertNil(config.keybinds.action(for: trigger("ctrl+cmd+left")))
        XCTAssertEqual(config.problems, [])
    }

    func testNextAndPreviousWindowActionsAcceptBindings() throws {
        let config = try load("""
        keybindings:
          select_next_window: [ctrl+cmd+right, cmd+shift+right_bracket]
          select_prev_window: ctrl+cmd+left
        """)
        XCTAssertEqual(config.keybinds.action(for: trigger("ctrl+cmd+right")), .selectNextWindow)
        XCTAssertEqual(config.keybinds.action(for: trigger("cmd+shift+right_bracket")), .selectNextWindow)
        XCTAssertEqual(config.keybinds.action(for: trigger("ctrl+cmd+left")), .selectPrevWindow)
        XCTAssertEqual(config.keybinds.firstTrigger(for: .selectNextWindow), trigger("ctrl+cmd+right"))
        XCTAssertEqual(config.keybinds.firstTrigger(for: .selectPrevWindow), trigger("ctrl+cmd+left"))
        XCTAssertEqual(config.keybinds.action(for: trigger("cmd+1")), .selectWindow1)
        XCTAssertEqual(config.problems, [])
    }

    func testNextAndPreviousSessionAndTopicActionsAcceptBindings() throws {
        let config = try load("""
        keybindings:
          select_next_session: ctrl+cmd+down
          select_prev_session: ctrl+cmd+up
          select_next_topic: [ctrl+alt+cmd+down, cmd+1]
          select_prev_topic: ctrl+alt+cmd+up
        """)
        XCTAssertEqual(config.keybinds.action(for: trigger("ctrl+cmd+down")), .selectNextSession)
        XCTAssertEqual(config.keybinds.action(for: trigger("ctrl+cmd+up")), .selectPrevSession)
        XCTAssertEqual(config.keybinds.action(for: trigger("ctrl+alt+cmd+down")), .selectNextTopic)
        XCTAssertEqual(config.keybinds.action(for: trigger("cmd+1")), .selectNextTopic)
        XCTAssertEqual(config.keybinds.action(for: trigger("ctrl+alt+cmd+up")), .selectPrevTopic)
        XCTAssertNil(config.keybinds.firstTrigger(for: .selectWindow1))
        XCTAssertEqual(config.problems, [])
    }

    func testNextAndPreviousWindowActionsCanBeExplicitlyDisabled() throws {
        let config = try load("""
        keybindings:
          select_next_window: []
          select_prev_window: []
        """)
        XCTAssertEqual(config.keybinds, Keybinds.defaults)
        XCTAssertEqual(config.problems, [])
    }

    func testNextWindowActionCanClaimANumberedWindowDefault() throws {
        let config = try load("""
        keybindings:
          select_next_window: cmd+1
        """)
        XCTAssertEqual(config.keybinds.action(for: trigger("cmd+1")), .selectNextWindow)
        XCTAssertNil(config.keybinds.firstTrigger(for: .selectWindow1))
        XCTAssertEqual(config.keybinds.action(for: trigger("cmd+2")), .selectWindow2)
        XCTAssertEqual(config.problems, [])
    }

    func testNamingAnActionReplacesItsDefaults() throws {
        let config = try load("""
        keybindings:
          toggle_sidebar: ctrl+cmd+s
        """)
        XCTAssertNil(config.keybinds.action(for: trigger("cmd+s")))
        XCTAssertEqual(config.keybinds.action(for: trigger("ctrl+cmd+s")), .toggleSidebar)
        XCTAssertEqual(config.keybinds.firstTrigger(for: .toggleSidebar), trigger("ctrl+cmd+s"))
        XCTAssertEqual(config.keybinds.action(for: trigger("cmd+b")), .toggleBrowser)
        XCTAssertEqual(config.problems, [])
    }

    func testAListBindsEveryTriggerAndTheFirstIsShown() throws {
        let config = try load("""
        keybindings:
          toggle_browser: [cmd+e, ctrl+cmd+b]
        """)
        XCTAssertEqual(config.keybinds.action(for: trigger("cmd+e")), .toggleBrowser)
        XCTAssertEqual(config.keybinds.action(for: trigger("ctrl+cmd+b")), .toggleBrowser)
        XCTAssertNil(config.keybinds.action(for: trigger("cmd+b")))
        XCTAssertEqual(config.keybinds.firstTrigger(for: .toggleBrowser), trigger("cmd+e"))
    }

    func testAnEmptyListLeavesTheActionWithNoKeybinding() throws {
        let config = try load("""
        keybindings:
          toggle_browser: []
        """)
        XCTAssertNil(config.keybinds.firstTrigger(for: .toggleBrowser))
        XCTAssertNil(config.keybinds.action(for: trigger("cmd+b")))
        XCTAssertEqual(config.keybinds.firstTrigger(for: .toggleSidebar), trigger("cmd+s"))
        XCTAssertEqual(config.problems, [])
    }

    func testATriggerListedForOneActionIsTakenFromTheDefaultsOfAnother() throws {
        let config = try load("""
        keybindings:
          toggle_browser: cmd+s
        """)
        XCTAssertEqual(config.keybinds.action(for: trigger("cmd+s")), .toggleBrowser)
        XCTAssertEqual(config.keybinds.firstTrigger(for: .toggleSidebar), trigger("ctrl+cmd+s"))
        XCTAssertNil(config.keybinds.action(for: trigger("cmd+b")))
        XCTAssertEqual(config.problems, [])
    }

    func testTheSameTriggerUnderTwoActionsStaysWithTheFirst() throws {
        let config = try load("""
        keybindings:
          toggle_browser: cmd+e
          toggle_sidebar:
            - cmd+e
            - cmd+j
        """)
        XCTAssertEqual(config.keybinds.action(for: trigger("cmd+e")), .toggleBrowser)
        XCTAssertEqual(config.keybinds.firstTrigger(for: .toggleSidebar), trigger("cmd+j"))
        XCTAssertEqual(config.problems, [
            ConfigProblem(path: root, line: 4, message: "cmd+e is already bound to toggle_browser"),
        ])
    }

    func testProblemLinesCountFromOne() throws {
        XCTAssertEqual(try load("nope: 1").problems, [
            ConfigProblem(path: root, line: 1, message: "unknown section \"nope\""),
        ])
    }

    func testValuesThatCannotApplyAreProblemsAndTheRestApplies() throws {
        let config = try load("""
        fonts:
          size: 12
        ghostty:
          theme: dark
        # comment
        keybindings:
          toggle_everything: cmd+e
          toggle_sidebar: hyper+s
          toggle_browser:
            - cmd+j
            - [cmd+k]
            - meta+b
        """)
        XCTAssertEqual(config.problems, [
            ConfigProblem(path: root, line: 1, message: "unknown section \"fonts\""),
            ConfigProblem(path: root, line: 4, message: "unknown key \"ghostty.theme\""),
            ConfigProblem(path: root, line: 7, message: "unknown action \"toggle_everything\""),
            ConfigProblem(path: root, line: 8, message: "bad trigger \"hyper+s\": unknown modifier \"hyper\""),
            ConfigProblem(path: root, line: 11, message: "toggle_browser: expected a trigger or a list of triggers"),
            ConfigProblem(path: root, line: 12, message: "bad trigger \"meta+b\": unknown modifier \"meta\""),
        ])
        XCTAssertNil(config.keybinds.action(for: trigger("cmd+e")))
        XCTAssertEqual(config.keybinds.firstTrigger(for: .toggleSidebar), trigger("cmd+s"))
        XCTAssertEqual(config.keybinds.triggers[.toggleBrowser], [trigger("cmd+j")])
    }

    func testValuesOfTheWrongTypeAreProblems() throws {
        XCTAssertEqual(try load("keybindings: cmd+s").problems, [
            ConfigProblem(path: root, line: 1, message: "keybindings: expected a mapping"),
        ])
        XCTAssertEqual(try load("- keybindings").problems, [
            ConfigProblem(path: root, line: 1, message: "the Config: expected a mapping"),
        ])
        let config = try load("""
        ghostty:
          config_file: [a, b]
        keybindings:
          toggle_sidebar:
          toggle_browser: {cmd: b}
        """)
        XCTAssertEqual(config.problems, [
            ConfigProblem(path: root, line: 2, message: "ghostty.config_file: expected a path"),
            ConfigProblem(path: root, line: 4, message: "toggle_sidebar: expected a trigger or a list of triggers"),
            ConfigProblem(path: root, line: 5, message: "toggle_browser: expected a trigger or a list of triggers"),
        ])
        XCTAssertNil(config.ghosttyConfigFile)
        XCTAssertEqual(config.keybinds, Keybinds.defaults)
    }

    func testGhosttyConfigFileResolvesAgainstTheConfigAndExpandsHome() throws {
        let relative = try load([
            root: "ghostty:\n  config_file: ../ghostty/personal",
            "/cfg/ghostty/personal": "",
        ])
        XCTAssertEqual(relative.ghosttyConfigFile, "/cfg/ghostty/personal")
        XCTAssertEqual(relative.problems, [])

        let home = NSHomeDirectory()
        let fromHome = try load([
            root: "ghostty:\n  config_file: ~/ghostty/work",
            "\(home)/ghostty/work": "",
        ])
        XCTAssertEqual(fromHome.ghosttyConfigFile, "\(home)/ghostty/work")
        XCTAssertEqual(fromHome.problems, [])
    }

    func testAMissingGhosttyConfigFileIsAProblem() throws {
        let config = try load("ghostty:\n  config_file: /nowhere")
        XCTAssertEqual(config.ghosttyConfigFile, "/nowhere")
        XCTAssertEqual(config.problems, [
            ConfigProblem(path: root, line: 2, message: "ghostty.config_file /nowhere: not found"),
        ])
    }

    func testASyntaxErrorFailsTheWholeRead() {
        let badIndent = Config.load(path: root) { _ in "keybindings:\n  toggle_sidebar: cmd+s\n toggle_browser: cmd+b\n" }
        XCTAssertThrowsError(try badIndent.get()) { error in
            XCTAssertEqual((error as? ConfigSyntaxError)?.problem.line, 3)
            XCTAssertEqual((error as? ConfigSyntaxError)?.problem.path, root)
        }
        let duplicate = Config.load(path: root) { _ in "keybindings:\n  toggle_sidebar: cmd+s\n  toggle_sidebar: cmd+j\n" }
        XCTAssertThrowsError(try duplicate.get()) { error in
            XCTAssertEqual((error as? ConfigSyntaxError)?.problem.message, "duplicate key toggle_sidebar")
        }
    }

    func testASyntaxErrorKeepsTheLastGoodConfigAndShowsOnlyItself() throws {
        var loaded = LoadedConfig()
        loaded.update(with: Config.load(path: root) { _ in "keybindings:\n  toggle_browser: cmd+e\nnope: 1" })
        let good = loaded.config
        XCTAssertEqual(good.keybinds.firstTrigger(for: .toggleBrowser), trigger("cmd+e"))
        XCTAssertEqual(loaded.problems.map(\.message), ["unknown section \"nope\""])

        let syntaxError = Config.load(path: root) { _ in "keybindings: [" }
        loaded.update(with: syntaxError)
        XCTAssertEqual(loaded.config, good)
        XCTAssertThrowsError(try syntaxError.get()) { error in
            XCTAssertEqual(loaded.problems, [(error as! ConfigSyntaxError).problem])
        }

        loaded.update(with: Config.load(path: root) { _ in nil })
        XCTAssertEqual(loaded.config.keybinds, Keybinds.defaults)
        XCTAssertEqual(loaded.problems, [])
    }

    func testTriggersParseGhosttyNames() throws {
        XCTAssertEqual(try KeyTrigger("cmd+shift+left_bracket"), KeyTrigger(modifiers: [.command, .shift], key: .character("[")))
        XCTAssertEqual(try KeyTrigger("ctrl+cmd+s"), KeyTrigger(modifiers: [.control, .command], key: .character("s")))
        XCTAssertEqual(try KeyTrigger("control+command+S"), try KeyTrigger("ctrl+cmd+s"))
        XCTAssertEqual(try KeyTrigger("digit_1"), KeyTrigger(modifiers: [], key: .character("1")))
        XCTAssertEqual(try KeyTrigger("opt+left"), KeyTrigger(modifiers: .option, key: .special(.left)))
        XCTAssertEqual(try KeyTrigger("cmd+shift+left_bracket").symbol, "⇧⌘[")
        XCTAssertEqual(try KeyTrigger("ctrl+cmd+s").symbol, "⌃⌘S")
        XCTAssertThrowsError(try KeyTrigger("cmd+"))
        XCTAssertThrowsError(try KeyTrigger("cmd+nope"))
        XCTAssertThrowsError(try KeyTrigger("meta+s"))
    }

    func testTriggersNameTheKeyThatTypesTheCharacterWithCommandOnTheLayout() throws {
        let russian = try XCTUnwrap(KeyboardLayout(inputSourceID: "com.apple.keylayout.Russian"))
        let abc = try XCTUnwrap(KeyboardLayout(inputSourceID: "com.apple.keylayout.ABC"))
        let keyP: UInt16 = 0x23, keyS: UInt16 = 0x01, key1: UInt16 = 0x12
        func pressed(_ flags: NSEvent.ModifierFlags, _ keyCode: UInt16, _ layout: KeyboardLayout) throws -> KeyTrigger {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                                      windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                                      isARepeat: false, keyCode: keyCode))
            return try XCTUnwrap(KeyTrigger(event, layout: layout))
        }
        XCTAssertEqual(try pressed(.command, keyP, russian), trigger("cmd+p"), "the key labelled P types з, and ⌘ types p")
        XCTAssertEqual(try pressed([.command, .shift], keyP, russian), trigger("cmd+shift+p"))
        XCTAssertEqual(try pressed([.control, .command], keyS, russian), trigger("ctrl+cmd+s"))
        XCTAssertEqual(try pressed([.command, .shift], key1, russian), trigger("cmd+shift+1"), "⇧ types !, which is not the key's name")
        XCTAssertEqual(try pressed(.command, keyP, abc), trigger("cmd+p"))
        XCTAssertEqual(try pressed([.command, .shift], key1, abc), trigger("cmd+shift+1"))
    }

    func testTheTemplateIsAValidConfigThatChangesNothing() throws {
        let config = try load(Config.template)
        XCTAssertEqual(config.keybinds, Keybinds.defaults)
        XCTAssertEqual(config.headerHeight, 30)
        XCTAssertEqual(config.sidebarTypography, SidebarTypography())
        XCTAssertNil(config.ghosttyConfigFile)
        XCTAssertEqual(config.problems, [])
    }

    func testTheHeaderHeightTheTemplateShowsIsTheDefault() throws {
        let shown = Config.template.split(separator: "\n").filter { line in
            line.hasPrefix("# ui:") || line.hasPrefix("#   header_height:")
        }.map { $0.dropFirst(2) }
        XCTAssertEqual(shown.count, 2)
        let config = try load(shown.joined(separator: "\n"))
        XCTAssertEqual(config.headerHeight, Config().headerHeight)
        XCTAssertEqual(config.problems, [])
    }

    func testTopicTitleCommandsAcceptOneCommandAnOrderedListAndAnEmptyList() throws {
        XCTAssertEqual(try load("topics:\n  title_command_fallbacks: claude -p").topics.titleCommandFallbacks, ["claude -p"])
        XCTAssertEqual(try load("topics:\n  title_command_fallbacks: [first, second]").topics.titleCommandFallbacks, ["first", "second"])
        XCTAssertEqual(try load("topics:\n  title_command_fallbacks: []").topics.titleCommandFallbacks, [])
    }

    func testTopicTitleCommandsReportBadShapesAtTheirLinesAndKeepValidItems() throws {
        let list = try load("""
        topics:
          title_command_fallbacks:
            - first
            - ""
            - 42
            - second
        """)
        XCTAssertEqual(list.topics.titleCommandFallbacks, ["first", "second"])
        XCTAssertEqual(list.problems, [
            ConfigProblem(path: root, line: 4, message: "topics.title_command_fallbacks: expected a nonempty string"),
            ConfigProblem(path: root, line: 5, message: "topics.title_command_fallbacks: expected a nonempty string"),
        ])
        for text in ["topics:\n  title_command_fallbacks: ''", "topics:\n  title_command_fallbacks: {}", "topics:\n  title_command_fallbacks: 42"] {
            let config = try load(text)
            XCTAssertTrue(config.topics.titleCommandFallbacks.isEmpty)
            XCTAssertEqual(config.problems.first?.line, 2)
        }
    }

    func testTopicInsertPosition() throws {
        XCTAssertEqual(try load("").topics.insertPosition, .bottom)
        XCTAssertEqual(try load("topics:\n  insert_position: top").topics.insertPosition, .top)
        XCTAssertEqual(try load("topics:\n  insert_position: bottom").topics.insertPosition, .bottom)
        for value in ["middle", "true", "1", "[]"] {
            let bad = try load("topics:\n  insert_position: " + value)
            XCTAssertEqual(bad.topics.insertPosition, .bottom)
            XCTAssertEqual(bad.problems, [ConfigProblem(path: root, line: 2, message: "topics.insert_position: expected bottom or top")])
        }
    }

    func testTopicSessionOrderTakesOldestOrNewestFirstAndReportsAnythingElse() throws {
        XCTAssertEqual(try load("").topics.sessionOrder, .oldestFirst)
        XCTAssertEqual(try load("topics:\n  session_order: newest_first").topics.sessionOrder, .newestFirst)
        let bad = try load("topics:\n  session_order: manual")
        XCTAssertEqual(bad.topics.sessionOrder, .oldestFirst)
        XCTAssertEqual(bad.problems, [ConfigProblem(path: root, line: 2, message: "topics.session_order: expected oldest_first or newest_first")])
    }

    func testTemplateShowsTopicTitleCommandExamplesWithoutEnablingThem() throws {
        XCTAssertTrue(Config.template.contains("#   title_command_fallbacks:"))
        XCTAssertTrue(Config.template.contains("#     - claude -p --model haiku"))
        XCTAssertTrue(try load(Config.template).topics.titleCommandFallbacks.isEmpty)
    }

    func testTheSidebarTypographyTheTemplateShowsIsTheDefault() throws {
        let shown = Config.template.split(separator: "\n").filter { line in
            line.hasPrefix("# ui:") || line.hasPrefix("#   sidebar:") || line.hasPrefix("#     font_")
        }.map { $0.dropFirst(2) }
        XCTAssertEqual(shown.count, 4)
        let config = try load(shown.joined(separator: "\n"))
        XCTAssertEqual(config.sidebarTypography, Config().sidebarTypography)
        XCTAssertEqual(config.problems, [])
    }

    func testTheKeybindingsTheTemplateShowsAreTheDefaults() throws {
        let shown = Config.template.split(separator: "\n").filter { line in
            ConfigAction.allCases.contains { line.hasPrefix("#   \($0.rawValue):") }
        }.map { $0.dropFirst() }
        XCTAssertEqual(shown.count, ConfigAction.allCases.count)
        let config = try load("keybindings:\n" + shown.joined(separator: "\n"))
        XCTAssertEqual(config.keybinds, Keybinds.defaults)
        XCTAssertEqual(config.problems, [])
    }
}

final class ConfigFileSetTests: XCTestCase {
    func testIncludesResolveAgainstTheIncludingFile() {
        let files = [
            "/g/config": """
            font-size = 12
            config-file = keys/more
            """,
            "/g/keys/more": "config-file = \"../last\"",
            "/g/last": "",
        ]
        XCTAssertEqual(ConfigFileSet(root: "/g/config") { files[$0] }.files, ["/g/config", "/g/keys/more", "/g/last"])
    }

    func testMissingIncludesAreStillWatched() {
        let files = ["/g/config": "config-file = ?optional\nconfig-file = required"]
        XCTAssertEqual(ConfigFileSet(root: "/g/config") { files[$0] }.files, ["/g/config", "/g/optional", "/g/required"])
    }

    func testAnIncludeCycleIsReadOnce() {
        let files = ["/g/config": "config-file = other", "/g/other": "config-file = config"]
        var reads: [String] = []
        let set = ConfigFileSet(root: "/g/config") { reads.append($0); return files[$0] }
        XCTAssertEqual(set.files, ["/g/config", "/g/other"])
        XCTAssertEqual(reads, ["/g/config", "/g/other"])
    }
}
