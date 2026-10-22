import XCTest
@testable import MuxifyCLI
import MuxifyCore

final class CLIVerbsTests: XCTestCase {
    /// A mirror names a `CLIVerbPath`, so each path must have exactly one verb to run.
    func testEachVerbPathHasExactlyOneVerb() {
        let paths = CLIVerbs.all.map(\.path)
        XCTAssertEqual(paths.count, Set(paths).count, "\(paths)")
        XCTAssertEqual(Set(paths).symmetricDifference(CLIVerbPath.allCases).map(\.rawValue).sorted(), [], "a path with no verb, or a verb with no path")
    }

    /// The options that a synopsis shows are the options that its verb reads, and the reverse.
    func testEachSynopsisShowsTheOptionsThatItsVerbReads() throws {
        let option = try NSRegularExpression(pattern: "--[a-z][a-z-]*")
        for verb in CLIVerbs.all {
            let synopsis = verb.synopsis as NSString
            let shown = Set(option.matches(in: verb.synopsis, range: NSRange(location: 0, length: synopsis.length))
                .map { synopsis.substring(with: $0.range) })
            let read = Set(verb.options.map(\.name))
            let targets = Set(verb.targets.map(\.rawValue))
            XCTAssertEqual(shown.subtracting(targets), read, verb.path.rawValue)
        }
    }

    func testRequestVerbsOfUnitTwoBuildTheirCommandOrNameTheProblem() throws {
        let inside = ["TMUX_PANE": "%7", "XDG_STATE_HOME": "/state", "HOME": "/home/me"]
        let paths = MuxifyPaths(environment: inside, home: "/home/me")
        let caller = try XCTUnwrap(PaneID(rawValue: "%7"))
        func request(_ command: RequestInvocation.Command, target: EnvironmentTarget? = nil) -> CLICommand {
            .request(RequestInvocation(command: command, target: target, caller: caller, output: .text, paths: paths))
        }
        let cases: [([String], CLICommand)] = [
            (["topic", "rename", "New title"], request(.rename(title: "New title"))),
            (["topic", "open"], request(.open)),
            (["topic", "open", "--topic", "Fix"], request(.open, target: .topic(.named("Fix")))),
            (["topic", "reopen", "--topic", "Fix"], request(.reopen, target: .topic(.named("Fix")))),
            (["topic", "start-fresh", "--topic", "Fix"], request(.startFresh, target: .topic(.named("Fix")))),
            (["session", "remove-from-topic"], request(.removeSessionFromTopic(kill: false, removeWorktree: false))),
            (["session", "remove-from-topic", "--kill", "--remove-worktree", "--session", "$4"],
             request(.removeSessionFromTopic(kill: true, removeWorktree: true), target: .session(SessionID(rawValue: "$4")!))),
            (["session", "remove-from-topic", "--session", "gs/fix"],
             request(.removeSessionFromTopic(kill: false, removeWorktree: false), target: .sessionName("gs/fix"))),
            (["window", "remove-from-topic", "--new-session"], request(.removeWindowFromTopic(session: nil))),
            (["window", "remove-from-topic", "--session", "notes", "--window", "@12"],
             request(.removeWindowFromTopic(session: "notes"), target: .window(WindowID(rawValue: "@12")!))),
        ]
        for (arguments, expected) in cases {
            XCTAssertEqual(try CLICommand(arguments: arguments, environment: inside), expected, "\(arguments)")
        }
        let errors: [([String], String)] = [
            (["topic", "rename"], CLIVerbs.usage),
            (["topic", "rename", " "], CLIVerbs.usage),
            (["topic", "reopen"], "topic reopen takes the Topic: --topic <id|label>. A Dormant or Settled Topic has no Pane."),
            (["topic", "start-fresh", "--pane", "%3"], "topic start-fresh does not take --pane; name the target with --topic <id|label>"),
            (["session", "remove-from-topic", "--remove-worktree"], CLIVerbs.usage),
            (["session", "remove-from-topic", "--window", "@1"], CLIVerbs.usage),
            (["session", "lock", "--pane", "%3"], CLIVerbs.usage),
            (["window", "remove-from-topic"],
             "window remove-from-topic takes the destination: --session <name|id> of a No Topic Session, or --new-session"),
            (["window", "remove-from-topic", "--session", "a", "--new-session"],
             "window remove-from-topic takes the destination: --session <name|id> of a No Topic Session, or --new-session"),
        ]
        for (arguments, message) in errors {
            XCTAssertThrowsError(try CLICommand(arguments: arguments, environment: inside), "\(arguments)") { error in
                XCTAssertEqual((error as? CLIError)?.exitCode, 2, "\(arguments)")
                XCTAssertEqual(error.localizedDescription, message, "\(arguments)")
            }
        }
    }

    func testWindowNewTakesOneTargetAndTheCommandAfterTheDashes() throws {
        let inside = ["TMUX_PANE": "%7", "XDG_STATE_HOME": "/state", "HOME": "/home/me"]
        let paths = MuxifyPaths(environment: inside, home: "/home/me")
        let caller = try XCTUnwrap(PaneID(rawValue: "%7"))
        func request(_ command: [String]?, target: EnvironmentTarget? = nil, output: RequestInvocation.Output = .text) -> CLICommand {
            .request(RequestInvocation(command: .newWindow(command: command), target: target, caller: caller, output: output, paths: paths))
        }
        XCTAssertEqual(try CLICommand(arguments: ["window", "new"], environment: inside), request(nil))
        XCTAssertEqual(try CLICommand(arguments: ["window", "new", "--topic", "5c1e", "--json", "--", "claude", "Read x.md", "--json"],
                                      environment: inside), request(["claude", "Read x.md", "--json"], target: .topic(.named("5c1e")), output: .json))
        XCTAssertEqual(try CLICommand(arguments: ["window", "new", "--session", "$7"], environment: inside),
                       request(nil, target: .session(SessionID(rawValue: "$7")!)))
        for arguments in [["window", "new", "--"], ["window", "new", "pwd"], ["window", "new", "--topic", "a", "--pane", "%1"]] {
            XCTAssertThrowsError(try CLICommand(arguments: arguments, environment: inside), "\(arguments)") { error in
                XCTAssertEqual((error as? CLIError)?.exitCode, 2, "\(arguments)")
            }
        }
    }

    func testSessionNewTakesTheFolderAndAName() throws {
        let environment = ["XDG_STATE_HOME": "/state", "HOME": "/home/me"]
        let paths = MuxifyPaths(environment: environment, home: "/home/me")
        XCTAssertEqual(try CLICommand(arguments: ["session", "new", "/work", "--name", "debug", "--json"], environment: environment),
                       .request(RequestInvocation(command: .newSession(directory: "/work", name: "debug"), target: nil, caller: nil,
                                                  output: .json, paths: paths)))
        for arguments in [["session", "new"], ["session", "new", "a", "b"], ["session", "new", "a", "--name", ""], ["session", "new", "a", "--pane", "%1"]] {
            XCTAssertThrowsError(try CLICommand(arguments: arguments, environment: environment), "\(arguments)") { error in
                XCTAssertEqual((error as? CLIError)?.exitCode, 2, "\(arguments)")
            }
        }
    }

    func testPinAndMoveTakeTheirCardAndMoveTakesOneDirection() throws {
        let inside = ["TMUX_PANE": "%7", "XDG_STATE_HOME": "/state", "HOME": "/home/me"]
        let paths = MuxifyPaths(environment: inside, home: "/home/me")
        let caller = try XCTUnwrap(PaneID(rawValue: "%7"))
        func request(_ command: RequestInvocation.Command, target: EnvironmentTarget? = nil) -> CLICommand {
            .request(RequestInvocation(command: command, target: target, caller: caller, output: .text, paths: paths))
        }
        let cases: [([String], CLICommand)] = [
            (["topic", "pin"], request(.pin(true))),
            (["topic", "unpin", "--topic", "Fix"], request(.pin(false), target: .topic(.named("Fix")))),
            (["topic", "move", "up"], request(.moveCard(.up))),
            (["topic", "move", "down", "--topic", "Fix"], request(.moveCard(.down), target: .topic(.named("Fix")))),
            (["session", "move", "up", "--session", "notes"], request(.moveSession(.up), target: .sessionName("notes"))),
            (["session", "move", "down"], request(.moveSession(.down))),
            (["topic", "sort-sessions", "--topic", "Fix"], request(.sortSessions, target: .topic(.named("Fix")))),
        ]
        for (arguments, expected) in cases {
            XCTAssertEqual(try CLICommand(arguments: arguments, environment: inside), expected, "\(arguments)")
        }
        for arguments in [["topic", "pin", "now"], ["topic", "move"], ["topic", "move", "left"], ["topic", "move", "up", "down"],
                          ["session", "move", "up", "--window", "@1"], ["session", "move", "up", "--topic", "Fix"]] {
            XCTAssertThrowsError(try CLICommand(arguments: arguments, environment: inside), "\(arguments)") { error in
                XCTAssertEqual((error as? CLIError)?.exitCode, 2, "\(arguments)")
            }
        }
    }

    func testWindowMoveTakesAnAnchorWindowAsOneMoreDestination() throws {
        let inside = ["TMUX_PANE": "%7", "XDG_STATE_HOME": "/state", "HOME": "/home/me"]
        let paths = MuxifyPaths(environment: inside, home: "/home/me")
        let caller = try XCTUnwrap(PaneID(rawValue: "%7"))
        let three = try XCTUnwrap(WindowID(rawValue: "@3")), five = try XCTUnwrap(WindowID(rawValue: "@5"))
        func request(_ placement: WindowPlacement, target: EnvironmentTarget? = nil, output: RequestInvocation.Output = .text) -> CLICommand {
            .request(RequestInvocation(command: .placeWindow(placement), target: target, caller: caller, output: output, paths: paths))
        }
        XCTAssertEqual(try CLICommand(arguments: ["window", "move", "--before", "@3"], environment: inside), request(.before(three)))
        XCTAssertEqual(try CLICommand(arguments: ["window", "move", "--after", "@3", "--window", "@5", "--json"], environment: inside),
                       request(.after(three), target: .window(five), output: .json))
        let oneDestination = "window move takes one destination: --topic <id|label>, --new-topic [\"title\"], --new-window [\"title\"], "
            + "--before <window> or --after <window>"
        let errors: [([String], String)] = [
            (["window", "move", "--before", "@3", "--after", "@4"], oneDestination),
            (["window", "move", "--before", "@3", "--topic", "Fix"], oneDestination),
            (["window", "move", "--before", "3"], "--before takes a tmux Window id, e.g. @3"),
            (["window", "move", "--after", "%3"], "--after takes a tmux Window id, e.g. @3"),
            (["window", "move", "--before", "@3", "--session", "notes"], CLIVerbs.usage),
            (["window", "move", "--before", "@3", "--new-session"], CLIVerbs.usage),
            (["window", "move", "--before", "@3", "title"], CLIVerbs.usage),
        ]
        for (arguments, message) in errors {
            XCTAssertThrowsError(try CLICommand(arguments: arguments, environment: inside), "\(arguments)") { error in
                XCTAssertEqual((error as? CLIError)?.exitCode, 2, "\(arguments)")
                XCTAssertEqual(error.localizedDescription, message, "\(arguments)")
            }
        }
    }

    /// ADR 0039: an old form fails and names the commands that do its work now.
    func testEachRemovedFormOfTopicNewNamesTheNewCommands() {
        let cases: [([String], [String])] = [
            (["topic", "new"], ["muxify window move --new-topic"]),
            (["topic", "new", "Fix", "--directory", "/work"], ["muxify topic new \"Fix\" --json", "muxify topic add-session /work --topic"]),
            (["topic", "new", "--pane", "%3"], ["muxify window move --new-topic [\"title\"] [--window <id> | --pane <id>]"]),
            (["topic", "new", "Fix", "--pane", "%3"], ["muxify topic new \"Fix\" --json", "muxify topic add-session <dir>", "muxify window move --new-topic"]),
        ]
        for (arguments, commands) in cases {
            XCTAssertThrowsError(try CLICommand(arguments: arguments, environment: ["TMUX_PANE": "%7"]), "\(arguments)") { error in
                XCTAssertEqual((error as? CLIError)?.exitCode, 2)
                for command in commands { XCTAssertTrue(error.localizedDescription.contains(command), "\(arguments): \(error.localizedDescription)") }
            }
        }
    }
}
