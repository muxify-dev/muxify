import XCTest
@testable import MuxifyCLI
import MuxifyCore

final class CLICommandTests: XCTestCase {
    func testHelpDoesNotNeedTmux() throws {
        for arguments in [["--help"], ["-h"], ["help"], ["browser", "--help"],
                          ["browser", "open", "--help"], ["session", "-h"], ["session", "open", "--help"],
                          ["extensions", "--help"], ["extensions", "install", "--help"]] {
            XCTAssertEqual(try CLICommand(arguments: arguments, environment: [:]), .help)
        }
    }

    func testIncompleteAndUnknownCommandsReturnUsage() {
        for arguments in [[], ["unknown"], ["browser"], ["browser", "close"], ["browser", "open"],
                          ["browser", "open", "--window"], ["session"], ["session", "close"], ["session", "open"],
                          ["extensions"], ["extensions", "unknown"]] {
            XCTAssertThrowsError(try CLICommand(arguments: arguments, environment: [:])) { error in
                XCTAssertEqual((error as? CLIError)?.exitCode, 2)
                XCTAssertEqual(error.localizedDescription, CLICommand.usage)
            }
        }
    }

    func testBrowserTargetsCallingPaneAndKeepsURLsSeparate() throws {
        XCTAssertEqual(try CLICommand(arguments: ["browser", "open", "localhost:3000", "https://example.com/#token=secret"],
                                      environment: ["TMUX_PANE": "%7"]),
                       .browserOpen(window: "%7", urls: ["localhost:3000", "https://example.com/#token=secret"]))
    }

    func testBrowserExplicitWindowWorksOutsideTmux() throws {
        for options in [["--window", "@12"], ["-w", "@12"], ["--window=@12"]] {
            XCTAssertEqual(try CLICommand(arguments: ["browser", "open"] + options + ["https://example.com"], environment: [:]),
                           .browserOpen(window: "@12", urls: ["https://example.com"]))
        }
        XCTAssertEqual(try CLICommand(arguments: ["browser", "open", "--window", "@12", "--", "-url"], environment: [:]),
                       .browserOpen(window: "@12", urls: ["-url"]))
    }

    func testBrowserRejectsMissingTargetUnknownOptionsAndWhitespace() {
        XCTAssertThrowsError(try CLICommand(arguments: ["browser", "open", "localhost:3000"], environment: [:]))
        for argument in ["--unknown", "https://example.com/a b", "https://example.com/a\nb"] {
            XCTAssertThrowsError(try CLICommand(arguments: ["browser", "open", argument], environment: ["TMUX_PANE": "%7"]))
        }
    }

    func testSessionNamesMayBeQuotedUnquotedOrStartWithAnOption() throws {
        for arguments in [["my sessionPath"], ["my", "sessionPath"]] {
            XCTAssertEqual(try CLICommand(arguments: ["session", "open"] + arguments), .sessionOpen(name: "my sessionPath"))
        }
        XCTAssertEqual(try CLICommand(arguments: ["session", "open", "--", "--help"]), .sessionOpen(name: "--help"))
    }

    func testExtensionsInstallNeedsNoTmuxAndRejectsArguments() throws {
        XCTAssertEqual(try CLICommand(arguments: ["extensions", "install"], environment: [:]), .extensionsInstall)
        XCTAssertThrowsError(try CLICommand(arguments: ["extensions", "install", "unexpected"], environment: [:])) { error in
            XCTAssertEqual(error.localizedDescription, "extensions install takes no arguments")
        }
    }

    func testExtensionsInstallerIsLocatedThroughRelativeSymlink() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("muxify-cli-extensions-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("Muxify.app/Contents/Resources")
        let executable = resources.appendingPathComponent("bin/muxify")
        let installer = resources.appendingPathComponent("extensions/install.sh")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: installer.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: executable)
        try Data().write(to: installer)
        let link = root.appendingPathComponent("installed-muxify")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "Muxify.app/Contents/Resources/bin/muxify")
        let runner = RecordingRunner(results: [.init(status: 0, output: "")])
        try await CLICommand.extensionsInstall.execute(using: runner, executableURL: link)
        XCTAssertEqual(runner.calls, [.init(command: "/bin/sh", arguments: [installer.path], quiet: false)])
    }

    func testMissingExtensionsInstallerDoesNotRunACommand() async {
        let runner = RecordingRunner(results: [])
        do {
            try await CLICommand.extensionsInstall.execute(using: runner, executableURL: URL(fileURLWithPath: "/missing/bin/muxify"))
            XCTFail("Expected missing installer error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Extension installer is missing beside the command line tool")
        }
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testBrowserAppendsRequestToResolvedWindow() async throws {
        let runner = RecordingRunner(results: [.init(status: 0, output: "@12\n@12\n"), .init(status: 0, output: "")])
        try await CLICommand.browserOpen(window: "%7", urls: ["localhost:3000", "https://example.com"]).execute(using: runner)
        XCTAssertEqual(runner.calls, [
            .init(command: "tmux", arguments: ["list-panes", "-t", "%7", "-F", "#{window_id}"], quiet: true),
            .init(command: "tmux", arguments: ["set-option", "-wa", "-t", "@12", "@muxify_open", " localhost:3000 https://example.com"], quiet: false),
        ])
    }

    func testMissingBrowserWindowDoesNotWriteOptions() async {
        for result in [CLICommandResult(status: 1, output: ""), .init(status: 0, output: "")] {
            let runner = RecordingRunner(results: [result])
            do {
                try await CLICommand.browserOpen(window: "@404", urls: ["localhost:3000"]).execute(using: runner)
                XCTFail("Expected missing Window error")
            } catch {
                XCTAssertEqual(error.localizedDescription, "no tmux Window '@404'")
            }
            XCTAssertEqual(runner.calls.count, 1)
        }
    }

    func testSessionUsesExactNameAndPercentEncodesUTF8() async throws {
        let runner = RecordingRunner(results: [.init(status: 0, output: ""), .init(status: 0, output: "")])
        try await CLICommand.sessionOpen(name: "a &猫").execute(using: runner)
        XCTAssertEqual(runner.calls, [
            .init(command: "tmux", arguments: ["has-session", "-t", "=a &猫"], quiet: true),
            .init(command: "open", arguments: ["muxify://select?session=%61%20%26%e7%8c%ab"], quiet: false),
        ])
    }

    func testWindowOpenNamesTheWindowOfTheTargetOrOfTheCallerPane() throws {
        XCTAssertEqual(try CLICommand(arguments: ["window", "open"], environment: ["TMUX_PANE": "%7"]), .windowOpen(target: "%7"))
        XCTAssertEqual(try CLICommand(arguments: ["window", "open", "--window", "@12"], environment: ["TMUX_PANE": "%7"]), .windowOpen(target: "@12"))
        XCTAssertEqual(try CLICommand(arguments: ["window", "open", "--pane", "%3"], environment: [:]), .windowOpen(target: "%3"))
        for arguments in [["window", "open"], ["window", "open", "--topic", "Fix"], ["window", "open", "@12"]] {
            XCTAssertThrowsError(try CLICommand(arguments: arguments, environment: [:]), "\(arguments)")
        }
    }

    func testWindowOpenOpensTheURLOfTheWindowThatTmuxNames() async throws {
        let runner = RecordingRunner(results: [.init(status: 0, output: "@12\n"), .init(status: 0, output: "")])
        try await CLICommand.windowOpen(target: "%7").execute(using: runner)
        XCTAssertEqual(runner.calls, [
            .init(command: "tmux", arguments: ["list-panes", "-t", "%7", "-F", "#{window_id}"], quiet: true),
            .init(command: "open", arguments: ["muxify://select?window=%40%31%32"], quiet: false),
        ])
    }

    func testWindowOpenOfAMissingWindowDoesNotOpenTheApp() async {
        let runner = RecordingRunner(results: [.init(status: 1, output: "")])
        do {
            try await CLICommand.windowOpen(target: "@404").execute(using: runner)
            XCTFail("Expected missing Window error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "no tmux Window or Pane '@404'")
        }
        XCTAssertEqual(runner.calls.count, 1)
    }

    func testMissingSessionDoesNotOpenApp() async {
        let runner = RecordingRunner(results: [.init(status: 1, output: "")])
        do {
            try await CLICommand.sessionOpen(name: "missing").execute(using: runner)
            XCTFail("Expected missing Session error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "no tmux session 'missing'")
        }
        XCTAssertEqual(runner.calls.count, 1)
    }

    func testSubcommandFailurePreservesExitCode() async {
        let runner = RecordingRunner(results: [.init(status: 0, output: "@12\n"), .init(status: 7, output: "")])
        do {
            try await CLICommand.browserOpen(window: "%7", urls: ["localhost:3000"]).execute(using: runner)
            XCTFail("Expected tmux failure")
        } catch {
            XCTAssertEqual((error as? CLIError)?.exitCode, 7)
        }
    }

    func testZenStartKeepsTheTargetsTopicAndZenEndTakesNoTarget() throws {
        let inside = ["TMUX_PANE": "%7", "XDG_STATE_HOME": "/state", "HOME": "/home/me"]
        let paths = MuxifyPaths(environment: inside, home: "/home/me")
        let caller = try XCTUnwrap(PaneID(rawValue: "%7"))
        func zen(_ command: RequestInvocation.Command, target: EnvironmentTarget? = nil, caller: PaneID? = caller,
                 output: RequestInvocation.Output = .text) -> CLICommand {
            .request(RequestInvocation(command: command, target: target, caller: caller, output: output, paths: paths))
        }
        XCTAssertEqual(try CLICommand(arguments: ["zen", "start", "2h"], environment: inside), zen(.zen(try XCTUnwrap(SnoozeSchedule("2h", typed: true)))))
        XCTAssertEqual(try CLICommand(arguments: ["zen", "start", "forever", "--topic", "Fix", "--json"], environment: inside),
                       zen(.zen(.never), target: .topic(.named("Fix")), output: .json))
        XCTAssertEqual(try CLICommand(arguments: ["zen", "end"], environment: [:]),
                       .request(RequestInvocation(command: .endZen, target: nil, caller: nil, output: .text,
                                                  paths: MuxifyPaths(environment: [:], home: NSHomeDirectory()))))
        for (arguments, message) in [(["zen", "start"], nil), (["zen", "start", "soon"], "zen start takes a time, e.g. 2h, 17:30, tomorrow, mon 9am or forever"),
                                     (["zen", "end", "now"], nil), (["zen", "end", "--topic", "Fix"], nil)] {
            XCTAssertThrowsError(try CLICommand(arguments: arguments, environment: inside), "\(arguments)") { error in
                XCTAssertEqual((error as? CLIError)?.exitCode, 2, "\(arguments)")
                if let message { XCTAssertEqual(error.localizedDescription, message, "\(arguments)") }
            }
        }
    }

    func testMarkReadVerbsSendTheirScopeWithTheTargetOrTheCallingPane() throws {
        let inside = ["TMUX_PANE": "%7", "XDG_STATE_HOME": "/state", "HOME": "/home/me"]
        let paths = MuxifyPaths(environment: inside, home: "/home/me")
        let caller = try XCTUnwrap(PaneID(rawValue: "%7"))
        func read(_ command: RequestInvocation.Command, target: EnvironmentTarget? = nil, caller: PaneID? = caller) -> CLICommand {
            .request(RequestInvocation(command: command, target: target, caller: caller, output: .text, paths: paths))
        }
        let cases: [([String], CLICommand)] = [
            (["topic", "mark-read"], read(.markRead(.read, scope: .topic))),
            (["topic", "mark-unread", "--topic", "Fix"], read(.markRead(.unread, scope: .topic), target: .topic(.named("Fix")))),
            (["session", "mark-read", "--session", "gs/fix"], read(.markRead(.read, scope: .session), target: .sessionName("gs/fix"))),
            (["window", "mark-unread", "--window", "@12"], read(.markRead(.unread, scope: .window), target: .window(WindowID(rawValue: "@12")!))),
            (["agent", "mark-read", "--pane", "%3"], read(.markRead(.read, scope: .pane), target: .pane(PaneID(rawValue: "%3")!))),
            (["mark-all-read"], read(.markAllRead)),
        ]
        for (arguments, expected) in cases {
            XCTAssertEqual(try CLICommand(arguments: arguments, environment: inside), expected, "\(arguments)")
        }
        for arguments in [["agent", "mark-read", "--window", "@12"], ["window", "mark-read", "--session", "gs"], ["mark-all-read", "--pane", "%3"],
                          ["topic", "mark-read", "now"]] {
            XCTAssertThrowsError(try CLICommand(arguments: arguments, environment: inside), "\(arguments)") { error in
                XCTAssertEqual((error as? CLIError)?.exitCode, 2, "\(arguments)")
            }
        }
    }

    func testTopicCommandsTakeTheCallingPaneAndAtMostOneExplicitTarget() throws {
        let inside = ["TMUX_PANE": "%7", "XDG_STATE_HOME": "/state", "HOME": "/home/me"]
        let outside = ["XDG_STATE_HOME": "/state", "HOME": "/home/me"]
        let paths = MuxifyPaths(environment: inside, home: "/home/me")
        let caller = try XCTUnwrap(PaneID(rawValue: "%7"))
        let window = EnvironmentTarget.window(try XCTUnwrap(WindowID(rawValue: "@12")))
        let pane = EnvironmentTarget.pane(try XCTUnwrap(PaneID(rawValue: "%3")))
        func topic(_ command: RequestInvocation.Command, target: EnvironmentTarget? = nil, caller: PaneID? = caller,
                   output: RequestInvocation.Output = .text) -> CLICommand {
            .request(RequestInvocation(command: command, target: target, caller: caller, output: output, paths: paths))
        }
        let cases: [([String], [String: String], CLICommand)] = [
            (["new", "Fix reward"], outside, topic(.new(title: "Fix reward", tags: []), caller: nil)),
            (["new", "Fix reward", "--tag", "backend", "--tag", "#Release", "--json"], inside,
             topic(.new(title: "Fix reward", tags: [Tag(name: "backend")!, Tag(name: "release")!]), output: .json)),
            (["add-session", "tools"], inside, topic(.addSession(directory: "tools", newWorktree: nil))),
            (["add-session", "tools", "--topic", "Fix reward"], outside,
             topic(.addSession(directory: "tools", newWorktree: nil), target: .topic(.named("Fix reward")), caller: nil)),
            (["add-session", "tools", "--worktree"], inside, topic(.addSession(directory: "tools", newWorktree: .head))),
            (["add-session", "--base", "origin/main", "tools", "--worktree"], inside,
             topic(.addSession(directory: "tools", newWorktree: .ref("origin/main")))),
            (["add-session", "tools", "--worktree", "--branch", "fix"], inside, topic(.addSession(directory: "tools", newWorktree: .branch("fix")))),
            (["settle", "--window", "@12"], inside, topic(.settle(removeWorktrees: false), target: window)),
            (["settle", "--json", "--pane", "%3"], inside, topic(.settle(removeWorktrees: false), target: pane, output: .json)),
            (["settle", "--remove-worktrees"], inside, topic(.settle(removeWorktrees: true))),
            (["snooze", "2h"], inside, topic(.snooze(.relative(2, .hour), topics: []))),
            (["snooze", "mon", "9:30", "--topic", "Fix reward", "--json"], outside,
             topic(.snooze(.weekday(2, hour: 9, minute: 30), topics: [.named("Fix reward")]), caller: nil, output: .json)),
            (["snooze", "--topic", "a", "2h", "--topic", "b", "--topic", "a"], inside,
             topic(.snooze(.relative(2, .hour), topics: [.named("a"), .named("b"), .named("a")]))),
            (["snooze", "forever", "--pane", "%3"], inside, topic(.snooze(.never, topics: []), target: pane)),
            (["unsnooze"], inside, topic(.unsnooze(topics: []))),
            (["tag", "add", "backend", "#Release"], inside, topic(.tag(.add([Tag(name: "backend")!, Tag(name: "release")!])))),
            (["tag", "remove", "backend", "--topic", "Fix"], outside,
             topic(.tag(.remove([Tag(name: "backend")!])), target: .topic(.named("Fix")), caller: nil)),
            (["tag", "set", "--pane", "%3", "--json"], inside, topic(.tag(.set([])), target: pane, output: .json)),
            (["unsnooze", "--window", "@12"], inside, topic(.unsnooze(topics: []), target: window)),
            (["unsnooze", "--topic", "a", "--topic", "b", "--json"], outside,
             topic(.unsnooze(topics: [.named("a"), .named("b")]), caller: nil, output: .json)),
            (["list"], outside, topic(.list, caller: nil)),
            (["list", "--json"], inside, topic(.list, output: .json)),
            (["show"], inside, topic(.show(conversations: false))),
            (["show", "--topic", "Fix reward", "--json"], outside, topic(.show(conversations: false), target: .topic(.named("Fix reward")), caller: nil, output: .json)),
            (["show", "--pane", "%3"], inside, topic(.show(conversations: false), target: pane)),
            (["show", "--conversations", "--json"], inside, topic(.show(conversations: true), output: .json)),
            (["exec", "--", "git", "status", "--short"], inside, topic(.exec(sessionPath: nil, timeout: 60, command: ["git", "status", "--short"]))),
            (["exec", "--topic", "Fix reward", "--session", "tools", "--timeout", "2.5", "--json", "--", "make", "--", "-j"], outside,
             topic(.exec(sessionPath: "tools", timeout: 2.5, command: ["make", "--", "-j"]), target: .topic(.named("Fix reward")),
                   caller: nil, output: .json)),
            (["status"], inside, topic(.status(sessionPath: nil))),
            (["status", "--session", "tools", "--topic", "Fix reward", "--json"], outside,
             topic(.status(sessionPath: "tools"), target: .topic(.named("Fix reward")), caller: nil, output: .json)),
            (["diff"], inside, topic(.diff(sessionPath: nil, stat: false))),
            (["diff", "--stat", "--window", "@12"], inside, topic(.diff(sessionPath: nil, stat: true), target: window)),
            (["exec", "--pane", "%3", "--", "pwd", "--json"], inside, topic(.exec(sessionPath: nil, timeout: 60, command: ["pwd", "--json"]), target: pane)),
        ]
        for (arguments, environment, expected) in cases {
            XCTAssertEqual(try CLICommand(arguments: ["topic"] + arguments, environment: environment), expected, "\(arguments)")
        }
        XCTAssertThrowsError(try CLICommand(arguments: ["topic", "settle"], environment: ["TMUX_PANE": "not-a-pane"]),
                             "a TMUX_PANE that is not a Pane id is no caller") { error in
            XCTAssertEqual((error as? CLIError)?.message,
                           "TMUX_PANE not-a-pane is not a tmux Pane id; name the target with --topic <id|label>, --window <id> or --pane <id>")
            XCTAssertEqual((error as? CLIError)?.exitCode, 2)
        }
        for (environment, topics) in [(["XDG_STATE_HOME": "/state"], "/state/muxify/topics"),
                                      (["HOME": "/home/me"], "/home/me/.local/state/muxify/topics")] {
            guard case .request(let invocation) = try CLICommand(arguments: ["topic", "list"], environment: environment) else {
                return XCTFail("\(environment): expected topic list")
            }
            XCTAssertEqual(invocation.paths.topics.path, topics)
        }
    }

    func testSessionListTakesOnlyJson() throws {
        let environment = ["XDG_STATE_HOME": "/state", "HOME": "/home/me"]
        let paths = MuxifyPaths(environment: environment, home: "/home/me")
        guard case .sessionList(let invocation) = try CLICommand(arguments: ["session", "list", "--json"], environment: environment) else { return XCTFail("expected Session list") }
        XCTAssertEqual(invocation.paths, paths)
        XCTAssertEqual(invocation.output, .json)
        for arguments in [["session"], ["session", "show"], ["session", "list", "extra"], ["session", "list", "--pane", "%3"], ["project", "list"]] {
            XCTAssertThrowsError(try CLICommand(arguments: arguments, environment: [:]), "\(arguments)") { error in
                XCTAssertEqual((error as? CLIError)?.exitCode, 2, "\(arguments)")
            }
        }
    }

    func testWindowMoveTakesTheTopicAndTheCallersWindowOrOneExplicitTarget() throws {
        let inside = ["TMUX_PANE": "%7", "XDG_STATE_HOME": "/state", "HOME": "/home/me"]
        let outside = ["XDG_STATE_HOME": "/state", "HOME": "/home/me"]
        let paths = MuxifyPaths(environment: inside, home: "/home/me")
        let caller = try XCTUnwrap(PaneID(rawValue: "%7"))
        func move(_ topic: String, target: EnvironmentTarget? = nil, caller: PaneID? = caller,
                  output: RequestInvocation.Output = .text) -> CLICommand {
            .request(RequestInvocation(command: .moveWindow(topic: topic, session: nil, newSession: false), target: target, caller: caller,
                                       output: output, paths: paths))
        }
        let cases: [([String], [String: String], CLICommand)] = [
            (["--topic", "Fix reward"], inside, move("Fix reward")),
            (["--window", "@12", "--topic", "Fix"], outside, move("Fix", target: .window(try XCTUnwrap(WindowID(rawValue: "@12"))), caller: nil)),
            (["--topic", "Fix", "--pane", "%3", "--json"], inside, move("Fix", target: .pane(try XCTUnwrap(PaneID(rawValue: "%3"))), output: .json)),
            (["--new-topic"], inside, .request(RequestInvocation(command: .moveToNewTopic(title: ""), target: nil, caller: caller, output: .text, paths: paths))),
            (["--new-topic", "Fix", "--window", "@12"], outside,
             .request(RequestInvocation(command: .moveToNewTopic(title: "Fix"), target: .window(try XCTUnwrap(WindowID(rawValue: "@12"))),
                                        caller: nil, output: .text, paths: paths))),
            (["--new-window", "logs"], inside, .request(RequestInvocation(command: .moveToNewWindow(title: "logs"), target: nil, caller: caller,
                                                                           output: .text, paths: paths))),
        ]
        for (arguments, environment, expected) in cases {
            XCTAssertEqual(try CLICommand(arguments: ["window", "move"] + arguments, environment: environment), expected, "\(arguments)")
        }
        XCTAssertEqual(try CLICommand(arguments: ["window", "move", "--help"], environment: [:]), .help)
        let oneDestination = "window move takes one destination: --topic <id|label>, --new-topic [\"title\"], --new-window [\"title\"], "
            + "--before <window> or --after <window>"
        let errors: [([String], [String: String], String)] = [
            (["window"], inside, CLICommand.usage), (["window", "list"], inside, CLICommand.usage),
            (["window", "move", "--topic"], inside, CLICommand.usage),
            (["window", "move", "Fix"], inside, oneDestination),
            (["window", "move"], inside, oneDestination),
            (["window", "move", "--topic", "Fix", "--new-topic"], inside,
             oneDestination),
            (["window", "move", "--new-topic", "a", "b"], inside, CLICommand.usage),
            (["window", "move", "--new-window", "--window", "@1"], inside,
             "window move --new-window does not take --window; name the target with --pane <id>"),
            (["window", "move", "--topic", ""], inside, "--topic takes the id or label of an open Topic"),
            (["window", "move", "--topic", "Fix", "--window", "@1", "--pane", "%2"], inside, "give only one of --window and --pane"),
            (["window", "move", "--topic", "Fix", "--window", "%1"], inside, "--window takes a tmux Window id, e.g. @12"),
            (["window", "move", "--topic", "Fix"], [:], "not inside tmux; name the target with --window <id> or --pane <id>"),
        ]
        for (arguments, environment, message) in errors {
            XCTAssertThrowsError(try CLICommand(arguments: arguments, environment: environment), "\(arguments)") { error in
                XCTAssertEqual((error as? CLIError)?.exitCode, 2, "\(arguments)")
                XCTAssertEqual(error.localizedDescription, message, "\(arguments)")
            }
        }
    }

    func testSessionLockTakesTheNamedSessionOrTheCallersSession() throws {
        let inside = ["TMUX_PANE": "%7", "XDG_STATE_HOME": "/state", "HOME": "/home/me"]
        let outside = ["XDG_STATE_HOME": "/state", "HOME": "/home/me"]
        let paths = MuxifyPaths(environment: inside, home: "/home/me")
        let caller = try XCTUnwrap(PaneID(rawValue: "%7"))
        XCTAssertEqual(try CLICommand(arguments: ["session", "lock"], environment: inside),
                       .request(RequestInvocation(command: .lock(true), target: nil, caller: caller, output: .text, paths: paths)))
        XCTAssertEqual(try CLICommand(arguments: ["session", "unlock", "--session", "my notes", "--json"], environment: outside),
                       .request(RequestInvocation(command: .lock(false), target: .sessionName("my notes"), caller: nil, output: .json, paths: paths)))
        XCTAssertEqual(try CLICommand(arguments: ["session", "lock", "--help"], environment: [:]), .help)
        let errors: [([String], [String: String], String)] = [
            (["session", "lock", "notes"], inside, CLICommand.usage),
            (["session", "lock", "--session"], inside, CLICommand.usage),
            (["session", "lock"], outside, "not inside tmux; name the target with --session <name|id>"),
        ]
        for (arguments, environment, message) in errors {
            XCTAssertThrowsError(try CLICommand(arguments: arguments, environment: environment), "\(arguments)") { error in
                XCTAssertEqual((error as? CLIError)?.exitCode, 2, "\(arguments)")
                XCTAssertEqual(error.localizedDescription, message, "\(arguments)")
            }
        }
    }

    func testAgentListTakesTheFiltersAndJson() throws {
        let environment = ["XDG_STATE_HOME": "/state", "HOME": "/home/me"]
        let paths = MuxifyPaths(environment: environment, home: "/home/me")
        func agent(topic: String? = nil, status: AgentStatus? = nil, unreadOnly: Bool = false,
                   output: RequestInvocation.Output = .text) -> CLICommand {
            .agent(AgentInvocation(topic: topic, status: status, unreadOnly: unreadOnly, output: output, paths: paths))
        }
        let cases: [([String], CLICommand)] = [
            (["list"], agent()),
            (["list", "--json"], agent(output: .json)),
            (["list", "--topic", "Fix reward", "--status", "blocked", "--unread"],
             agent(topic: "Fix reward", status: .blocked, unreadOnly: true)),
        ]
        for (arguments, expected) in cases {
            XCTAssertEqual(try CLICommand(arguments: ["agent"] + arguments, environment: environment), expected, "\(arguments)")
        }
        XCTAssertEqual(try CLICommand(arguments: ["agent", "list", "--help"], environment: [:]), .help)
        let errors: [([String], String)] = [
            (["agent"], CLICommand.usage), (["agent", "show"], CLICommand.usage), (["agent", "list", "extra"], CLICommand.usage),
            (["agent", "list", "--topic"], CLICommand.usage), (["agent", "list", "--pane", "%3"], CLICommand.usage),
            (["agent", "list", "--status", "idle"], "--status takes working, blocked, done or failed"),
            (["agent", "list", "--topic", ""], "--topic takes the id or label of an open Topic"),
        ]
        for (arguments, message) in errors {
            XCTAssertThrowsError(try CLICommand(arguments: arguments, environment: environment), "\(arguments)") { error in
                XCTAssertEqual((error as? CLIError)?.exitCode, 2, "\(arguments)")
                XCTAssertEqual(error.localizedDescription, message, "\(arguments)")
            }
        }
    }

    func testAgentConversationTakesOneSourceTheSelectionAndTheOutput() throws {
        let environment = ["HOME": "/home/me", "CODEX_HOME": "/codex"]
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let roots = TranscriptRoots(environment: environment, home: URL(fileURLWithPath: "/home/me"))
        let pane = try XCTUnwrap(PaneID(rawValue: "%12"))
        func read(_ source: AgentConversationInvocation.Source, _ selection: EntrySelection = EntrySelection(window: .tail(20)),
                  info: Bool = false, output: RequestInvocation.Output = .text) -> AgentConversationInvocation {
            AgentConversationInvocation(source: source, selection: selection, info: info, output: output, roots: roots)
        }
        let all = Set(Entry.Role.allCases)
        let cases: [([String], AgentConversationInvocation)] = [
            (["%12"], read(.pane(pane))),
            (["--conversation", "abc-1", "--kind", "codex", "--json"], read(.conversation(AgentConversation(kind: .codex, id: "abc-1")), output: .json)),
            (["--transcript", "t.jsonl"], read(.transcript(path: "t.jsonl", kind: nil))),
            (["--transcript", "t.jsonl", "--kind", "pi", "--info"], read(.transcript(path: "t.jsonl", kind: .pi), info: true)),
            (["%12", "--tools", "--range", "-20..-1", "--full"], read(.pane(pane), EntrySelection(roles: all, window: .range(-20, -1), maxChars: nil))),
            (["%12", "--range", "40.."], read(.pane(pane), EntrySelection(window: .range(40, nil)))),
            (["%12", "--after", "61", "--max-chars", "500"], read(.pane(pane), EntrySelection(after: 61, maxChars: 500))),
            (["%12", "--grep", "auth", "--context", "2", "--head", "3"],
             read(.pane(pane), EntrySelection(grep: try .init(pattern: "auth", context: 2), window: .head(3)))),
            (["%12", "--tool", "Bash,Edit"], read(.pane(pane), EntrySelection(roles: [.toolCall, .toolResult], tools: ["Bash", "Edit"]))),
            (["%12", "--role", "user,tool_result"], read(.pane(pane), EntrySelection(roles: [.user, .toolResult]))),
            (["%12", "--since", "2h"], read(.pane(pane), EntrySelection(since: now.addingTimeInterval(-7200)))),
        ]
        for (arguments, expected) in cases {
            XCTAssertEqual(try CLICommand(arguments: ["agent", "conversation"] + arguments, environment: environment, now: now),
                           .agentConversation(expected), "\(arguments)")
        }
        XCTAssertEqual(try CLICommand(arguments: ["agent", "conversation", "%12"], environment: environment),
                       .agentConversation(read(.pane(pane))))
        XCTAssertEqual(try CLICommand(arguments: ["agent", "conversation", "--help"], environment: [:]), .help)
        let errors: [([String], String)] = [
            ([], "name the conversation with a Pane, --conversation <id> --kind <kind> or --transcript <path>"),
            (["%1", "--transcript", "t.jsonl"], "name the conversation with a Pane, --conversation <id> --kind <kind> or --transcript <path>"),
            (["@1"], "agent conversation takes a tmux Pane id, e.g. %3"),
            (["--conversation", "abc"], "--conversation needs --kind claude, codex, pi or opencode"),
            (["--conversation", "../abc", "--kind", "claude"], "--conversation takes an id of letters, digits, _ and -"),
            (["%1", "--kind", "claude"], "--kind goes with --conversation or --transcript, not with a Pane"),
            (["--transcript", "t.json", "--kind", "opencode"], "OpenCode keeps no Transcript file; read it with --conversation <id> --kind opencode"),
            (["%1", "--kind", "gpt"], "--kind takes claude, codex, pi or opencode"),
            (["%1", "--head", "2", "--tail", "2"], "give only one of --head, --tail and --range"),
            (["%1", "--tail", "0"], "--tail takes a whole number above 0"),
            (["%1", "--range", "..", "--json"], "--range takes A..B, e.g. 40..60, -20..-1 or 40.."),
            (["%1", "--range", "4-6"], "--range takes A..B, e.g. 40..60, -20..-1 or 40.."),
            (["%1", "--tools", "--role", "user"], "give only one of --role, --tools and --tool"),
            (["%1", "--role", "system"], "--role takes user, assistant, tool_call, tool_result or all, separated by commas"),
            (["%1", "--context", "2"], "--context goes with --grep"),
            (["%1", "--grep", "("], "--grep takes a regular expression; ( is not one"),
            (["%1", "--full", "--max-chars", "9"], "give only one of --max-chars and --full"),
            (["%1", "--info", "--tail", "5"], "--info prints no Entries, so it takes no selection; it takes --json"),
            (["%1", "--since", "soon"], "--since takes a time, e.g. 2h, 30m, 17:30, mon 9am or 2026-10-18T09:00:00Z"),
            (["%1", "--unknown"], CLICommand.usage),
        ]
        for (arguments, message) in errors {
            XCTAssertThrowsError(try CLICommand(arguments: ["agent", "conversation"] + arguments, environment: environment), "\(arguments)") { error in
                XCTAssertEqual((error as? CLIError)?.exitCode, 2, "\(arguments)")
                XCTAssertEqual(error.localizedDescription, message, "\(arguments)")
            }
        }
        XCTAssertThrowsError(try CLICommand(arguments: ["topic", "status", "--conversations"], environment: ["TMUX_PANE": "%1"]))
    }

    func testTopicCommandsRejectWhatTheShellToolRejected() {
        let inside = ["TMUX_PANE": "%7"]
        for arguments in [["topic"], ["topic", "close"], ["topic", "new", "a", "b"], ["topic", "new", " "],
                          ["topic", "new", "--directory"],
                          ["topic", "new", "--other"], ["topic", "new", "--pane"], ["topic", "add-session"], ["topic", "add-session", "-x"],
                          ["topic", "add-session", "a", "--directory", "b"], ["topic", "add", "a"],
                          ["topic", "add-session", "a", "--base", "main"], ["topic", "add-session", "a", "--worktree", "--base"],
                          ["topic", "add-session", "a", "--worktree", "--base", "x", "--base", "y"],
                          ["topic", "add-session", "a", "--branch", "x"], ["topic", "add-session", "a", "--worktree", "--base", "x", "--branch", "y"],
                          ["topic", "new", "--worktree"], ["topic", "settle", "--base", "main"],
                          ["topic", "add-session", "a", "--remove-worktrees"], ["topic", "move", "a"],
                          ["topic", "settle", "extra"], ["topic", "move", "a", "--window", "@12"],
                          ["topic", "list", "extra"], ["topic", "show", "Fix"],
                          ["topic", "exec"], ["topic", "exec", "--"], ["topic", "exec", "pwd"], ["topic", "exec", "pwd", "--", "ls"],
                          ["topic", "exec", "--timeout", "0", "--", "pwd"], ["topic", "exec", "--timeout", "soon", "--", "pwd"],
                          ["topic", "exec", "--timeout", "-1", "--", "pwd"], ["topic", "show", "--", "pwd"],
                          ["topic", "show", "--timeout", "5"], ["topic", "status", "--stat"], ["topic", "status", "x"],
                          ["topic", "diff", "x"], ["topic", "diff", "--", "pwd"], ["topic", "show", "--stat"],
                          ["topic", "snooze"], ["topic", "snooze", "2h", "--directory", "tools"], ["topic", "snooze", "2h", "--stat"],
                          ["topic", "tag"], ["topic", "tag", "add"], ["topic", "tag", "remove"], ["topic", "tag", "rename", "a"],
                          ["topic", "tag", "add", "a", "--directory", "tools"],
                          ["topic", "unsnooze", "2h"], ["topic", "unsnooze", "--remove-worktrees"], ["topic", "snooze", "2h", "--topic"]] {
            XCTAssertThrowsError(try CLICommand(arguments: arguments, environment: inside), "\(arguments)") { error in
                XCTAssertEqual((error as? CLIError)?.exitCode, 2)
                XCTAssertEqual(error.localizedDescription, CLICommand.usage, "\(arguments)")
            }
        }
        XCTAssertEqual(try CLICommand(arguments: ["topic", "new", "--help"], environment: [:]), .help)
    }

    func testTopicTargetOptionErrorsNameTheProblem() {
        let inside = ["TMUX_PANE": "%7"]
        let cases: [([String], [String: String], String)] = [
            (["new", "--pane", "%1", "--pane", "%2"], inside, "give only one of --topic, --window and --pane"),
            (["settle", "--topic", "Fix", "--window", "@1"], inside, "give only one of --topic, --window and --pane"),
            (["settle", "--topic", "a", "--topic", "b"], inside, "give only one of --topic, --window and --pane"),
            (["snooze", "2h", "--topic", "a", "--pane", "%1"], inside, "give --topic one or more times, or only one of --window and --pane"),
            (["unsnooze", "--window", "@1", "--topic", "a"], inside, "give --topic one or more times, or only one of --window and --pane"),
            (["unsnooze", "--pane", "%1", "--pane", "%2"], inside, "give --topic one or more times, or only one of --window and --pane"),
            (["unsnooze", "--topic", "a", "--topic", ""], inside, "--topic takes the id or label of an open Topic"),
            (["settle", "--window", "%3"], inside, "--window takes a tmux Window id, e.g. @12"),
            (["settle", "--pane", "@3"], inside, "--pane takes a tmux Pane id, e.g. %3"),
            (["new", "--pane", "7"], inside, "--pane takes a tmux Pane id, e.g. %3"),
            (["settle", "--topic", ""], inside, "--topic takes the id or label of an open Topic"),
            (["new", "Fix", "--topic", "Fix"], inside, "topic new does not take --topic"),
            (["list", "--pane", "%3"], inside, "topic list does not take --pane"),
            (["new"], [:], "topic new needs a title. To move this Pane into a new Topic, use: muxify window move --new-topic [\"title\"]"),
            (["new", "--window", "@12"], inside, "topic new makes an Empty Topic and takes no Pane or Window. To move a Pane or Window "
                + "into a new Topic, use: muxify window move --new-topic [\"title\"] [--window <id> | --pane <id>]"),
            (["new", "Fix", "--pane", "%3"], inside, """
                topic new makes an Empty Topic and takes no Pane or Window. To start a Session in the folder of a Pane, use two commands:
                  id=$(muxify topic new "Fix" --json | jq -r .changed.topic_id)
                  muxify topic add-session <dir> --topic "$id"
                To move a Pane or Window into a new Topic, use: muxify window move --new-topic ["title"] [--window <id> | --pane <id>]
                """),
            (["new", "Fix", "--directory", "/work", "--pane", "%3"], inside, """
                topic new makes an Empty Topic and no longer takes --directory. Use two commands:
                  id=$(muxify topic new "Fix" --json | jq -r .changed.topic_id)
                  muxify topic add-session /work --topic "$id"
                """),
            (["add-session", "tools"], [:], "not inside tmux; name the target with --topic <id|label>, --window <id> or --pane <id>"),
            (["settle"], [:], "not inside tmux; name the target with --topic <id|label>, --window <id> or --pane <id>"),
            (["show"], [:], "not inside tmux; name the target with --topic <id|label>, --window <id> or --pane <id>"),
            (["snooze", "2h"], [:], "not inside tmux; name the target with --topic <id|label>, --window <id> or --pane <id>"),
            (["unsnooze"], [:], "not inside tmux; name the target with --topic <id|label>, --window <id> or --pane <id>"),
            (["snooze", "soon"], inside, "topic snooze takes a time, e.g. 2h, 17:30, tomorrow, mon 9am or forever"),
            (["snooze", "25:00"], inside, "topic snooze takes a time, e.g. 2h, 17:30, tomorrow, mon 9am or forever"),
            (["snooze", "never"], inside, "topic snooze takes a time, e.g. 2h, 17:30, tomorrow, mon 9am or forever"),
            (["tag", "add", "back end"], inside, "back end is not a Tag: use lower case letters, digits and -, e.g. backend"),
            (["tag", "set", "café"], inside, "café is not a Tag: use lower case letters, digits and -, e.g. backend"),
            (["tag", "add", "a"], [:], "not inside tmux; name the target with --topic <id|label>, --window <id> or --pane <id>"),
        ]
        for (arguments, environment, message) in cases {
            XCTAssertThrowsError(try CLICommand(arguments: ["topic"] + arguments, environment: environment), "\(arguments)") { error in
                XCTAssertEqual((error as? CLIError)?.exitCode, 2, "\(arguments)")
                XCTAssertEqual(error.localizedDescription, message, "\(arguments)")
            }
        }
    }

    func testBrowserAvailabilityParsingAndStatus() async throws {
        XCTAssertEqual(try CLICommand(arguments: ["browser", "available"], environment: [:]), .browserAvailable(pane: nil))
        XCTAssertEqual(try CLICommand(arguments: ["browser", "available", "--help"]), .help)
        XCTAssertThrowsError(try CLICommand(arguments: ["browser", "available", "extra"]))
        let status = try await CLICommand.browserAvailable(pane: nil).execute(using: RecordingRunner(results: []))
        XCTAssertEqual(status, 1)
        for kind in ["local", "remote"] {
            let runner = RecordingRunner(results: [
                .init(status: 0, output: "90 1 999\n12 0 100\n12 0 200\n11 0 300\n"),
                .init(status: 0, output: "ordinary value\n@muxify_client_stale value\n@muxify_client_live value\n"),
                .init(status: 0, output: "200␟tty␟home␟host␟local\n"),
                .init(status: 0, output: "100␟extra␟fields␟are␟allowed␟\(kind)\n"),
            ])
            let command = try CLICommand(arguments: ["browser", "available"], environment: ["TMUX_PANE": "%7"])
            let status = try await command.execute(using: runner)
            XCTAssertEqual(status, 0)
            XCTAssertTrue(runner.calls.allSatisfy { $0.quiet && $0.command == "tmux" })
        }
    }

    func testBrowserAvailabilityUsesTheNewestClientOnTheServerWhenNoClientShowsThePanesSession() {
        let runner = RecordingRunner(results: [
            .init(status: 0, output: "90 1 999\n"),
            .init(status: 0, output: "90 1 999\n40 0 200\n50 0 100\n"),
            .init(status: 0, output: "@muxify_client_live value\n"),
            .init(status: 0, output: "100␟tty␟home␟host␟local\n"),
        ])
        XCTAssertEqual(BrowserAvailability.check(pane: "%7", using: runner), .local)
        XCTAssertEqual(runner.calls.prefix(2).map(\.arguments), [
            ["list-clients", "-t", "%7", "-F", "#{client_activity} #{client_control_mode} #{client_pid}"],
            ["list-clients", "-F", "#{client_activity} #{client_control_mode} #{client_pid}"],
        ])
    }

    func testBrowserAvailabilityQuietFailuresAndUnmarkedClients() {
        let cases: [[CLICommandResult]] = [
            [.init(status: 1, output: "")],
            [.init(status: 0, output: "10 1 123\n"), .init(status: 1, output: "")],
            [.init(status: 0, output: ""), .init(status: 0, output: "10 1 123\n")],
            [.init(status: 0, output: "10 0 123\n"), .init(status: 1, output: "")],
            [.init(status: 0, output: "10 0 123\n"), .init(status: 0, output: "")],
            [.init(status: 0, output: "10 0 123\n"), .init(status: 0, output: "@muxify_client_bad x"), .init(status: 1, output: "")],
            [.init(status: 0, output: "10 0 123\n"), .init(status: 0, output: "@muxify_client_bad x"), .init(status: 0, output: "123␟unknown")],
        ]
        for results in cases {
            XCTAssertEqual(BrowserAvailability.check(pane: "%7", using: RecordingRunner(results: results)), .no)
        }
    }

    func testProcessRunnerPreservesArgumentBoundaries() throws {
        let result = try CLIProcessRunner().run("/usr/bin/printf", arguments: ["%s\n", "a b", "x; y", "$HOME"], quiet: false)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, "a b\nx; y\n$HOME\n")
    }
}

private final class RecordingRunner: CLICommandRunning {
    struct Call: Equatable {
        let command: String
        let arguments: [String]
        let quiet: Bool
    }

    var calls: [Call] = []
    var results: [CLICommandResult]

    init(results: [CLICommandResult]) { self.results = results }

    func run(_ command: String, arguments: [String], quiet: Bool) throws -> CLICommandResult {
        calls.append(Call(command: command, arguments: arguments, quiet: quiet))
        return results.removeFirst()
    }
}
