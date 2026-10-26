import XCTest
@testable import MuxifyCore

final class CommandPaletteConfigTests: XCTestCase {
    private let root = "/cfg/muxify/config.yaml"

    private func load(_ text: String, isRemote: Bool = false) throws -> Config {
        try Config.load(path: root, isRemote: isRemote, fontFamilies: { [] }) { $0 == self.root ? text : nil }.get()
    }

    private func trigger(_ string: String) -> KeyTrigger {
        try! KeyTrigger(string)
    }

    func testDefaultsAreCommandsAndGoToPalettesAndThePaletteKeys() throws {
        let config = try load("")
        XCTAssertEqual(config.commandPalettes, [
            CommandPaletteConfig(name: "Commands", triggers: [trigger("cmd+shift+p")], sources: [.commands]),
            CommandPaletteConfig(name: "Go to…", triggers: [trigger("cmd+p")], sources: [.topics, .sessions]),
        ])
        XCTAssertEqual(config.commandPalettes[0].placeholder, "Search Commands")
        XCTAssertEqual(config.commandPalettes[1].placeholder, "Go to…")
        let keys = config.paletteKeybinds
        XCTAssertEqual(keys.action(for: trigger("enter")), .jumpTo)
        XCTAssertEqual(keys.action(for: trigger("cmd+enter")), .newSession)
        XCTAssertEqual(keys.action(for: trigger("down")), .selectNext)
        XCTAssertEqual(keys.action(for: trigger("ctrl+j")), .selectNext)
        XCTAssertEqual(keys.action(for: trigger("up")), .selectPrev)
        XCTAssertEqual(keys.action(for: trigger("ctrl+k")), .selectPrev)
        XCTAssertEqual(keys.action(for: trigger("cmd+k")), .showActions)
        XCTAssertEqual(keys.action(for: trigger("cmd+c")), .copyFolder)
        XCTAssertEqual(keys.action(for: trigger("cmd+shift+c")), .copyTmuxTarget)
        XCTAssertEqual(keys.action(for: trigger("ctrl+y")), .pasteFolder)
        XCTAssertEqual(keys.action(for: trigger("ctrl+s")), .snoozeTopic)
        XCTAssertEqual(keys.action(for: trigger("alt+1")), .choosePane)
        XCTAssertEqual(keys.action(for: trigger("alt+2")), .chooseWindow)
        XCTAssertEqual(keys.action(for: trigger("alt+3")), .chooseSession)
        XCTAssertEqual(keys.action(for: trigger("alt+t")), .toggleIncludeTab)
        XCTAssertEqual(keys.action(for: trigger("alt+w")), .toggleNewWorktree)
        XCTAssertEqual(config.sessionRoots, [])
        XCTAssertEqual(config.problems, [])
    }

    func testTheExampleConfig() throws {
        let config = try load("""
        keybindings:
          command_palette:
            copy_folder: cmd+c
            jump_to: enter

        sessions:
          paths:
            - path: ~/sessionPaths
              depth: 1
            - path: ~/.dotfiles

        command_palettes:
          - name: "Sessions"
            keybinding: "cmd+p"
            sources: [sessions, windows]
          - name: "Agents"
            keybinding: "cmd+shift+o"
            sources: [agents]
        """)
        XCTAssertEqual(config.problems, [])
        XCTAssertEqual(config.sessionRoots, [SessionPathRoot(path: "~/sessionPaths", depth: 1), SessionPathRoot(path: "~/.dotfiles")])
        XCTAssertEqual(config.commandPalettes, [
            CommandPaletteConfig(name: "Sessions", triggers: [trigger("cmd+p")], sources: [.sessions, .windows]),
            CommandPaletteConfig(name: "Agents", triggers: [trigger("cmd+shift+o")], sources: [.agents]),
        ])
        XCTAssertEqual(config.commandPalettes[0].placeholder, "Search Sessions")
        XCTAssertEqual(config.paletteKeybinds, .defaults)
        XCTAssertEqual(config.keybinds, .defaults)
    }

    func testCommandsCanBeMixedWithOtherSources() throws {
        let config = try load("""
        command_palettes:
          - name: Everything
            keybinding: cmd+p
            sources: [commands, topics, commands]
        """)
        let palette = try XCTUnwrap(config.commandPalettes.first)
        XCTAssertEqual(palette.sources, [.commands, .topics])
        XCTAssertEqual(palette.allSources, [.commands, .topics, .sessions, .windows, .agents])
        XCTAssertEqual(config.problems, [])
    }

    func testAPaletteCanRankEverySourceInOneListWithItsOwnTiebreaks() throws {
        let config = try load("""
        command_palettes:
          - name: Go to…
            sources: [topics, sessions]
            order: ranked
            tiebreak: [visit, open, visit]
          - name: Commands
            sources: [commands]
          - name: Broken order
            sources: [agents]
            order: mixed
          - name: Broken tiebreak
            sources: [agents]
            tiebreak: [visit, frecency]
        """)
        XCTAssertEqual(config.commandPalettes.map(\.order), [.ranked, .grouped])
        XCTAssertEqual(config.commandPalettes.map(\.rules.tiebreak), [[.visit, .open], PaletteTiebreak.standard])
        XCTAssertEqual(config.problems, [
            ConfigProblem(path: root, line: 10, message: "Command Palette order: expected grouped or ranked"),
            ConfigProblem(path: root, line: 13, message: "Command Palette tiebreak: expected open, running, visit, activity or length"),
        ])
    }

    func testAPaletteShowsOnlyTheKindsItsShowNamesAndABadShowDropsThePalette() throws {
        let config = try load("""
        command_palettes:
          - name: Go to…
            sources: [topics, sessions]
            show: [topic, session, session-path, worktree, session]
          - name: Everything
            sources: [topics, sessions]
          - name: One kind
            sources: [agents]
            show: agent
          - name: Typo
            sources: [sessions]
            show: [sesion]
          - name: Nothing
            sources: [sessions]
            show: []
        """)
        XCTAssertEqual(config.commandPalettes.map(\.name), ["Go to…", "Everything", "One kind"])
        XCTAssertEqual(config.commandPalettes.map(\.rules.show), [[.topic, .session, .sessionPath, .worktree], RowKind.all, [.agent]])
        let every = "topic, snoozed, settled, session, topic-session, session-path, worktree, window, agent, command or tag"
        XCTAssertEqual(config.problems, [
            ConfigProblem(path: root, line: 12, message: "Command Palette show: expected " + every),
            ConfigProblem(path: root, line: 15, message: "Command Palette show: expected a list of " + every),
        ])
    }

    func testPickListsGiveAnActionListItsShowAndTiebreak() throws {
        let config = try load("""
        pick_lists:
          add_session:
            show: [session-path]
            tiebreak: [visit, length]
          move_session:
            tiebreak: activity
        """)
        XCTAssertEqual(config.problems, [])
        XCTAssertEqual(config.rules(for: .addSession), PickRules(show: [.sessionPath], tiebreak: [.visit, .length]))
        XCTAssertEqual(config.rules(for: .moveSession), PickRules(tiebreak: [.activity]))
        XCTAssertEqual(config.rules(for: .move), .standard, "a list with no entry keeps every kind and the standard tiebreak")
        XCTAssertEqual(try load("").rules(for: .addSession), .standard)
    }

    func testABadPickListEntryIsAProblemAndOnlyThatListKeepsItsStandardRules() throws {
        let config = try load("""
        pick_lists:
          add_sesion:
            show: [session-path]
          add_session:
            show: [session-path, window]
          move:
            show: [topic]
            order: ranked
          tags:
            show: []
          unsnooze_topic:
            tiebreak: [frecency]
          snooze_topics:
            show: [tag, topic]
        """)
        XCTAssertEqual(config.problems, [
            ConfigProblem(path: root, line: 2, message: "unknown pick list \"add_sesion\": expected add_session, move, move_session, "
                          + "snooze_topics, unsnooze_topics, unsnooze_topic, tags or worktree_start"),
            ConfigProblem(path: root, line: 5, message: "pick_lists.add_session.show: expected session, topic-session, session-path or worktree"),
            ConfigProblem(path: root, line: 8, message: "unknown key \"pick_lists.move.order\""),
            ConfigProblem(path: root, line: 10, message: "pick_lists.tags.show: expected a list of tag"),
            ConfigProblem(path: root, line: 12, message: "pick_lists.unsnooze_topic.tiebreak: expected open, running, visit, activity or length"),
        ])
        for list in [ActionList.addSession, .move, .tags, .unsnoozeTopic] {
            XCTAssertEqual(config.rules(for: list), .standard, "\(list)")
        }
        XCTAssertEqual(config.rules(for: .snoozeTopics), PickRules(show: [.tag, .topic]), "a good entry applies beside bad ones")
    }

    func testTheConfigurationGuideNamesEveryPickListAndRowKind() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let guide = try String(contentsOf: repository.appendingPathComponent("docs/configuration.md"), encoding: .utf8)
        for word in ActionList.allCases.map(\.rawValue) + RowKind.allCases.map(\.rawValue) {
            XCTAssertTrue(guide.contains("| `\(word)` |"), "docs/configuration.md has no table row for `\(word)`")
        }
    }

    func testMoveKeysCanBeReboundAndDisabled() throws {
        let config = try load("""
        keybindings:
          command_palette:
            toggle_include_tab: alt+1
            choose_window: []
        """)
        XCTAssertEqual(config.paletteKeybinds.action(for: trigger("alt+1")), .toggleIncludeTab)
        XCTAssertEqual(config.paletteKeybinds.triggers[.choosePane], [])
        XCTAssertNil(config.paletteKeybinds.action(for: trigger("alt+2")))
        XCTAssertEqual(config.problems, [])
    }

    func testRowActionsCanBeBoundWithoutDefaultShortcuts() throws {
        let defaults = try load("")
        XCTAssertNil(defaults.paletteKeybinds.firstTrigger(for: .killWindow))
        XCTAssertNil(defaults.paletteKeybinds.firstTrigger(for: .rename))
        let config = try load("""
        keybindings:
          command_palette:
            kill_window: cmd+backspace
            rename: alt+r
            remove_from_topic: alt+x
        """)
        XCTAssertEqual(config.paletteKeybinds.action(for: trigger("cmd+backspace")), .killWindow)
        XCTAssertEqual(config.paletteKeybinds.action(for: trigger("alt+r")), .rename)
        XCTAssertEqual(config.paletteKeybinds.action(for: trigger("alt+x")), .removeFromTopic)
        XCTAssertEqual(config.problems, [])
    }

    func testAnEmptyListRemovesEveryPalette() throws {
        let config = try load("command_palettes: []")
        XCTAssertEqual(config.commandPalettes, [])
        XCTAssertEqual(config.problems, [])
    }

    func testAPaletteKeybindingIsTakenFromTheDefaultsOfAnAction() throws {
        let config = try load("""
        command_palettes:
          - name: Browse
            keybinding: [cmd+b, ctrl+cmd+b]
            sources: windows
        """)
        XCTAssertEqual(config.commandPalettes.first?.triggers, [trigger("cmd+b"), trigger("ctrl+cmd+b")])
        XCTAssertEqual(config.commandPalettes.first?.sources, [.windows])
        XCTAssertNil(config.keybinds.firstTrigger(for: .toggleBrowser))
        XCTAssertEqual(config.problems, [])
    }

    func testAKeybindingClaimedFirstStaysWhereItWas() throws {
        let actionFirst = try load("""
        keybindings:
          toggle_browser: cmd+p
        command_palettes:
          - name: Sessions
            keybinding: [cmd+p, cmd+shift+p]
            sources: [sessions]
        """)
        XCTAssertEqual(actionFirst.keybinds.action(for: trigger("cmd+p"), focus: nil), .toggleBrowser)
        XCTAssertEqual(actionFirst.commandPalettes.first?.triggers, [trigger("cmd+shift+p")])
        XCTAssertEqual(actionFirst.problems, [
            ConfigProblem(path: root, line: 5, message: "cmd+p is already bound to toggle_browser"),
        ])

        let paletteFirst = try load("""
        command_palettes:
          - name: Sessions
            keybinding: cmd+p
            sources: [sessions]
          - name: Agents
            keybinding: cmd+p
            sources: [agents]
        keybindings:
          toggle_browser: [cmd+p, cmd+e]
        """)
        XCTAssertEqual(paletteFirst.commandPalettes.map(\.triggers), [[trigger("cmd+p")], []])
        XCTAssertEqual(paletteFirst.keybinds.triggers[.toggleBrowser], [trigger("cmd+e")])
        XCTAssertEqual(paletteFirst.problems, [
            ConfigProblem(path: root, line: 6, message: "cmd+p is already bound to the Sessions Command Palette"),
            ConfigProblem(path: root, line: 9, message: "cmd+p is already bound to the Sessions Command Palette"),
        ])
    }

    func testAnActionCanTakeTheDefaultPalettesKeybinding() throws {
        let config = try load("keybindings:\n  toggle_sidebar: cmd+shift+p")
        XCTAssertEqual(config.commandPalettes.first?.name, "Commands")
        XCTAssertEqual(config.commandPalettes.first?.triggers, [])
        XCTAssertEqual(config.commandPalettes.last?.triggers, [trigger("cmd+p")])
        XCTAssertEqual(config.keybinds.action(for: trigger("cmd+shift+p"), focus: nil), .toggleSidebar)
        XCTAssertEqual(config.problems, [])
    }

    func testPalettesThatCannotApplyAreSkipped() throws {
        let config = try load("""
        command_palettes:
          - name: Sessions
            sources: [sessions]
          - name: Sessions
            sources: [windows]
          - name: Files
            sources: [files]
          - name: Nothing
          - sources: [agents]
          - name: Odd
            sources: [agents]
            color: red
          - name: Agents
            keybinding: [hyper+a, cmd+shift+o]
            sources: [agents, agents]
        """)
        XCTAssertEqual(config.commandPalettes, [
            CommandPaletteConfig(name: "Sessions", triggers: [], sources: [.sessions]),
            CommandPaletteConfig(name: "Agents", triggers: [trigger("cmd+shift+o")], sources: [.agents]),
        ])
        XCTAssertEqual(config.problems, [
            ConfigProblem(path: root, line: 4, message: "Command Palette name \"Sessions\" is already used"),
            ConfigProblem(path: root, line: 7, message: "Command Palette sources: expected topics, sessions, windows, agents or commands"),
            ConfigProblem(path: root, line: 8, message: "Command Palette sources: expected a list of topics, sessions, windows, agents or commands"),
            ConfigProblem(path: root, line: 9, message: "Command Palette name: expected a nonempty string"),
            ConfigProblem(path: root, line: 12, message: "unknown Command Palette key \"color\""),
            ConfigProblem(path: root, line: 14, message: "bad trigger \"hyper+a\": unknown modifier \"hyper\""),
        ])
        XCTAssertEqual(try load("command_palettes: {name: x}").problems, [
            ConfigProblem(path: root, line: 1, message: "command_palettes: expected a list"),
        ])
    }

    func testPaletteKeybindingsOverlayTheirOwnDefaults() throws {
        let config = try load("""
        keybindings:
          toggle_browser: cmd+e
          command_palette:
            jump_to: [enter, cmd+b]
            select_next: ctrl+n
            copy_tmux_target: []
            copy_folder: ctrl+n
            reveal_in_finder: cmd+r
        """)
        let keys = config.paletteKeybinds
        XCTAssertEqual(keys.triggers[.jumpTo], [trigger("enter"), trigger("cmd+b")])
        XCTAssertEqual(keys.triggers[.selectNext], [trigger("ctrl+n")])
        XCTAssertEqual(keys.triggers[.selectPrev], [trigger("up"), trigger("ctrl+k")])
        XCTAssertEqual(keys.triggers[.copyTmuxTarget], [])
        XCTAssertEqual(keys.triggers[.copyFolder], [])
        XCTAssertEqual(keys.triggers[.showActions], [trigger("cmd+k")])
        // Only while a palette is open: the global keybinds are untouched.
        XCTAssertEqual(config.keybinds.triggers[.toggleBrowser], [trigger("cmd+e")])
        XCTAssertEqual(config.problems, [
            ConfigProblem(path: root, line: 7, message: "ctrl+n is already bound to select_next"),
            ConfigProblem(path: root, line: 8, message: "unknown Command Palette action \"reveal_in_finder\""),
        ])
    }

    func testARemoteConfigSkipsTheSectionsAboutTheApp() throws {
        let text = """
        ghostty:
          config_file: ghostty.conf
        remote_environments:
          - name: Home
            host: home
            username: me
        ui:
          header_height: 40
          status_line_header: false
        sessions:
          paths:
            - path: ~/src
              depth: 1
        """
        let remote = try load(text, isRemote: true)
        XCTAssertNil(remote.ghosttyConfigFile)
        XCTAssertEqual(remote.remoteEnvironments, [])
        XCTAssertEqual(remote.headerHeight, 40)
        XCTAssertFalse(remote.statusLineHeader)
        XCTAssertEqual(remote.sessionRoots, [SessionPathRoot(path: "~/src", depth: 1)])
        XCTAssertEqual(remote.problems, [])

        let local = try load(text)
        XCTAssertNotNil(local.ghosttyConfigFile)
        XCTAssertEqual(local.remoteEnvironments.map(\.name), ["Home"])
    }
}
