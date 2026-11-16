#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import XCTest
@testable import MuxifyCLI
import MuxifyCore
import MuxifyTestSupport

/// The binary against a throwaway tmux server, state folder and Config, a TopicSandbox. The tests of one class run in
/// order, in one process, so the tests are in one class for each verb area, and xcodebuild runs the classes side by side.
class CLIIntegrationTestCase: XCTestCase {
    /// The one JSON object on the one line of `stdout`.
    fileprivate func jsonLine(_ stdout: String) throws -> [String: Any] {
        XCTAssertEqual(stdout.filter { $0 == "\n" }.count, 1, "one line: \(stdout)")
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any], stdout)
    }

    /// The CLI beside this test bundle: `muxify-app-cli` from the app's Xcode build, `muxify` from `swift test`.
    fileprivate var cli: URL {
        #if os(macOS)
        let folder = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        #else
        // On Linux the tests are an executable beside the products, not a .xctest bundle.
        let folder = URL(fileURLWithPath: "/proc/self/exe").resolvingSymlinksInPath().deletingLastPathComponent()
        #endif
        let appCLI = folder.appendingPathComponent("muxify-app-cli")
        return FileManager.default.isExecutableFile(atPath: appCLI.path) ? appCLI : folder.appendingPathComponent("muxify")
    }

    /// Makes a Topic with a Session in `sessionPath` through the CLI, as a user would before the command under test:
    /// an Empty Topic, then Add a Session.
    fileprivate func newTopic(_ title: String, in sessionPath: URL, sandbox: TopicSandbox) async throws -> String {
        let environment = sandbox.cliEnvironment(pane: try sandbox.pane(of: "main"))
        let made = try await run(cli, arguments: ["topic", "new", title], environment: environment)
        guard made.status == 0, let id = made.output.split(separator: "\n").first else { throw CLIError("topic new: \(made.output)") }
        let added = try await run(cli, arguments: ["topic", "add-session", sessionPath.path, "--topic", String(id)], environment: environment)
        guard added.status == 0 else { throw CLIError("topic add-session: \(added.output)") }
        return String(id)
    }

    /// The names of the live Sessions of the Topic, in its order, as topic show --json gives them.
    fileprivate func topicSessions(_ id: String, sandbox: TopicSandbox) async throws -> [String] {
        let shown = try await run(cli, arguments: ["topic", "show", "--topic", id, "--json"], environment: sandbox.cliEnvironment(pane: nil))
        guard shown.status == 0 else { throw CLIError("topic show: \(shown.output)") }
        let sessions = (try jsonLine(shown.stdout)["topic"] as? [String: Any])?["sessions"] as? [[String: Any]] ?? []
        return sessions.compactMap { $0["name"] as? String }
    }

    /// The open Topics, in the order of the Sidebar, as topic list --json gives them.
    fileprivate func topicList(sandbox: TopicSandbox) async throws -> [NSDictionary] {
        let listed = try await run(cli, arguments: ["topic", "list", "--json"], environment: sandbox.cliEnvironment(pane: nil))
        guard listed.status == 0 else { throw CLIError("topic list: \(listed.output)") }
        return try XCTUnwrap(try jsonLine(listed.stdout)["topics"] as? [NSDictionary], listed.stdout)
    }

    /// Waits for what a program in a Pane does in its own time, such as a hook or the command of a new Window.
    fileprivate func wait(_ message: String, seconds: TimeInterval = 10, until done: () throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while try !done() {
            guard Date() < deadline else { return XCTFail(message) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    fileprivate func makeProcess(_ tool: URL, arguments: [String], output: Pipe, errors: Pipe,
                                 environment: [String: String] = [:], in directory: URL? = nil) -> Process {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.currentDirectoryURL = directory ?? tool.deletingLastPathComponent()
        var inherited = ProcessInfo.processInfo.environment
        inherited["PATH"] = "/usr/bin:/bin"
        inherited.removeValue(forKey: "TMUX")
        inherited.removeValue(forKey: "TMUX_PANE")
        process.environment = inherited.merging(environment) { $1 }
        process.standardOutput = output
        process.standardError = errors
        return process
    }

    fileprivate func run(_ tool: URL, arguments: [String], environment: [String: String] = [:], in directory: URL? = nil) async throws -> CLIRun {
        let output = Pipe()
        let errors = Pipe()
        let process = makeProcess(tool, arguments: arguments, output: output, errors: errors, environment: environment, in: directory)
        try process.run()
        defer { stopIfRunning(process) }
        try await waitForExit(process)
        return CLIRun(status: process.terminationStatus,
                      stdout: String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                      stderr: String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    fileprivate func waitForExit(_ process: Process) async throws {
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        guard !process.isRunning else { throw CLIError("CLI did not exit before the timeout") }
        // Async tasks can resume on a different thread than Process.run().
        // waitUntilExit() can then hang in a thread-local run loop even after exit.
        // Once isRunning is false, terminationStatus is already available.
    }

    fileprivate func stopIfRunning(_ process: Process) {
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            XCTAssertFalse(process.isRunning, "CLI did not exit after SIGKILL")
        }
    }
}

/// Topics: list, new, add-session and its Worktrees, settle, rename, reopen and start-fresh, forget, tag, forget-settled,
/// pin, the In Play verbs, open, the failures and --json.
final class CLITopicIntegrationTests: CLIIntegrationTestCase {
    /// One line per open Topic: its id, its label on one line, and its Tags.
    func testTopicListPrintsTheIdLabelAndTagsOfEachOpenTopicOnALine() async throws {
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("muxify-cli-golden-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: state) }
        var tagged = TopicRecord(id: "b-tags", title: "Ship")
        tagged.tags = [Tag(name: "release")!, Tag(name: "backend")!]
        try TopicStore(paths: MuxifyPaths(environment: ["XDG_STATE_HOME": state.path], home: "/nonexistent")).write { topics in
            for record in [TopicRecord(id: "a-tabs", title: "Fix\treward\nflow\r\nnow"), tagged, TopicRecord(id: "c-untitled")] {
                try topics.create(record)
            }
        }
        let result = try await run(cli, arguments: ["topic", "list"], environment: ["XDG_STATE_HOME": state.path])
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(Array(result.output.utf8), Array("""
            a-tabs\tFix reward flow\r now\t
            b-tags\tShip\t#backend #release
            c-untitled\tUntitled 1\t

            """.utf8))
    }

    func testTopicListLeavesOutEntriesThatAreNotValidRecordsAndNamesEach() async throws {
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("muxify-cli-invalid-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: state) }
        let binary = cli
        let empty = try await run(binary, arguments: ["topic", "list"], environment: ["XDG_STATE_HOME": state.path])
        XCTAssertEqual(empty.status, 0, empty.output)
        XCTAssertEqual(empty.output, "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.path), "a list creates no state folder")

        let folder = state.appendingPathComponent("muxify")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("topics.json")
        try Data(#"{"records":[{"id":"a","title":"Valid"},{"id":"d","title":7},42,{"id":"a","title":"Twin"}],"open_places":[]}"#.utf8)
            .write(to: file)
        let result = try await run(binary, arguments: ["topic", "list"], environment: ["XDG_STATE_HOME": state.path])
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.stdout, "a\tValid\t\n")
        let problems = result.stderr.split(separator: "\n").map(String.init)
        XCTAssertEqual(problems.count, 3, result.stderr)
        XCTAssertTrue(problems[0].hasPrefix("muxify: \(file.path): records[1] (id d) is not a valid Topic record"), problems[0])
        XCTAssertTrue(problems[1].hasPrefix("muxify: \(file.path): records[2] is not a valid Topic record"), problems[1])
        XCTAssertEqual(problems[2], "muxify: \(file.path): records[3] (id a) repeats the id of an earlier record, so Muxify did not import it")
        let again = try await run(binary, arguments: ["topic", "list"], environment: ["XDG_STATE_HOME": state.path])
        XCTAssertEqual(again.output, "a\tValid\t\n", "the import ran once")
    }

    func testTopicNewThenAddSessionLeavesEveryClientWhereItWas() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let caller = try sandbox.pane(of: "main")
        let control = try sandbox.attachClient(to: "main", control: true)
        let client = try sandbox.attachClient(to: "main")
        let made = try await run(cli, arguments: ["topic", "new", "Ship it"], environment: sandbox.cliEnvironment(pane: caller))
        XCTAssertEqual(made.status, 0, made.output)
        let id = try XCTUnwrap(sandbox.records().only?.id)
        XCTAssertEqual(made.output, id + "\n")
        let result = try await run(cli, arguments: ["topic", "add-session", sandbox.game.path, "--topic", id],
                                   environment: sandbox.cliEnvironment(pane: caller))
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.output, id + "\n")
        let record = try XCTUnwrap(sandbox.records().only)
        XCTAssertEqual(record.title, "Ship it")
        XCTAssertEqual(sandbox.repositoryPaths(of: record), [sandbox.game.path])
        XCTAssertEqual(try sandbox.tmux(["show-options", "-qv", "-t", "game/ship-it:", "@muxify_topic"]), id)
        XCTAssertEqual(try sandbox.clientSession(client), "main", "a command changes what the terminal shows only when asked")
        XCTAssertEqual(try sandbox.clientSession(control), "main", "a command changes what the control-mode client shows only when asked")
        XCTAssertEqual(try sandbox.tmux(["display-message", "-p", "-t", caller.rawValue, "#{session_name}"]), "main", "the caller Pane stays")
    }

    func testATopicCommandWithAMissingDirectoryIsAUsageErrorAndWritesNothing() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let missing = sandbox.root.appendingPathComponent("missing").path
        let environment = sandbox.cliEnvironment(pane: try sandbox.pane(of: "main"))
        for arguments in [["topic", "add-session", missing], ["topic", "new", "Fix", "--directory", missing]] {
            let result = try await run(cli, arguments: arguments, environment: environment)
            XCTAssertEqual(result.status, 2, "\(arguments): \(result.output)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.root.appendingPathComponent("state").path),
                       "a usage error writes no state folder")
        XCTAssertEqual(try sandbox.sessions(), ["main"])
    }

    func testTopicAddSessionAddsASessionForTheSessionPathToTheCallerPanesTopic() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let id = try await newTopic("Ship", in: sandbox.game, sandbox: sandbox)
        let link = sandbox.root.appendingPathComponent("tools-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sandbox.tools)
        let result = try await run(cli, arguments: ["topic", "add-session", link.path],
                                   environment: sandbox.cliEnvironment(pane: try sandbox.pane(of: "game/ship")))
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.stdout, id + "\n", "a write prints the id of the Topic it changed")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(sandbox.repositoryPaths(of: try XCTUnwrap(sandbox.records().only)), [sandbox.game.path, sandbox.tools.path])
        XCTAssertEqual(try sandbox.tmux(["show-options", "-qv", "-t", "tools/ship:", "@muxify_topic"]), id)
    }

    func testTopicAddSessionOfAWorktreeFolderOpensTheSessionInThatWorktree() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let server = try sandbox.makeBareRepository("server", worktrees: ["main", "release"])
        let id = try await newTopic("Ship", in: sandbox.game, sandbox: sandbox)
        let result = try await run(cli, arguments: ["topic", "add-session", server.path + "/release", "--topic", id],
                                   environment: sandbox.cliEnvironment(pane: nil))
        XCTAssertEqual(result.status, 0, result.output)
        let session = try XCTUnwrap(sandbox.session(of: try XCTUnwrap(sandbox.records().only), in: server))
        XCTAssertEqual(sandbox.real(session["worktree_path"]?.string), server.path + "/release")
        XCTAssertEqual(session["branch"]?.string, "release")
        XCTAssertEqual(session["worktree_created"], .bool(false))
        XCTAssertEqual(sandbox.real(try sandbox.tmux(["display-message", "-p", "-t", "=server/release/ship:", "#{session_path}"])), server.path + "/release")
    }

    func testTopicAddSessionWithWorktreeAndBaseMakesAWorktreeOnTheTopicBranchAtThatRefInMuxifysFolder() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let server = try sandbox.makeBareRepository("server", worktrees: ["main", "release"])
        let release = server.path + "/release"
        try sandbox.git(["commit", "-q", "--allow-empty", "-m", "release only"], in: release)
        let id = try await newTopic("Ship", in: sandbox.game, sandbox: sandbox)
        let result = try await run(cli, arguments: ["topic", "add-session", release, "--worktree", "--base", "main", "--topic", id],
                                   environment: sandbox.cliEnvironment(pane: nil))
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.stdout, id + "\n")
        let worktree = sandbox.root.path + "/state/muxify/worktrees/server/ship"
        let main = try sandbox.git(["rev-parse", "main"], in: release)
        XCTAssertNotEqual(main, try sandbox.git(["rev-parse", "HEAD"], in: release))
        let session = try XCTUnwrap(sandbox.session(of: try XCTUnwrap(sandbox.records().only), in: server))
        XCTAssertEqual(sandbox.real(session["worktree_path"]?.string), worktree)
        XCTAssertEqual(session["branch"]?.string, "ship")
        XCTAssertEqual(session["worktree_created"], .bool(true))
        XCTAssertEqual(session["base"]?.string, main, "the commit that --base names, not the HEAD of the row's Worktree")
        XCTAssertEqual(try sandbox.git(["rev-parse", "HEAD"], in: worktree), main)
        XCTAssertEqual(try sandbox.git(["symbolic-ref", "--short", "HEAD"], in: worktree), "ship")
        XCTAssertEqual(sandbox.real(try sandbox.tmux(["display-message", "-p", "-t", "=server/release/ship:", "#{session_path}"])), worktree)
        XCTAssertEqual(try sandbox.topicOption(of: "server/release/ship"), id)
    }

    func testTopicAddSessionWithWorktreeOfAFolderThatIsNoRepositoryIsAnErrorAndChangesNothing() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let id = try await newTopic("Ship", in: sandbox.game, sandbox: sandbox)
        let before = try sandbox.records()
        let result = try await run(cli, arguments: ["topic", "add-session", sandbox.tools.path, "--worktree", "--topic", id],
                                   environment: sandbox.cliEnvironment(pane: nil))
        XCTAssertEqual(result.status, 2, result.output)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "muxify: --worktree needs a git repository, and \(sandbox.tools.path) is not one\n")
        XCTAssertEqual(try sandbox.records(), before)
        XCTAssertEqual(try sandbox.sessions(), ["game/ship", "main"])
    }

    func testTopicSettleWithRemoveWorktreesRemovesTheMergedWorktreeThatTheTopicMadeAndKeepsItsBranch() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let server = try sandbox.makeBareRepository("server", worktrees: ["main"])
        let id = try await newTopic("Ship", in: sandbox.game, sandbox: sandbox)
        let added = try await run(cli, arguments: ["topic", "add-session", server.path + "/main", "--worktree", "--topic", id],
                                  environment: sandbox.cliEnvironment(pane: nil))
        XCTAssertEqual(added.status, 0, added.output)
        let worktree = sandbox.root.path + "/state/muxify/worktrees/server/ship"
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree))
        let result = try await run(cli, arguments: ["topic", "settle", "--kill-sessions", "--remove-worktrees", "--topic", id],
                                   environment: sandbox.cliEnvironment(pane: nil))
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.stdout, id + "\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree), "Settle removes the Worktree that the Topic made")
        XCTAssertEqual(try sandbox.git(["branch", "--list", "ship"], in: server.path), "ship", "Settle keeps the branch for Reopen")
        XCTAssertEqual(try sandbox.sessions(), ["main"])
    }

    func testTopicSettleSettlesTheCallerPanesTopicAndEndsItsSession() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let id = try await newTopic("Ship", in: sandbox.game, sandbox: sandbox)
        let result = try await run(cli, arguments: ["topic", "settle", "--kill-sessions"],
                                   environment: sandbox.cliEnvironment(pane: try sandbox.pane(of: "game/ship")))
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.stdout, id + "\n", "a write prints the id of the Topic it changed")
        XCTAssertEqual(result.stderr, "")
        XCTAssertNotNil(try XCTUnwrap(sandbox.records().only).settledAt)
        XCTAssertEqual(try sandbox.sessions(), ["main"])
    }

    func testTopicTagAddsRemovesAndSetsTheTagsOfTheTopicInTheRecord() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let id = try await newTopic("Ship", in: sandbox.game, sandbox: sandbox)
        let add = try await run(cli, arguments: ["topic", "tag", "add", "Release", "#backend"],
                                environment: sandbox.cliEnvironment(pane: try sandbox.pane(of: "game/ship")))
        XCTAssertEqual(add.status, 0, add.output)
        XCTAssertEqual(add.stdout, id + "\n", "a write prints the id of the Topic it changed")
        XCTAssertEqual(try XCTUnwrap(sandbox.records().only).tags.map(\.name).sorted(), ["backend", "release"])
        let undefined = try await run(cli, arguments: ["topic", "tag", "set", "backend", "bazel", "--topic", "Ship"],
                                      environment: sandbox.cliEnvironment(pane: nil))
        XCTAssertNotEqual(undefined.status, 0, undefined.output)
        XCTAssertTrue(undefined.stderr.contains("#bazel") && undefined.stderr.contains("topics.tags"), undefined.stderr)
        XCTAssertEqual(try XCTUnwrap(sandbox.records().only).tags.map(\.name).sorted(), ["backend", "release"],
                       "a Tag that the Config does not define writes nothing")
        let remove = try await run(cli, arguments: ["topic", "tag", "remove", "release", "--topic", "Ship"], environment: sandbox.cliEnvironment(pane: nil))
        XCTAssertEqual(remove.status, 0, remove.output)
        XCTAssertEqual(try XCTUnwrap(sandbox.records().only).tags.map(\.name).sorted(), ["backend"])
        let set = try await run(cli, arguments: ["topic", "tag", "set", "--topic", id, "--json"], environment: sandbox.cliEnvironment(pane: nil))
        XCTAssertEqual(set.status, 0, set.output)
        XCTAssertEqual(try XCTUnwrap(try jsonLine(set.stdout)["changed"] as? [String: Any], set.stdout)["topic_id"] as? String, id)
        XCTAssertEqual(try XCTUnwrap(sandbox.records().only).tags, [], "set with no Tag removes the key")
        XCTAssertEqual(try sandbox.sessions(), ["game/ship", "main"], "a Tag change changes nothing in tmux")
    }

    /// Each In Play verb through the binary, from its command line to its step, and a refused step. GuestTests and
    /// TopicServiceCardTests prove what each step does.
    func testEachInPlayVerbMovesItsCardAndARefusedStepExitsOne() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let config = try String(contentsOf: sandbox.config, encoding: .utf8)
        try Data(config.replacingOccurrences(of: "topics:\n", with: "topics:\n  in_play: 2\n").utf8).write(to: sandbox.config)
        for name in ["First", "Second", "Third", "Fourth"] { _ = try await newTopic(name, in: sandbox.game, sandbox: sandbox) }
        try sandbox.tmux(["new-session", "-d", "-s", "notes", "-c", sandbox.tools.path])
        let notes = try sandbox.tmux(["display-message", "-p", "-t", "=notes:", "#{session_id}"])
        let environment = sandbox.cliEnvironment(pane: nil)
        // environment show prints the snapshot with no key around it.
        func unpinned() async throws -> [String: Any] {
            let shown = try await run(cli, arguments: ["environment", "show", "--json"], environment: environment)
            return try XCTUnwrap(try jsonLine(shown.stdout)["unpinned"] as? [String: Any], shown.stdout)
        }
        /// The places, the Guests and the Bench: each card is its Topic's label, its Locked Session's id, or `open`.
        func cards() async throws -> String {
            let sections = try await unpinned()
            return ["places", "guests", "bench"].map { section in
                "[" + (sections[section] as? [[String: Any]] ?? []).map { card in
                    (card["topic"] as? [String: Any])?["label"] as? String ?? (card["sessions"] as? [String])?.first ?? "open"
                }.joined(separator: " ") + "]"
            }.joined(separator: " ")
        }
        func step(_ arguments: [String], _ expected: String) async throws {
            let result = try await run(cli, arguments: ["topic"] + arguments, environment: environment)
            XCTAssertEqual(result.status, 0, "\(arguments): \(result.output)")
            let after = try await cards()
            XCTAssertEqual(after, expected, "\(arguments)")
        }
        let start = try await cards()
        XCTAssertEqual(start, "[First Second] [] [Fourth Third]")

        try await step(["make-guest", "--session", "notes"], "[First Second] [\(notes)] [Fourth Third]")
        try await step(["make-guest", "--topic", "Third"], "[First Second] [\(notes) Third] [Fourth]")
        // A card that a command line names by its Session.
        let refused = try await run(cli, arguments: ["topic", "replace-from-bench", "--with-session", "notes", "--topic", "First"],
                                    environment: environment)
        XCTAssertEqual(refused.status, 1, "a Guest Session is In Play: " + refused.output)
        XCTAssertTrue(refused.stderr.contains("not on the Bench"), refused.stderr)
        try await step(["bench", "--topic", "Third"], "[First Second] [\(notes)] [Third Fourth]")
        try await step(["bench", "--topic", "Second"], "[First open] [\(notes)] [Second Third Fourth]")
        let places = try await unpinned()["places"] as? [[String: Any]]
        let open = try XCTUnwrap(places?.last?["id"] as? String, "the Open Place that Second left")
        try await step(["move", "--after-place", open, "--topic", "First"], "[open First] [\(notes)] [Second Third Fourth]")
        try await step(["fill-place", "1", "--topic", "Fourth"], "[Fourth First] [\(notes)] [Second Third]")
        try await step(["move", "--trade-with", "Second", "--topic", "First"], "[Fourth Second] [\(notes)] [First Third]")
        try await step(["move", "--before", "First", "--topic", "Third"], "[Fourth Second] [\(notes)] [Third First]")
        try await step(["choose-in-play", "--topic", "Third", "--topic", "First"], "[Third First] [\(notes)] [Fourth Second]")
        try await step(["replace-from-bench", "--with", "Second", "--session", "notes"], "[Third First] [Second] [Fourth]")
    }

    func testTopicForgetSettledForgetsOnlyTheSettledTopicsOlderThanTheDaysAndKeepsTheirWorktrees() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let config = try String(contentsOf: sandbox.config, encoding: .utf8)
        try Data(config.replacingOccurrences(of: "topics:\n", with: "topics:\n  forget_settled_older_than: 30\n").utf8).write(to: sandbox.config)
        let worktree = sandbox.root.appendingPathComponent("work/kept-tree", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        func ago(_ days: Int) -> String { ISO8601DateFormatter().string(from: Date().addingTimeInterval(-Double(days) * 86_400)) }
        let records: [[String: Any]] = [
            ["id": "old", "title": "Old", "slug": "old", "settled_at": ago(40),
             "sessions": [["id": "saved:old", "worktree_path": worktree.path, "directory": worktree.path]]],
            ["id": "middle", "title": "Middle", "slug": "middle", "settled_at": ago(20)],
            ["id": "recent", "title": "Recent", "slug": "recent", "settled_at": ago(2)],
            ["id": "open", "title": "Open", "slug": "open"],
        ]
        let file = sandbox.root.appendingPathComponent("state/muxify/topics.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["open_places": [], "records": records]).write(to: file)
        let environment = sandbox.cliEnvironment(pane: nil)
        func ids() throws -> [String] { try sandbox.records().map(\.id).sorted() }

        let byConfig = try await run(cli, arguments: ["topic", "forget-settled"], environment: environment)
        XCTAssertEqual(byConfig.status, 0, byConfig.output)
        XCTAssertEqual(byConfig.stdout, "old\tOld\t\n", "without --older-than, topics.forget_settled_older_than gives 30 days")
        XCTAssertEqual(try ids(), ["middle", "open", "recent"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.path), "Forget Settled Older Than… removed a Worktree")

        let byOption = try await run(cli, arguments: ["topic", "forget-settled", "--older-than", "14", "--json"], environment: environment)
        XCTAssertEqual(byOption.status, 0, byOption.output)
        let forgotten = try XCTUnwrap(try jsonLine(byOption.stdout)["topics"] as? [[String: Any]])
        XCTAssertEqual(forgotten.compactMap { $0["id"] as? String }, ["middle"])
        XCTAssertEqual(try ids(), ["open", "recent"], "an open Topic, and a Topic Settled 2 days ago, stay")

        let none = try await run(cli, arguments: ["topic", "forget-settled", "--older-than", "14"], environment: environment)
        XCTAssertEqual(none.status, 0, none.output)
        XCTAssertEqual(none.stdout, "No Settled Topic was Settled more than 14 days ago.\n")
        XCTAssertEqual(try ids(), ["open", "recent"])
    }

    /// A failure prints `muxify: <message> No changes were made.` and exits 1, and with --json it also prints the
    /// failure's kind. TopicServiceTests proves the kinds and that nothing changed.
    func testAFailurePrintsItsMessageAndKindExitsOneAndChangesNothing() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        _ = try await newTopic("Ship", in: sandbox.game, sandbox: sandbox)
        _ = try await newTopic("Ship", in: sandbox.game, sandbox: sandbox)
        let before = try sandbox.records()
        let sessions = try sandbox.sessions()
        let main = try sandbox.pane(of: "main")
        let cases: [(arguments: [String], caller: PaneID?, message: String, kind: String)] = [
            (["topic", "settle", "--topic", "Nope"], nil, "No open Topic matches Nope.", "topic_unavailable"),
            (["window", "move", "--topic", "Nope"], main, "No open Topic matches Nope.", "topic_unavailable"),
            (["topic", "add-session", sandbox.tools.path, "--topic", "Ship"], main, "More than one open Topic matches Ship. Use an id.",
             "topic_ambiguous"),
            (["topic", "settle", "--pane", main.rawValue], try sandbox.pane(of: "game/ship"), "The Pane is not in an open Topic.",
             "source_has_no_topic"),
            (["topic", "show"], main, "The Pane is not in an open Topic.", "source_has_no_topic"),
        ]
        for (arguments, caller, message, kind) in cases {
            let text = try await run(cli, arguments: arguments, environment: sandbox.cliEnvironment(pane: caller))
            XCTAssertEqual(text.status, 1, "\(arguments): \(text.output)")
            XCTAssertEqual(text.stdout, "", "\(arguments)")
            XCTAssertEqual(text.stderr, "muxify: \(message) No changes were made.\n", "\(arguments)")
            let json = try await run(cli, arguments: arguments + ["--json"], environment: sandbox.cliEnvironment(pane: caller))
            XCTAssertEqual(json.status, 1, "\(arguments): \(json.output)")
            XCTAssertEqual(json.stderr, text.stderr, "\(arguments)")
            let failure = try XCTUnwrap(try jsonLine(json.stdout)["failed"] as? [String: Any], "\(arguments): \(json.stdout)")
            XCTAssertEqual(failure["kind"] as? String, kind, "\(arguments)")
            XCTAssertEqual(failure["phase"] as? String, "nothing_changed", "\(arguments)")
            XCTAssertEqual(failure["message"] as? String, message, "\(arguments)")
        }
        XCTAssertEqual(try sandbox.records(), before)
        XCTAssertEqual(try sandbox.sessions(), sessions)
        XCTAssertEqual(try sandbox.topicOption(of: "main"), "", "the caller's Window stays out of every Topic")
    }

    func testJsonPrintsTheChangeAsOneLine() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let result = try await run(cli, arguments: ["topic", "new", "Ship", "--json"], environment: sandbox.cliEnvironment(pane: nil))
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.stderr, "")
        let id = try XCTUnwrap(sandbox.records().only?.id)
        let change = try XCTUnwrap(try jsonLine(result.stdout)["changed"] as? [String: Any], result.stdout)
        XCTAssertEqual(change["topic_id"] as? String, id)
        XCTAssertEqual(change["created"] as? Bool, true)
    }

    func testJsonListsTheOpenTopics() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let id = try await newTopic("Ship", in: sandbox.game, sandbox: sandbox)
        let tagged = try await run(cli, arguments: ["topic", "tag", "add", "backend", "--topic", id], environment: sandbox.cliEnvironment(pane: nil))
        XCTAssertEqual(tagged.status, 0, tagged.output)
        let result = try await run(cli, arguments: ["topic", "list", "--json"], environment: sandbox.cliEnvironment(pane: nil))
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.stdout, #"{"topics":[{"id":""# + id + #"","label":"Ship","pinned":false,"tags":["backend"]}]}"# + "\n")
    }

    func testTopicForgetForgetsALiveOrASettledTopicAndItsSession() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let environment = sandbox.cliEnvironment(pane: nil)
        for settled in [false, true] {
            let id = try await newTopic("Forget", in: sandbox.game, sandbox: sandbox)
            if settled {
                let settle = try await run(cli, arguments: ["topic", "settle", "--topic", id], environment: environment)
                XCTAssertEqual(settle.status, 0, settle.output)
            }
            let forgot = try await run(cli, arguments: ["topic", "forget", "--topic", id, "--json"], environment: environment)
            XCTAssertEqual(forgot.status, 0, forgot.output)
            XCTAssertEqual(try sandbox.records(), [], "settled: \(settled)")
            XCTAssertFalse(try sandbox.sessions().contains("game/forget"), "settled: \(settled)")
        }
    }

    func testTopicRenameThenSettleReopenAndStartFreshBringTheSessionBack() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let id = try await newTopic("Reopen", in: sandbox.game, sandbox: sandbox)
        let environment = sandbox.cliEnvironment(pane: nil)
        let renamed = try await run(cli, arguments: ["topic", "rename", "Reopen renamed", "--topic", id], environment: environment)
        XCTAssertEqual(renamed.status, 0, renamed.output)
        XCTAssertEqual(renamed.stdout, id + "\n")
        XCTAssertEqual(try XCTUnwrap(sandbox.records().only).title, "Reopen renamed")

        for verb in ["reopen", "start-fresh"] {
            let settled = try await run(cli, arguments: ["topic", "settle", "--kill-sessions", "--topic", id], environment: environment)
            XCTAssertEqual(settled.status, 0, settled.output)
            XCTAssertEqual(try sandbox.sessions(), ["main"], "Settle kept a Session")
            let reopened = try await run(cli, arguments: ["topic", verb, "--topic", id], environment: environment)
            XCTAssertEqual(reopened.status, 0, "\(verb): \(reopened.output)")
            let sessions = try await topicSessions(id, sandbox: sandbox)
            XCTAssertEqual(sessions.count, 1, "\(verb) made no Session")
        }
    }

    func testTopicAddSessionJsonGivesTheIdsOfTheSessionWindowAndPaneThatItMade() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let environment = sandbox.cliEnvironment(pane: nil)
        let made = try await run(cli, arguments: ["topic", "new", "Ids"], environment: environment)
        let id = made.stdout.trimmingCharacters(in: .newlines)
        let added = try await run(cli, arguments: ["topic", "add-session", sandbox.game.path, "--topic", id, "--json"], environment: environment)
        XCTAssertEqual(added.status, 0, added.output)
        let changed = try XCTUnwrap(try jsonLine(added.stdout)["changed"] as? [String: Any], added.stdout)
        XCTAssertEqual(changed["session_name"] as? String, "game/ids")
        let pane = try XCTUnwrap(changed["pane"] as? String, added.stdout)
        XCTAssertEqual(try sandbox.tmux(["display-message", "-p", "-t", pane, "#{session_id} #{window_id} #{pane_id} #{@muxify_topic}"]),
                       [changed["session"] as? String, changed["window"] as? String, pane, id].compactMap { $0 }.joined(separator: " "))
    }

    func testTopicPinPutsTheTopicFirstAndUnpinPutsItAtTheTopOfTheBench() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let config = try String(contentsOf: sandbox.config, encoding: .utf8)
        try Data(config.replacingOccurrences(of: "topics:\n", with: "topics:\n  in_play: 1\n").utf8).write(to: sandbox.config)
        let environment = sandbox.cliEnvironment(pane: nil)
        // One place: the next Topics go to the Bench, each new one to its top.
        var ids: [String] = []
        for title in ["Pin in play", "Pin pinned", "Pin benched"] {
            ids.append(try await run(cli, arguments: ["topic", "new", title], environment: environment).stdout.trimmingCharacters(in: .newlines))
        }
        let (inPlay, pinned, benched) = (ids[0], ids[1], ids[2])
        let pin = try await run(cli, arguments: ["topic", "pin", "--topic", pinned], environment: environment)
        XCTAssertEqual(pin.status, 0, pin.output)
        let topics = try await topicList(sandbox: sandbox)
        XCTAssertEqual(topics.compactMap { $0["id"] as? String }, [pinned, inPlay, benched])
        XCTAssertEqual(topics.first?["pinned"] as? Bool, true)

        let unpin = try await run(cli, arguments: ["topic", "unpin", "--topic", pinned], environment: environment)
        XCTAssertEqual(unpin.status, 0, unpin.output)
        let after = try await topicList(sandbox: sandbox)
        XCTAssertFalse(after.contains { $0["pinned"] as? Bool == true }, "a Pin stays")
        XCTAssertEqual(after.compactMap { $0["id"] as? String }, [inPlay, pinned, benched], "Unpin puts the Topic at the top of the Bench")
    }

    func testTopicMoveStepsTheCardAndFailsAtTheEndOrForASettledTopic() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let environment = sandbox.cliEnvironment(pane: nil)
        func new(_ title: String) async throws -> String {
            try await run(cli, arguments: ["topic", "new", title], environment: environment).stdout.trimmingCharacters(in: .newlines)
        }
        func ids() async throws -> [String] { try await topicList(sandbox: sandbox).compactMap { $0["id"] as? String } }
        // The Settled Topic is Settled before the others exist, so the Open Place that it leaves is not between them.
        let settled = try await new("Move settled")
        let settle = try await run(cli, arguments: ["topic", "settle", "--topic", settled], environment: environment)
        XCTAssertEqual(settle.status, 0, settle.output)
        let top = try await new("Move top"), moved = try await new("Move moved")
        let chosen = try await run(cli, arguments: ["topic", "choose-in-play", "--topic", top, "--topic", moved], environment: environment)
        XCTAssertEqual(chosen.status, 0, chosen.output)
        let start = try await ids()
        XCTAssertEqual(Array(start.prefix(2)), [top, moved])

        let up = try await run(cli, arguments: ["topic", "move", "up", "--topic", moved], environment: environment)
        XCTAssertEqual(up.status, 0, up.output)
        let stepped = try await ids()
        XCTAssertEqual(Array(stepped.prefix(2)), [moved, top], "the card did not step up")

        let before = try await topicList(sandbox: sandbox)
        for (topic, kind) in [(moved, "card_at_end"), (settled, "topic_unavailable")] {
            let refused = try await run(cli, arguments: ["topic", "move", "up", "--topic", topic, "--json"], environment: environment)
            XCTAssertEqual(refused.status, 1, refused.output)
            XCTAssertEqual(try XCTUnwrap(try jsonLine(refused.stdout)["failed"] as? [String: Any], refused.stdout)["kind"] as? String, kind)
        }
        let after = try await topicList(sandbox: sandbox)
        XCTAssertEqual(after, before, "a failed move changed the order")
    }

    /// The app is a fake `open` first on the PATH, which the CLI runs through `/usr/bin/env`. A Linux Host with no Host
    /// Server's socket has no Muxify to reach, so there `topic open` fails and runs no `open`.
    func testTopicOpenHandsTheAppTheURLOfTheTopicAndFailsWithoutOne() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let fake = sandbox.root.appendingPathComponent("fake-open", isDirectory: true)
        try FileManager.default.createDirectory(at: fake, withIntermediateDirectories: true)
        let opened = fake.appendingPathComponent("opened")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$*\" >> \(Tmux.shellQuote(opened.path))\n".utf8).write(to: fake.appendingPathComponent("open"))
        XCTAssertEqual(chmod(fake.appendingPathComponent("open").path, 0o755), 0)
        let openedURLs = { (try? String(contentsOf: opened, encoding: .utf8)) ?? "" }
        let path = ["PATH": fake.path + ":/usr/bin:/bin"]
        let id = try await newTopic("Open view", in: sandbox.game, sandbox: sandbox)

        for (arguments, caller) in [(["topic", "open"], try sandbox.pane(of: "game/open-view")), (["topic", "open", "--topic", "Open view"], nil)] {
            let result = try await run(cli, arguments: arguments, environment: sandbox.cliEnvironment(pane: caller).merging(path) { $1 })
            #if os(macOS)
            XCTAssertEqual(result.status, 0, "\(arguments): \(result.output)")
            XCTAssertEqual(result.stdout, "", "\(arguments)")
            #else
            XCTAssertEqual(result.status, 1, "\(arguments): \(result.output)")
            XCTAssertTrue(result.stderr.contains("cannot reach Muxify"), "\(arguments): \(result.output)")
            #endif
        }
        #if os(macOS)
        let encoded = id.utf8.map { String(format: "%%%02x", $0) }.joined()
        let urls = String(repeating: "muxify://select?topic=\(encoded)\n", count: 2)
        #else
        let urls = ""
        #endif
        XCTAssertEqual(openedURLs(), urls)

        let missing = try await run(cli, arguments: ["topic", "open", "--topic", "No such topic"],
                                    environment: sandbox.cliEnvironment(pane: nil).merging(path) { $1 })
        XCTAssertNotEqual(missing.status, 0, missing.output)
        XCTAssertNotEqual(missing.stderr, "")
        XCTAssertEqual(openedURLs(), urls, "a failed topic open opened a URL")
    }
}

/// Windows and Sessions: window move, new, rename and kill, session new, rename, kill and move, remove-from-topic, session
/// list, the Sessions of one folder, and the git state of each Session of a Topic (topic status and diff).
final class CLIWindowAndSessionIntegrationTests: CLIIntegrationTestCase {
    func testRepeatedDirectorySessionsHaveIndependentNamesAndExactSelectors() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let id = try await newTopic("Repeated", in: sandbox.game, sandbox: sandbox)
        let environment = sandbox.cliEnvironment(pane: nil)
        let added = try await run(cli, arguments: ["topic", "add-session", sandbox.game.path, "--topic", id], environment: environment)
        XCTAssertEqual(added.status, 0, added.output)
        let record = try XCTUnwrap(sandbox.records().only)
        let sessions = record.sessions
        XCTAssertEqual(sessions.compactMap { $0["name"]?.string }, ["game/repeated", "game+2/repeated"])
        XCTAssertEqual(Set(sessions.compactMap { $0["id"]?.string }).count, 2)
        XCTAssertEqual(sessions.compactMap { $0["directory"]?.string }, [sandbox.game.path, sandbox.game.path])
        let listed = try await run(cli, arguments: ["session", "list", "--json"], environment: environment)
        let rows = try XCTUnwrap(try jsonLine(listed.stdout)["sessions"] as? [[String: Any]])
        XCTAssertEqual(rows.filter { ($0["name"] as? String)?.hasSuffix("/repeated") == true }.count, 2)
        XCTAssertEqual(rows.first { $0["name"] as? String == "game" }?["running"] as? Bool, false,
                       "same-folder Topic members do not occupy the exact launch name")
        let selected = try await run(cli, arguments: ["topic", "exec", "--topic", id, "--session", "game+2/repeated", "--", "pwd"], environment: environment)
        XCTAssertEqual(selected.status, 0, selected.output)
        XCTAssertEqual(selected.stdout, "==> game+2/repeated <==\n\(sandbox.game.path)\n")
        let settled = try await run(cli, arguments: ["topic", "settle", "--topic", id], environment: environment)
        XCTAssertEqual(settled.status, 0, settled.output)
        XCTAssertEqual(try sandbox.sessions(), ["game", "game+2", "main"], "default Settle keeps both Sessions without a Topic")
        XCTAssertEqual(try sandbox.topicOption(of: "game"), "")
        XCTAssertEqual(try sandbox.topicOption(of: "game+2"), "")
    }

    func testWindowMoveWithSeveralSameFolderDestinationsRequiresAnExplicitSession() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let id = try await newTopic("Destination", in: sandbox.game, sandbox: sandbox)
        let environment = sandbox.cliEnvironment(pane: nil)
        let added = try await run(cli, arguments: ["topic", "add-session", sandbox.game.path, "--topic", id], environment: environment)
        XCTAssertEqual(added.status, 0, added.output)
        try sandbox.tmux(["new-session", "-d", "-s", "loose", "-c", sandbox.tools.path])
        let window = try sandbox.tmux(["display-message", "-p", "-t", "=loose:", "#{window_id}"])
        let missing = try await run(cli, arguments: ["window", "move", "--window", window, "--topic", id], environment: environment)
        XCTAssertEqual(missing.status, 1, missing.output)
        XCTAssertEqual(try sandbox.tmux(["display-message", "-p", "-t", window, "#{session_name}"]), "loose")
        let moved = try await run(cli, arguments: ["window", "move", "--window", window, "--topic", id, "--session", "game+2/destination"], environment: environment)
        XCTAssertEqual(moved.status, 0, moved.output)
        XCTAssertEqual(try sandbox.tmux(["display-message", "-p", "-t", window, "#{session_name}"]), "game+2/destination")
    }

    func testWindowMoveNewSessionUsesCurrentDirectoryNotTheDestinationsRepository() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let id = try await newTopic("New destination", in: sandbox.game, sandbox: sandbox)
        try sandbox.tmux(["new-session", "-d", "-s", "custom", "-c", sandbox.tools.path])
        let window = try sandbox.tmux(["display-message", "-p", "-t", "=custom:", "#{window_id}"])
        let moved = try await run(cli, arguments: ["window", "move", "--window", window, "--topic", id, "--new-session"], environment: sandbox.cliEnvironment(pane: nil))
        XCTAssertEqual(moved.status, 0, moved.output)
        XCTAssertEqual(try sandbox.tmux(["display-message", "-p", "-t", window, "#{session_name}"]), "custom/new-destination")
        XCTAssertEqual(sandbox.real(try sandbox.tmux(["display-message", "-p", "-t", window, "#{session_path}"])), sandbox.tools.path)
    }

    func testWindowMoveMovesTheCallerPanesWindowIntoTheNamedTopic() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let id = try await newTopic("Ship", in: sandbox.game, sandbox: sandbox)
        try sandbox.tmux(["new-session", "-d", "-s", "loose", "-c", sandbox.tools.path])
        try sandbox.tmux(["new-window", "-d", "-t", "=loose:", "-c", sandbox.tools.path])
        let pane = try sandbox.pane(of: "loose")
        let result = try await run(cli, arguments: ["window", "move", "--topic", "Ship"], environment: sandbox.cliEnvironment(pane: pane))
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.stdout, id + "\n", "a write prints the id of the Topic it changed")
        XCTAssertEqual(result.stderr, "")
        let session = try sandbox.tmux(["display-message", "-p", "-t", pane.rawValue, "#{session_name}"])
        XCTAssertEqual(try sandbox.tmux(["show-options", "-qv", "-t", session + ":", "@muxify_topic"]), id)
        XCTAssertEqual(session, "game/ship", "a sole destination is selected regardless of folders")
        XCTAssertEqual(sandbox.repositoryPaths(of: try XCTUnwrap(sandbox.records().only)), [sandbox.game.path])
    }

    func testWindowMoveWithAPaneMovesItsWindowFromOutsideTmux() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let id = try await newTopic("Ship", in: sandbox.game, sandbox: sandbox)
        try sandbox.tmux(["new-session", "-d", "-s", "loose", "-c", sandbox.tools.path])
        try sandbox.tmux(["new-window", "-d", "-t", "=loose:", "-c", sandbox.tools.path])
        let pane = try sandbox.pane(of: "loose")
        let result = try await run(cli, arguments: ["window", "move", "--pane", pane.rawValue, "--topic", id],
                                   environment: sandbox.cliEnvironment(pane: nil))
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.stdout, id + "\n")
        XCTAssertEqual(try sandbox.topicOption(of: try sandbox.session(of: pane)), id)
        XCTAssertEqual(try sandbox.topicOption(of: "loose"), "", "the other Window of the Session stays out of the Topic")
    }

    func testWindowMoveToANewTopicWithAPaneMovesThatPaneAndNotTheCaller() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        try sandbox.tmux(["new-session", "-d", "-s", "loose", "-c", sandbox.game.path])
        try sandbox.tmux(["new-window", "-d", "-t", "=loose:", "-c", sandbox.game.path])
        let pane = try sandbox.pane(of: "loose")
        let caller = try sandbox.pane(of: "main")
        let result = try await run(cli, arguments: ["window", "move", "--new-topic", "--pane", pane.rawValue],
                                   environment: sandbox.cliEnvironment(pane: caller))
        XCTAssertEqual(result.status, 0, result.output)
        let record = try XCTUnwrap(sandbox.records().only)
        XCTAssertEqual(result.stdout, record.id + "\n")
        XCTAssertNil(record.title)
        XCTAssertEqual(try sandbox.session(of: pane), "loose/untitled-1")
        XCTAssertEqual(try sandbox.topicOption(of: "loose/untitled-1"), record.id)
        XCTAssertEqual(try sandbox.session(of: caller), "main", "the caller Pane stays")
    }

    func testTopicStatusGivesTheGitStatusOfEachSessionAndNullForAFolderInNoRepository() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        try sandbox.makeRepository(sandbox.tools)
        try Data("changed\n".utf8).write(to: sandbox.tools.appendingPathComponent("readme.txt"))
        let id = try await newTopic("Ship", in: sandbox.game, sandbox: sandbox)
        let added = try await run(cli, arguments: ["topic", "add-session", sandbox.tools.path, "--topic", id],
                                  environment: sandbox.cliEnvironment(pane: nil))
        XCTAssertEqual(added.status, 0, added.output)

        let json = try await run(cli, arguments: ["topic", "status", "--topic", id, "--json"], environment: sandbox.cliEnvironment(pane: nil))
        XCTAssertEqual(json.status, 0, json.output)
        let sessions = try XCTUnwrap(try jsonLine(json.stdout)["sessions"] as? [[String: Any]], json.stdout)
        XCTAssertEqual(sessions.map { $0["name"] as? String }, ["game/ship", "tools/ship"])
        XCTAssertTrue(sessions[0]["git"] is NSNull, "game is in no repository: \(json.stdout)")
        let git = try XCTUnwrap(sessions[1]["git"] as? [String: Any], json.stdout)
        XCTAssertEqual(git["branch"] as? String, "main")
        XCTAssertTrue(git["upstream"] is NSNull, json.stdout)
        XCTAssertEqual(git["changes"] as? [NSDictionary],
                       [["kind": "changed", "path": "readme.txt", "original_path": NSNull(), "index": ".", "worktree": "M"]])

        let text = try await run(cli, arguments: ["topic", "status"], environment: sandbox.cliEnvironment(pane: try sandbox.pane(of: "game/ship")))
        XCTAssertEqual(text.status, 0, text.output)
        XCTAssertEqual(text.stdout, "==> game/ship <==\nnot in a git repository\n==> tools/ship <==\n## main\n M readme.txt\n")
    }

    func testTopicDiffGivesOneChangesetAcrossTheSessionsFromEachBase() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        try sandbox.makeRepository(sandbox.game)
        let server = try sandbox.makeBareRepository("server", worktrees: ["main", "release"])
        let id = try await newTopic("Ship", in: sandbox.game, sandbox: sandbox)
        let added = try await run(cli, arguments: ["topic", "add-session", server.path + "/release", "--worktree", "--topic", id],
                                  environment: sandbox.cliEnvironment(pane: nil))
        XCTAssertEqual(added.status, 0, added.output)
        let worktree = sandbox.root.path + "/state/muxify/worktrees/server/ship"
        let recorded = try XCTUnwrap(sandbox.records().only?.sessions.compactMap { $0["base"]?.string }.first)
        // main moves on and the Worktree takes it, so the merge base with main is no longer the recorded base.
        try Data("main\n".utf8).write(to: URL(fileURLWithPath: server.path + "/main/main.txt"))
        _ = try sandbox.git(["add", "main.txt"], in: server.path + "/main")
        _ = try sandbox.git(["commit", "-q", "-m", "main"], in: server.path + "/main")
        _ = try sandbox.git(["merge", "-q", "--no-edit", "main"], in: worktree)
        try Data("shipped\n".utf8).write(to: URL(fileURLWithPath: worktree + "/ship.txt"))
        _ = try sandbox.git(["add", "ship.txt"], in: worktree)
        _ = try sandbox.git(["commit", "-q", "-m", "ship"], in: worktree)
        try Data("new\n".utf8).write(to: sandbox.game.appendingPathComponent("notes.txt"))

        let patch = try await run(cli, arguments: ["topic", "diff", "--topic", id], environment: sandbox.cliEnvironment(pane: nil))
        XCTAssertEqual(patch.status, 0, patch.output)
        XCTAssertEqual(patch.stdout.split(separator: "\n").filter { $0.hasPrefix("diff --git") },
                       ["diff --git a/game/ship/notes.txt b/game/ship/notes.txt", "diff --git a/server/release/ship/main.txt b/server/release/ship/main.txt",
                        "diff --git a/server/release/ship/ship.txt b/server/release/ship/ship.txt"],
                       "the untracked file of game and the commits of the Worktree since its recorded base: \(patch.stdout)")

        let stat = try await run(cli, arguments: ["topic", "diff", "--topic", id, "--stat"], environment: sandbox.cliEnvironment(pane: nil))
        XCTAssertEqual(stat.status, 0, stat.output)
        XCTAssertEqual(stat.stdout.split(separator: "\n").map { $0.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ") },
                       ["game/ship/notes.txt | 1 +", "server/release/ship/main.txt | 1 +", "server/release/ship/ship.txt | 1 +", "3 files changed, 3 insertions(+)"])

        let json = try await run(cli, arguments: ["topic", "diff", "--topic", id, "--json"], environment: sandbox.cliEnvironment(pane: nil))
        XCTAssertEqual(json.status, 0, json.output)
        let line = try jsonLine(json.stdout)
        XCTAssertEqual(line["patch"] as? String, patch.stdout)
        let sessions = try XCTUnwrap(line["sessions"] as? [[String: Any]], json.stdout)
        let git = try XCTUnwrap(sessions.first { $0["name"] as? String == "server/release/ship" }?["git"] as? [String: Any], json.stdout)
        XCTAssertEqual(git["base"] as? String, recorded, "the base that the Topic recorded for its Worktree")
        XCTAssertEqual(git["files"] as? [NSDictionary], [["path": "main.txt", "added": 1, "deleted": 0], ["path": "ship.txt", "added": 1, "deleted": 0]])
    }

    func testSessionPathListPrintsEachRowOfTheNewTopicListWithTheOpenTopicsThatUseIt() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        _ = try sandbox.makeBareRepository("server", worktrees: ["main", "release"])
        let id = try await newTopic("Ship\tit", in: sandbox.tools, sandbox: sandbox)
        let text = try await run(cli, arguments: ["session", "list"], environment: sandbox.cliEnvironment(pane: nil))
        XCTAssertEqual(text.status, 0, text.output)
        XCTAssertEqual(text.stderr, "")
        // The Config's glob spells /private/tmp as /tmp.
        let work = sandbox.root.path + "/work"
        let server = work + "/server"
        XCTAssertTrue(text.stdout.contains("tools/ship-it\trunning\t\(work)/tools\tShip it"), text.stdout)
        XCTAssertTrue(text.stdout.contains("game\tlaunchable\t\(work)/game\t"), text.stdout)
        XCTAssertTrue(text.stdout.contains("server/main\tlaunchable\t\(server)/main\t"), text.stdout)

        let json = try await run(cli, arguments: ["session", "list", "--json"], environment: sandbox.cliEnvironment(pane: nil))
        XCTAssertEqual(json.status, 0, json.output)
        let rows = try XCTUnwrap(try jsonLine(json.stdout)["sessions"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 6, json.stdout)
        XCTAssertEqual(Set(rows.compactMap { $0["name"] as? String }), ["main", "tools/ship-it", "game", "tools", "server/main", "server/release"])
        XCTAssertEqual((rows.first { $0["name"] as? String == "tools/ship-it" }?["topic"] as? [String: Any])?["id"] as? String, id)
        XCTAssertEqual(rows.filter { $0["running"] as? Bool == true }.count, 2)
    }

    func testSessionPathListGoesOnPastAConfigProblemAndPrintsItOnStderr() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        try Data("sessions:\n  paths:\n    - path: \(sandbox.root.path)/work/*\n  colour: red\n".utf8).write(to: sandbox.config)
        let result = try await run(cli, arguments: ["session", "list"], environment: sandbox.cliEnvironment(pane: nil))
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.stderr, "muxify: \(sandbox.config.path):4: unknown key \"sessions.colour\"\n")
        XCTAssertEqual(result.stdout.split(separator: "\n").map { $0.split(separator: "\t").first.map(String.init) },
                       ["main", "game", "tools"])
    }

    func testSessionRemoveFromTopicWithKillRemovesTheWorktreeThatTheTopicMadeAndKeepsTheBranch() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let server = try sandbox.makeBareRepository("server", worktrees: ["main"])
        let id = try await newTopic("Ship", in: sandbox.game, sandbox: sandbox)
        let environment = sandbox.cliEnvironment(pane: nil)
        let added = try await run(cli, arguments: ["topic", "add-session", server.path + "/main", "--worktree", "--topic", id], environment: environment)
        XCTAssertEqual(added.status, 0, added.output)
        let worktree = sandbox.root.path + "/state/muxify/worktrees/server/ship"
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree))

        let removed = try await run(cli, arguments: ["session", "remove-from-topic", "--kill", "--remove-worktree", "--session", "server/main/ship"],
                                    environment: environment)
        XCTAssertEqual(removed.status, 0, removed.output)
        XCTAssertEqual(try sandbox.sessions(), ["game/ship", "main"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree), "the Worktree that the Topic made is still there")
        XCTAssertEqual(try sandbox.git(["branch", "--list", "ship"], in: server.path), "ship", "the branch is gone")
        let sessions = try await topicSessions(id, sandbox: sandbox)
        XCTAssertEqual(sessions, ["game/ship"])

        let again = try await run(cli, arguments: ["session", "remove-from-topic", "--kill", "--remove-worktree", "--session", "game/ship"],
                                  environment: environment)
        XCTAssertEqual(again.status, 1, again.output)
        XCTAssertTrue(again.stderr.contains("no Worktree that Muxify made"), again.stderr)
        XCTAssertEqual(try sandbox.sessions(), ["game/ship", "main"], "a failed request killed the Session")
    }

    func testSessionAndWindowRemoveFromTopicLeaveThemRunningInNoTopic() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let id = try await newTopic("Ship", in: sandbox.game, sandbox: sandbox)
        let environment = sandbox.cliEnvironment(pane: nil)
        let added = try await run(cli, arguments: ["topic", "add-session", sandbox.tools.path, "--topic", id], environment: environment)
        XCTAssertEqual(added.status, 0, added.output)

        let session = try sandbox.tmux(["display-message", "-p", "-t", "=tools/ship:", "#{session_id}"])
        let removed = try await run(cli, arguments: ["session", "remove-from-topic", "--session", "tools/ship"], environment: environment)
        XCTAssertEqual(removed.status, 0, removed.output)
        let sessions = try await topicSessions(id, sandbox: sandbox)
        XCTAssertEqual(sessions, ["game/ship"])
        XCTAssertTrue(try sandbox.tmux(["list-sessions", "-F", "#{session_id}"]).split(separator: "\n").contains(Substring(session)),
                      "the removed Session stopped")
        XCTAssertEqual(try sandbox.tmux(["show-options", "-qv", "-t", session + ":", "@muxify_topic"]), "", "the Session is still in a Topic")

        let window = try sandbox.tmux(["new-window", "-d", "-P", "-F", "#{window_id}", "-t", "=game/ship:"])
        let intoTopic = try await run(cli, arguments: ["window", "remove-from-topic", "--window", window, "--session", "game/ship"],
                                      environment: environment)
        XCTAssertEqual(intoTopic.status, 1, "a Session in a Topic is no destination: \(intoTopic.output)")
        XCTAssertTrue(intoTopic.stderr.contains("is in the Topic"), intoTopic.stderr)
        let moved = try await run(cli, arguments: ["window", "remove-from-topic", "--window", window, "--new-session"], environment: environment)
        XCTAssertEqual(moved.status, 0, moved.output)
        XCTAssertNotEqual(try sandbox.tmux(["display-message", "-p", "-t", window, "#{session_name}"]), "game/ship", "the Window did not leave the Session")
        XCTAssertEqual(try sandbox.tmux(["show-options", "-qv", "-t", window, "@muxify_topic"]), "", "the Window is still in a Topic")
    }

    func testWindowNewInATopicGoesToItsOnlySessionAndFailsWithNoneOrSeveral() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let environment = sandbox.cliEnvironment(pane: nil)
        let empty = try await run(cli, arguments: ["topic", "new", "Window empty"], environment: environment).stdout.trimmingCharacters(in: .newlines)
        let none = try await run(cli, arguments: ["window", "new", "--topic", empty], environment: environment)
        XCTAssertEqual(none.status, 1, none.output)
        XCTAssertTrue(none.stderr.contains("muxify topic add-session <dir> --topic " + empty), none.stderr)

        let id = try await newTopic("Window one", in: sandbox.game, sandbox: sandbox)
        let marker = sandbox.root.appendingPathComponent("window-new-ran")
        let made = try await run(cli, arguments: ["window", "new", "--topic", id, "--json", "--", "sh", "-c", "pwd > \(Tmux.shellQuote(marker.path)); sleep 600"],
                                 environment: environment)
        XCTAssertEqual(made.status, 0, made.output)
        let window = try XCTUnwrap((try jsonLine(made.stdout)["changed"] as? [String: Any])?["window"] as? String, made.stdout)
        XCTAssertEqual(try sandbox.tmux(["display-message", "-p", "-t", window, "#{session_name}"]), "game/window-one")
        func ran() -> String { (try? String(contentsOf: marker, encoding: .utf8))?.trimmingCharacters(in: .newlines) ?? "" }
        try await wait("the command did not run in the new Window") { !ran().isEmpty }
        XCTAssertEqual(sandbox.real(ran()), sandbox.game.path)

        let added = try await run(cli, arguments: ["topic", "add-session", sandbox.tools.path, "--topic", id], environment: environment)
        XCTAssertEqual(added.status, 0, added.output)
        let windows = try sandbox.tmux(["list-windows", "-a", "-F", "#{window_id}"])
        let several = try await run(cli, arguments: ["window", "new", "--topic", id], environment: environment)
        XCTAssertEqual(several.status, 1, several.output)
        XCTAssertTrue(several.stderr.contains("Choose one with --session") && several.stderr.contains("tools/window-one ($"), several.stderr)
        XCTAssertEqual(try sandbox.tmux(["list-windows", "-a", "-F", "#{window_id}"]), windows, "a failed window new made a Window")
    }

    func testSessionNewStartsANoTopicSessionAndATakenNameGetsPlusTwo() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let environment = sandbox.cliEnvironment(pane: nil)
        var names: [String] = []
        for _ in 0..<2 {
            let made = try await run(cli, arguments: ["session", "new", sandbox.tools.path, "--json"], environment: environment)
            XCTAssertEqual(made.status, 0, made.output)
            let changed = try XCTUnwrap(try jsonLine(made.stdout)["changed"] as? [String: Any], made.stdout)
            names.append(try XCTUnwrap(changed["session_name"] as? String))
            let session = try XCTUnwrap(changed["session"] as? String)
            XCTAssertEqual(try sandbox.tmux(["show-options", "-qv", "-t", session + ":", "@muxify_topic"]), "", "the Session is in a Topic")
        }
        XCTAssertEqual(names, ["tools", "tools+2"])
        let named = try await run(cli, arguments: ["session", "new", sandbox.tools.path, "--name", "tools-debug"], environment: environment)
        XCTAssertEqual(named.status, 0, named.output)
        XCTAssertEqual(try sandbox.tmux(["display-message", "-p", "-t", named.stdout.trimmingCharacters(in: .newlines), "#{session_name}"]), "tools-debug")
    }

    func testSessionAndWindowRenameKeepTheTopicSlug() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let id = try await newTopic("Rename tmux", in: sandbox.game, sandbox: sandbox)
        let pane = try sandbox.pane(of: "game/rename-tmux")
        let renamed = try await run(cli, arguments: ["session", "rename", "renamed"], environment: sandbox.cliEnvironment(pane: pane))
        XCTAssertEqual(renamed.status, 0, renamed.output)
        XCTAssertEqual(renamed.stdout, "renamed/rename-tmux\n")
        XCTAssertEqual(try sandbox.tmux(["display-message", "-p", "-t", pane.rawValue, "#{session_name} #{@muxify_topic}"]), "renamed/rename-tmux " + id)
        let window = try await run(cli, arguments: ["window", "rename", "logs", "--pane", pane.rawValue], environment: sandbox.cliEnvironment(pane: nil))
        XCTAssertEqual(window.status, 0, window.output)
        XCTAssertEqual(try sandbox.tmux(["display-message", "-p", "-t", pane.rawValue, "#{window_id} #{window_name}"]),
                       window.stdout.trimmingCharacters(in: .newlines) + " logs")
    }

    func testWindowKillAndSessionKillFromTheirOwnPaneAndTheLastSessionLeavesTheTopicEmpty() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let id = try await newTopic("Kill", in: sandbox.game, sandbox: sandbox)
        // A Pane of the sandbox's server has the server's environment, which names no state folder or Config.
        func inPane(_ arguments: [String]) -> String {
            (["env", "XDG_STATE_HOME=" + sandbox.root.appendingPathComponent("state").path, "MUXIFY_CONFIG=" + sandbox.config.path, cli.path] + arguments)
                .map(Tmux.shellQuote).joined(separator: " ")
        }
        let window = try sandbox.tmux(["new-window", "-d", "-P", "-F", "#{window_id}", "-t", "=game/kill:"])
        let pane = try sandbox.tmux(["display-message", "-p", "-t", window, "#{pane_id}"])
        try sandbox.tmux(["respawn-pane", "-k", "-t", pane, inPane(["window", "kill"])])
        try await wait("window kill from its own Pane left the Window") {
            !(try sandbox.tmux(["list-windows", "-a", "-F", "#{window_id}"]).split(separator: "\n").contains(Substring(window)))
        }

        // The kill closes the Pane that runs the CLI, so the record must be written before the kill.
        try sandbox.tmux(["respawn-pane", "-k", "-t", try sandbox.pane(of: "game/kill").rawValue, inPane(["session", "kill"])])
        try await wait("session kill from its own Pane left the Session") { try sandbox.sessions() == ["main"] }
        let record = try XCTUnwrap(sandbox.records().only)
        XCTAssertNil(record.settledAt, "the Topic is not open")
        XCTAssertEqual(record.sessions, [], "the Topic is not Empty")

        let other = try await newTopic("Kill json", in: sandbox.tools, sandbox: sandbox)
        let killed = try await run(cli, arguments: ["session", "kill", "--session", "tools/kill-json", "--json"], environment: sandbox.cliEnvironment(pane: nil))
        XCTAssertEqual(killed.status, 0, killed.output)
        XCTAssertEqual((try jsonLine(killed.stdout)["changed"] as? [String: Any])?["topic_id"] as? String, other)
        XCTAssertNotEqual(other, id)
    }

    func testSessionMoveStepsASessionAmongItsTopicsSessionsAndSortSessionsGivesBackTheCreationOrder() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let environment = sandbox.cliEnvironment(pane: nil)
        let id = try await newTopic("Order", in: sandbox.game, sandbox: sandbox)
        let added = try await run(cli, arguments: ["topic", "add-session", sandbox.tools.path, "--topic", id], environment: environment)
        XCTAssertEqual(added.status, 0, added.output)
        let other = try await run(cli, arguments: ["topic", "new", "Other"], environment: environment)
        XCTAssertEqual(other.status, 0, other.output)
        let cards = try await topicList(sandbox: sandbox)
        let created = ["game/order", "tools/order"]
        let start = try await topicSessions(id, sandbox: sandbox)
        XCTAssertEqual(start, created)

        let up = try await run(cli, arguments: ["session", "move", "up", "--session", created[1]], environment: environment)
        XCTAssertEqual(up.status, 0, up.output)
        let stepped = try await topicSessions(id, sandbox: sandbox)
        XCTAssertEqual(stepped, Array(created.reversed()), "session move up did not step the Session")
        let after = try await topicList(sandbox: sandbox)
        XCTAssertEqual(after, cards, "session move moved a Topic card")
        let atEnd = try await run(cli, arguments: ["session", "move", "up", "--session", created[1], "--json"], environment: environment)
        XCTAssertEqual(atEnd.status, 1, atEnd.output)
        XCTAssertEqual(try XCTUnwrap(try jsonLine(atEnd.stdout)["failed"] as? [String: Any], atEnd.stdout)["kind"] as? String, "session_at_end")
        let unchanged = try await topicSessions(id, sandbox: sandbox)
        XCTAssertEqual(unchanged, Array(created.reversed()), "a failed move changed the order")

        let sorted = try await run(cli, arguments: ["topic", "sort-sessions"], environment: sandbox.cliEnvironment(pane: try sandbox.pane(of: created[0])))
        XCTAssertEqual(sorted.status, 0, sorted.output)
        XCTAssertEqual(sorted.stdout, id + "\n")
        let back = try await topicSessions(id, sandbox: sandbox)
        XCTAssertEqual(back, created, "topic sort-sessions did not give back the creation order")
    }

    func testWindowMoveBeforeAndAfterReordersTheWindowsOfASessionAndFailsForAnotherSessionsWindow() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        try sandbox.tmux(["new-session", "-d", "-s", "order", "-c", sandbox.root.path])
        for _ in 0..<2 { try sandbox.tmux(["new-window", "-d", "-t", "=order:"]) }
        func order() throws -> [String] { try sandbox.tmux(["list-windows", "-t", "=order", "-F", "#{window_id}"]).split(separator: "\n").map(String.init) }
        func current() throws -> String { try sandbox.tmux(["display-message", "-p", "-t", "=order:", "#{window_id}"]) }
        let windows = try order()
        let (a, b, c) = (windows[0], windows[1], windows[2])
        let shown = try current()

        let pane = try XCTUnwrap(PaneID(rawValue: try sandbox.tmux(["display-message", "-p", "-t", c, "#{pane_id}"])))
        let before = try await run(cli, arguments: ["window", "move", "--before", a], environment: sandbox.cliEnvironment(pane: pane))
        XCTAssertEqual(before.status, 0, before.output)
        XCTAssertEqual(before.stdout, c + "\n")
        XCTAssertEqual(try order(), [c, a, b], "window move --before from the Window's own Pane")

        let environment = sandbox.cliEnvironment(pane: nil)
        let after = try await run(cli, arguments: ["window", "move", "--after", b, "--window", c, "--json"], environment: environment)
        XCTAssertEqual(after.status, 0, after.output)
        XCTAssertEqual((try jsonLine(after.stdout)["changed"] as? [String: Any])?["window"] as? String, c)
        XCTAssertEqual(try order(), [a, b, c], "window move --after --window")
        XCTAssertEqual(try current(), shown, "the Session changed its current Window")

        let other = try sandbox.tmux(["display-message", "-p", "-t", "=main:", "#{window_id}"])
        let elsewhere = try await run(cli, arguments: ["window", "move", "--before", other, "--window", a, "--json"], environment: environment)
        XCTAssertEqual(elsewhere.status, 1, elsewhere.output)
        XCTAssertEqual(try XCTUnwrap(try jsonLine(elsewhere.stdout)["failed"] as? [String: Any], elsewhere.stdout)["kind"] as? String, "window_not_in_session")
        XCTAssertEqual(try order(), [a, b, c], "a failed move changed the order")
    }
}

/// topic exec: a command in the folder of each live Session of a Topic.
final class CLITopicExecIntegrationTests: CLIIntegrationTestCase {
    func testTopicExecRunsTheCommandInTheFolderOfEachLiveSessionAndTypesIntoNoPane() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let id = try await newTopic("Ship", in: sandbox.game, sandbox: sandbox)
        let added = try await run(cli, arguments: ["topic", "add-session", sandbox.tools.path, "--topic", id],
                                  environment: sandbox.cliEnvironment(pane: nil))
        XCTAssertEqual(added.status, 0, added.output)
        let heard = try ["game/ship", "tools/ship"].flatMap { try sandbox.listeners(in: $0) }

        let result = try await run(cli, arguments: ["topic", "exec", "--", "pwd"],
                                   environment: sandbox.cliEnvironment(pane: try sandbox.pane(of: "tools/ship")))
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.stdout, "==> game/ship <==\n\(sandbox.game.path)\n==> tools/ship <==\n\(sandbox.tools.path)\n")
        XCTAssertEqual(result.stderr, "")
        try await Task.sleep(nanoseconds: 300_000_000)
        for file in heard {
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "", "a Pane of the Topic got input: \(file.lastPathComponent)")
        }
    }

    func testTopicExecKeepsTheOutputOfACommandThatLeavesABackgroundProcess() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let id = try await newTopic("Ship", in: sandbox.game, sandbox: sandbox)
        let start = Date()
        let result = try await run(cli, arguments: ["topic", "exec", "--topic", id, "--", "sh", "-c", "echo first; /bin/sleep 3 & echo second"],
                                   environment: sandbox.cliEnvironment(pane: nil))
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.stdout, "==> game/ship <==\nfirst\nsecond\n")
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.5, "the background process is not waited for")
    }

    func testTopicExecRunsTheSessionsAtTheSameTimeAndSessionPathLimitsItToOneSession() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let id = try await newTopic("Ship", in: sandbox.game, sandbox: sandbox)
        let added = try await run(cli, arguments: ["topic", "add-session", sandbox.tools.path, "--topic", id],
                                  environment: sandbox.cliEnvironment(pane: nil))
        XCTAssertEqual(added.status, 0, added.output)

        let start = Date()
        let both = try await run(cli, arguments: ["topic", "exec", "--topic", id, "--", "/bin/sleep", "2"],
                                 environment: sandbox.cliEnvironment(pane: nil))
        XCTAssertEqual(both.status, 0, both.output)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3.5, "two runs of 2 s each took as long as one after the other")

        let one = try await run(cli, arguments: ["topic", "exec", "--topic", id, "--session", "tools/ship", "--", "pwd"],
                                environment: sandbox.cliEnvironment(pane: nil))
        XCTAssertEqual(one.status, 0, one.output)
        XCTAssertEqual(one.stdout, "==> tools/ship <==\n\(sandbox.tools.path)\n")

        let none = try await run(cli, arguments: ["topic", "exec", "--topic", id, "--session", "missing", "--", "pwd"],
                                 environment: sandbox.cliEnvironment(pane: nil))
        XCTAssertEqual(none.status, 1, none.output)
        XCTAssertEqual(none.stdout, "")
        XCTAssertEqual(none.stderr, "muxify: no live Session of the Topic Ship matches missing\n")
    }

    func testTopicExecReportsEachSessionsStatusAndOutputAndStopsARunAtTheTimeout() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let id = try await newTopic("Ship", in: sandbox.game, sandbox: sandbox)
        let added = try await run(cli, arguments: ["topic", "add-session", sandbox.tools.path, "--topic", id],
                                  environment: sandbox.cliEnvironment(pane: nil))
        XCTAssertEqual(added.status, 0, added.output)
        let script = "if [ \"${PWD##*/}\" = game ]; then exec /bin/sleep 30; fi; echo out; echo err >&2; exit 3"

        let start = Date()
        let result = try await run(cli, arguments: ["topic", "exec", "--topic", id, "--timeout", "0.5", "--json", "--", "sh", "-c", script],
                                   environment: sandbox.cliEnvironment(pane: nil))
        XCTAssertLessThan(Date().timeIntervalSince(start), 4, "the run that sleeps was not stopped at the timeout")
        XCTAssertEqual(result.status, 1, result.output)
        XCTAssertEqual(result.stderr, "muxify: topic exec: game/ship did not exit in 0.5 s; tools/ship exited with status 3\n")
        let line = try jsonLine(result.stdout)
        XCTAssertEqual(line["topic"] as? NSDictionary, ["id": id, "label": "Ship"] as NSDictionary)
        let sessions = try XCTUnwrap(line["sessions"] as? [[String: Any]], result.stdout)
        XCTAssertEqual(sessions.map { $0["name"] as? String }, ["game/ship", "tools/ship"])
        XCTAssertEqual(sessions.map { sandbox.real($0["directory"]) }, [sandbox.game.path, sandbox.tools.path], "the folder topic show gives")
        XCTAssertTrue(sessions[0]["status"] is NSNull, result.stdout)
        XCTAssertEqual(sessions[0]["timed_out"] as? Bool, true)
        XCTAssertEqual(sessions[1]["status"] as? Int, 3)
        XCTAssertEqual(sessions[1]["timed_out"] as? Bool, false)
        XCTAssertTrue(sessions[1]["error"] is NSNull, result.stdout)
        XCTAssertEqual(sessions[1]["stdout"] as? String, "out\n")
        XCTAssertEqual(sessions[1]["stderr"] as? String, "err\n")
    }
}

/// Muxify Worktrees: worktree create, list and remove, run in a repository folder, and the Worktree of a Topic.
final class CLIWorktreeIntegrationTests: CLIIntegrationTestCase {
    /// A .worktree.json in the format of the user's script, with a comment and trailing commas.
    private static let setup = """
        // The user's script reads this file too.
        {
          "sync": {
            "copyFiles": [".envrc", "missing.env",],
            "symlinkDirs": ["shared"],
          },
          "hooks": {
            "postCreate": ["echo \\"$MUXIFY_WORKTREE_NAME\\" > post-created.log"],
            "preDelete": ["echo \\"$MUXIFY_WORKTREE_BRANCH\\" >> ../pre-deleted.log"],
          },
        }
        """

    /// A repository in `work/<name>` with an uncommitted .worktree.json and the local files that it copies and links,
    /// all ignored.
    private func makeRepository(_ name: String, setup: String?, sandbox: TopicSandbox) throws -> URL {
        let folder = sandbox.root.appendingPathComponent("work/" + name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("shared"), withIntermediateDirectories: true)
        try Data(".worktree.json\n.envrc\nshared\n*.log\n".utf8).write(to: folder.appendingPathComponent(".gitignore"))
        for arguments in [["init", "-q", "-b", "main"], ["add", ".gitignore"], ["commit", "-q", "-m", "first"]] {
            _ = try sandbox.git(arguments, in: folder.path)
        }
        if let setup { try Data(setup.utf8).write(to: folder.appendingPathComponent(".worktree.json")) }
        try Data("export SECRET=1\n".utf8).write(to: folder.appendingPathComponent(".envrc"))
        return folder
    }

    private func worktree(_ repository: String, _ name: String, sandbox: TopicSandbox) -> URL {
        sandbox.root.appendingPathComponent("state/muxify/worktrees/\(repository)/\(name)", isDirectory: true)
    }

    /// The contents of the file, or "" while it is missing.
    private func text(_ file: URL) -> String { (try? String(contentsOf: file, encoding: .utf8)) ?? "" }

    func testWorktreeCreateSyncsRunsPostCreateAndMakesANoTopicSession() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let repository = try makeRepository("app", setup: Self.setup, sandbox: sandbox)
        let environment = sandbox.cliEnvironment(pane: nil)
        let made = try await run(cli, arguments: ["worktree", "create", "fix-login", "--no-open", "--json"], environment: environment, in: repository)
        XCTAssertEqual(made.status, 0, made.output)
        let change = try XCTUnwrap(try jsonLine(made.stdout)["changed"] as? [String: Any], made.stdout)
        let worktree = worktree("app", "fix-login", sandbox: sandbox)
        XCTAssertEqual(change["session_name"] as? String, "app/fix-login")
        XCTAssertTrue((change["output"] as? String)?.contains("skip copy (missing): missing.env") == true, "\(change)")
        XCTAssertEqual(text(worktree.appendingPathComponent(".envrc")), "export SECRET=1\n", "the setup did not copy .envrc")
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: worktree.appendingPathComponent("shared").path),
                        "the setup did not link shared")
        XCTAssertEqual(try sandbox.git(["symbolic-ref", "--short", "HEAD"], in: worktree.path), "fix-login")
        try await wait("postCreate did not run in the new Session") { !text(worktree.appendingPathComponent("post-created.log")).isEmpty }
        XCTAssertEqual(text(worktree.appendingPathComponent("post-created.log")), "fix-login\n")
        XCTAssertEqual(try sandbox.topicOption(of: "app/fix-login"), "", "the Session has a Topic")
        let record = try XCTUnwrap(sandbox.worktrees().only)
        XCTAssertEqual(record.id, change["worktree_id"] as? String)
        XCTAssertEqual(record.branch, "fix-login")
        XCTAssertEqual(record.path, worktree.path)

        let again = try await run(cli, arguments: ["worktree", "create", "fix-login", "--no-open"], environment: environment, in: repository)
        XCTAssertNotEqual(again.status, 0, again.output)
        XCTAssertTrue(again.stderr.contains("is already a Muxify Worktree"), again.stderr)
    }

    func testWorktreeListShowsOnlyTheMuxifyWorktreesOfTheRepository() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let repository = try makeRepository("app", setup: nil, sandbox: sandbox)
        let other = try makeRepository("other", setup: nil, sandbox: sandbox)
        _ = try sandbox.git(["worktree", "add", "-q", "-b", "by-hand", sandbox.root.appendingPathComponent("by-hand").path], in: repository.path)
        let environment = sandbox.cliEnvironment(pane: nil)
        for (folder, name) in [(repository, "listed"), (other, "elsewhere")] {
            let made = try await run(cli, arguments: ["worktree", "create", name, "--no-open"], environment: environment, in: folder)
            XCTAssertEqual(made.status, 0, made.output)
        }
        let listed = try await run(cli, arguments: ["worktree", "list"], environment: environment, in: repository)
        XCTAssertEqual(listed.status, 0, listed.output)
        let rows = listed.stdout.split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        XCTAssertEqual(rows.map { Array($0.prefix(3)) + [$0.count > 4 ? $0[4] : ""] }, [["listed", "listed", "clean", "app/listed"]], listed.stdout)
        let every = try await run(cli, arguments: ["worktree", "list", "--all", "--json"], environment: environment, in: sandbox.root)
        XCTAssertEqual(every.status, 0, every.output)
        let names = Set(try XCTUnwrap(try jsonLine(every.stdout)["worktrees"] as? [[String: Any]], every.stdout).compactMap { $0["name"] as? String })
        XCTAssertEqual(names, ["listed", "elsewhere"])
    }

    func testWorktreeRemoveNeedsKillForAUsedWorktreeRunsPreDeleteAndKeepsTheBranch() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let repository = try makeRepository("app", setup: Self.setup, sandbox: sandbox)
        let environment = sandbox.cliEnvironment(pane: nil)
        let made = try await run(cli, arguments: ["worktree", "create", "remove-me", "--no-open"], environment: environment, in: repository)
        XCTAssertEqual(made.status, 0, made.output)
        let worktree = worktree("app", "remove-me", sandbox: sandbox)
        try await wait("postCreate did not run") { !text(worktree.appendingPathComponent("post-created.log")).isEmpty }

        let refused = try await run(cli, arguments: ["worktree", "remove", "remove-me"], environment: environment, in: repository)
        XCTAssertNotEqual(refused.status, 0, refused.output)
        XCTAssertTrue(refused.stderr.contains("app/remove-me"), refused.stderr)
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.path), "a refused Remove removed the Worktree")

        let removed = try await run(cli, arguments: ["worktree", "remove", "remove-me", "--kill"], environment: environment, in: repository)
        XCTAssertEqual(removed.status, 0, removed.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree.path), "Remove kept the Worktree")
        XCTAssertEqual(text(worktree.deletingLastPathComponent().appendingPathComponent("pre-deleted.log")), "remove-me\n",
                       "preDelete did not run in the Worktree")
        XCTAssertEqual(try sandbox.sessions(), ["main"], "--kill kept the Session")
        XCTAssertEqual(try sandbox.git(["branch", "--list", "remove-me"], in: repository.path), "remove-me", "Remove deleted the branch")
        XCTAssertEqual(try sandbox.worktrees(), [], "Remove kept the record")
    }

    func testATopicsWorktreeGetsARecordAndRemoveMakesTheTopicForgetIt() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let repository = try makeRepository("app", setup: Self.setup, sandbox: sandbox)
        let environment = sandbox.cliEnvironment(pane: nil)
        let id = try await run(cli, arguments: ["topic", "new", "Worktree topic"], environment: environment).stdout.trimmingCharacters(in: .newlines)
        let added = try await run(cli, arguments: ["topic", "add-session", repository.path, "--worktree", "--topic", id], environment: environment)
        XCTAssertEqual(added.status, 0, added.output)
        let worktree = worktree("app", "worktree-topic", sandbox: sandbox)
        XCTAssertEqual(text(worktree.appendingPathComponent(".envrc")), "export SECRET=1\n", "the Topic Worktree did not get its sync")
        try await wait("postCreate did not run in the Topic Session") { !text(worktree.appendingPathComponent("post-created.log")).isEmpty }
        let record = try XCTUnwrap(sandbox.worktrees().only)
        XCTAssertEqual(try XCTUnwrap(sandbox.records().only).sessions.compactMap { $0["worktree_id"]?.string }, [record.id])
        let listed = try await run(cli, arguments: ["worktree", "list", "--json"], environment: environment, in: repository)
        let shown = try XCTUnwrap(try jsonLine(listed.stdout)["worktrees"] as? [[String: Any]], listed.stdout).first { $0["id"] as? String == record.id }
        XCTAssertEqual(shown?["topic"] as? String, "Worktree topic")

        let removed = try await run(cli, arguments: ["worktree", "remove", "worktree-topic", "--kill"], environment: environment, in: repository)
        XCTAssertEqual(removed.status, 0, removed.output)
        XCTAssertEqual(try XCTUnwrap(sandbox.records().only).sessions.filter { $0["worktree_path"]?.string != nil }, [],
                       "the Topic still remembers the removed Worktree")
    }
}

/// Agents, their Unread marks, and what topic show gives of a Topic's Sessions and Agents. The command line itself: the
/// installed binary, --version, environment show, the Config and --request.
final class CLIAgentAndEnvironmentIntegrationTests: CLIIntegrationTestCase {
    /// A copy of the binary with no resource bundle or app beside it, run from its folder and through a symlink, as an
    /// install leaves it. A test build has no stamp, and `--version` needs no tmux, no Config and no records file.
    func testARelocatedBinaryAndItsSymlinkPrintTheHelpRejectAnUnknownVerbAndGiveTheVersion() async throws {
        let tool = try standaloneCLI()
        defer { try? FileManager.default.removeItem(at: tool.deletingLastPathComponent()) }
        let link = tool.deletingLastPathComponent().appendingPathComponent("installed-muxify")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tool)
        for executable in [tool, link] {
            let help = try await run(executable, arguments: ["--help"])
            XCTAssertEqual(help.status, 0, "\(executable.lastPathComponent): \(help.output)")
            XCTAssertTrue(help.output.contains("usage: muxify browser open"), executable.lastPathComponent)
            let unknown = try await run(executable, arguments: ["unknown"])
            XCTAssertEqual(unknown.status, 2, executable.lastPathComponent)
        }
        let missing = tool.deletingLastPathComponent().appendingPathComponent("missing").path
        let version = try await run(tool, arguments: ["--version"], environment: [
            "PATH": missing, "HOME": missing, "XDG_STATE_HOME": missing, "XDG_CONFIG_HOME": missing,
            "MUXIFY_CONFIG": missing + "/config.yaml", "TMUX_TMPDIR": missing,
        ])
        XCTAssertEqual(version.status, 0, version.stderr)
        XCTAssertEqual(version.stdout, "muxify dev 0\n")
        XCTAssertEqual(version.stderr, "")
    }

    /// `muxify server` speaks the Host Server protocol on stdin and stdout: `hello`, then `ping`, and it exits 0
    /// when stdin ends.
    func testServerAnswersHelloAndPingAndExitsZeroOnStdinEOF() async throws {
        let server = try startServer()
        defer { stopIfRunning(server.process) }
        let session = try await server.client.connect()
        XCTAssertEqual(session.protocolVersion, 1)
        XCTAssertEqual(session.peerBuild, "muxify dev 0")
        try await server.client.ping()
        server.client.close()
        try await waitForExit(server.process)
        XCTAssertEqual(server.process.terminationStatus, 0)
        XCTAssertTrue(server.stderr().contains("muxify server: exits, stdin ended"))
    }

    func testServerExitsZeroOnShutdown() async throws {
        let server = try startServer()
        defer { stopIfRunning(server.process) }
        try await server.client.connect()
        try await server.client.call(HostRequest.shutdown)
        try await waitForExit(server.process)
        XCTAssertEqual(server.process.terminationStatus, 0)
        XCTAssertTrue(server.stderr().contains("muxify server: exits, asked to shut down"))
    }

    func testServerExitsAfterTheSilenceTimeout() async throws {
        let server = try startServer(environment: ["MUXIFY_SERVER_SILENCE": "0.5"])
        defer { stopIfRunning(server.process) }
        try await server.client.connect()
        try await server.client.ping()
        let start = Date()
        try await waitForExit(server.process)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.4)
        XCTAssertEqual(server.process.terminationStatus, 0)
        XCTAssertTrue(server.stderr().contains("muxify server: exits, no frame came in time"))
    }

    /// The `snapshot` subscription of `muxify server` is the JSON of `environment show --json` without `capabilities`
    /// for the same state, and `topic new` on the same muxify.db pushes the next item.
    func testAServersSnapshotItemIsEnvironmentShowWithoutCapabilities() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        _ = try await newTopic("Ship", in: sandbox.game, sandbox: sandbox)
        let environment = sandbox.cliEnvironment(pane: nil)
        let server = try startServer(environment: environment, capabilities: ["snapshot"])
        defer { stopIfRunning(server.process) }
        try await server.client.connect()
        let items = JSONItems()
        let stream = server.client.subscribe(HostRequest.subscribe(.snapshot), as: JSONValue.self)
        let consumer = Task {
            do {
                for try await item in stream { items.add(item) }
            } catch {}
        }
        defer { consumer.cancel() }

        func shown() async throws -> JSONValue {
            let result = try await run(self.cli, arguments: ["environment", "show", "--json"], environment: environment)
            XCTAssertEqual(result.status, 0, result.output)
            guard case .object(var keys) = try JSONDecoder().decode(JSONValue.self, from: Data(result.stdout.utf8)) else {
                throw CLIError("environment show printed no object: \(result.stdout)")
            }
            XCTAssertNotNil(keys.removeValue(forKey: "capabilities"), "the CLI lists its capabilities")
            return .object(keys)
        }
        // A Pane's shell may still draw its prompt or name its Window, which the next item shows: the last item and
        // what the CLI prints agree once tmux settled.
        func assertAgree(_ message: String) async throws {
            var printed = try await shown()
            let deadline = Date().addingTimeInterval(10)
            while items.last != printed, Date() < deadline {
                try await Task.sleep(for: .milliseconds(200))
                printed = try await shown()
            }
            XCTAssertEqual(items.last, printed, message)
        }
        try await assertAgree("the snapshot item is environment show --json without capabilities")
        guard case .object(let keys)? = items.last else { return XCTFail("no snapshot item") }
        XCTAssertEqual(keys["sidebar"], .object(["topics": .bool(true), "sessions": .bool(true)]))

        let made = try await run(cli, arguments: ["topic", "new", "Other"], environment: environment)
        XCTAssertEqual(made.status, 0, made.output)
        let id = made.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        func text(_ item: JSONValue?) -> String { item.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) } ?? "" }
        try await wait("topic new pushed no snapshot item with its Topic") { text(items.last).contains("\"\(id)\"") }
        try await assertAgree("the item after topic new is environment show --json without capabilities")
    }

    /// The JSON items of a subscription, as they came.
    private final class JSONItems: @unchecked Sendable {
        private let lock = NSLock()
        private var log: [JSONValue] = []

        func add(_ item: JSONValue) { lock.lock(); log.append(item); lock.unlock() }
        var last: JSONValue? { lock.lock(); defer { lock.unlock() }; return log.last }
    }

    /// A running `muxify server` with a protocol client on its stdout and stdin, and its stderr.
    private func startServer(environment: [String: String] = [:], capabilities: [String] = []) throws
        -> (process: Process, client: ProtocolClient, stderr: () -> String) {
        let output = Pipe()
        let errors = Pipe()
        let input = Pipe()
        let process = makeProcess(cli, arguments: ["server"], output: output, errors: errors, environment: environment)
        process.standardInput = input
        try process.run()
        let client = ProtocolClient(input: output.fileHandleForReading, output: input.fileHandleForWriting, build: "muxify test",
                                    capabilities: capabilities)
        return (process, client, { String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) })
    }

    /// The `topic` subscription's item is the JSON that `muxify topic show --json` prints for the same Topic and state.
    func testServerTopicItemIsTheJSONOfTopicShow() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let id = try await newTopic("Ship", in: sandbox.game, sandbox: sandbox)
        _ = try sandbox.fakeAgent(in: "game/ship", status: "blocked", unread: true)
        let server = try startServer(environment: sandbox.cliEnvironment(pane: nil), capabilities: ["topic-detail"])
        defer { stopIfRunning(server.process) }
        try await server.client.connect()
        let latest = LatestTopicItem()
        let events = server.client.subscribe(HostRequest.subscribe(.topic(TopicSubscription(id: id))), as: TopicDetailItem.self)
        let consumer = Task {
            do { for try await item in events { latest.set(item) } } catch {}
        }
        defer { consumer.cancel() }

        // The server writes the Topic's remembered Sessions after its first read, so the two agree once it settled.
        var item: Any?, shown: Any?
        for _ in 0..<50 {
            let result = try await run(cli, arguments: ["topic", "show", "--topic", id, "--json"], environment: sandbox.cliEnvironment(pane: nil))
            XCTAssertEqual(result.status, 0, result.output)
            shown = try jsonLine(result.stdout)
            item = try latest.json()
            if let item = item as? NSDictionary, let shown = shown as? NSDictionary, item == shown { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let sessions = (shown as? [String: Any])?["topic"].flatMap { ($0 as? [String: Any])?["sessions"] as? [Any] }
        XCTAssertEqual(sessions?.count, 1, "\(String(describing: shown))")
        XCTAssertEqual(item as? NSDictionary, shown as? NSDictionary)
    }

    func testTopicShowListsEveryLiveSessionOfTheTopicAndTheStatusOfItsAgent() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let id = try await newTopic("Ship", in: sandbox.game, sandbox: sandbox)
        let added = try await run(cli, arguments: ["topic", "add-session", sandbox.tools.path, "--topic", id],
                                  environment: sandbox.cliEnvironment(pane: nil))
        XCTAssertEqual(added.status, 0, added.output)
        let agent = try sandbox.fakeAgent(in: "game/ship", status: "blocked", unread: true)
        let shell = try sandbox.pane(of: "tools/ship")
        let tagged = try await run(cli, arguments: ["topic", "tag", "add", "#backend", "--topic", id], environment: sandbox.cliEnvironment(pane: nil))
        XCTAssertEqual(tagged.status, 0, tagged.output)

        let result = try await run(cli, arguments: ["topic", "show", "--topic", "Ship", "--json"], environment: sandbox.cliEnvironment(pane: nil))
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.stderr, "")
        let topic = try XCTUnwrap(try jsonLine(result.stdout)["topic"] as? [String: Any], result.stdout)
        XCTAssertEqual(topic["id"] as? String, id)
        XCTAssertEqual(topic["label"] as? String, "Ship")
        XCTAssertEqual(topic["tags"] as? [String], ["backend"])
        let sessions = try XCTUnwrap(topic["sessions"] as? [[String: Any]], result.stdout)
        XCTAssertEqual(sessions.map { $0["name"] as? String }, ["game/ship", "tools/ship"])
        XCTAssertEqual(sessions.map { $0["base_name"] as? String }, ["game", "tools"])
        let panes = sessions.flatMap { ($0["windows"] as? [[String: Any]] ?? []).flatMap { $0["panes"] as? [[String: Any]] ?? [] } }
        let agentPane = try XCTUnwrap(panes.first { $0["id"] as? String == agent.rawValue }, result.stdout)
        XCTAssertEqual(agentPane["agent"] as? NSDictionary, ["kind": "claude", "status": "blocked", "unread": true, "conversation": NSNull()] as NSDictionary)
        let shellPane = try XCTUnwrap(panes.first { $0["id"] as? String == shell.rawValue }, result.stdout)
        XCTAssertTrue(shellPane["agent"] is NSNull, "a shell Pane has no Agent: \(shellPane)")
    }

    func testTopicShowPrintsTheCallerPanesTopicAndALineForEachSession() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let id = try await newTopic("Ship", in: sandbox.game, sandbox: sandbox)
        let added = try await run(cli, arguments: ["topic", "add-session", sandbox.tools.path, "--topic", id],
                                  environment: sandbox.cliEnvironment(pane: nil))
        XCTAssertEqual(added.status, 0, added.output)
        let tagged = try await run(cli, arguments: ["topic", "tag", "set", "release", "backend", "--topic", id],
                                   environment: sandbox.cliEnvironment(pane: nil))
        XCTAssertEqual(tagged.status, 0, tagged.output)
        let agent = try sandbox.fakeAgent(in: "tools/ship", status: nil, unread: false)
        let result = try await run(cli, arguments: ["topic", "show"], environment: sandbox.cliEnvironment(pane: agent))
        XCTAssertEqual(result.status, 0, result.output)
        // The Config's glob spells /private/tmp as /tmp.
        let work = sandbox.root.path + "/work"
        XCTAssertEqual(result.stdout, "\(id)\tShip\t#backend #release\ngame/ship\tgame\t\(work)/game\t\ntools/ship\ttools\t\(work)/tools\t\n")
    }

    func testTopicShowGivesTheWorktreeOfASessionAndTheBranchItHasNow() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let server = try sandbox.makeBareRepository("server", worktrees: ["main", "release"])
        let id = try await newTopic("Ship", in: sandbox.game, sandbox: sandbox)
        let added = try await run(cli, arguments: ["topic", "add-session", server.path + "/release", "--worktree", "--topic", id],
                                  environment: sandbox.cliEnvironment(pane: nil))
        XCTAssertEqual(added.status, 0, added.output)
        let worktree = sandbox.root.path + "/state/muxify/worktrees/server/ship"

        let json = try await run(cli, arguments: ["topic", "show", "--topic", id, "--json"], environment: sandbox.cliEnvironment(pane: nil))
        XCTAssertEqual(json.status, 0, json.output)
        let sessions = try XCTUnwrap((try jsonLine(json.stdout)["topic"] as? [String: Any])?["sessions"] as? [[String: Any]], json.stdout)
        let entry = try XCTUnwrap(sessions.first { $0["name"] as? String == "server/release/ship" }?["worktree"] as? [String: Any], json.stdout)
        XCTAssertEqual(sandbox.real(entry["path"]), worktree)
        XCTAssertEqual(entry["branch"] as? String, "ship", "the Topic branch")

        let text = try await run(cli, arguments: ["topic", "show", "--topic", id], environment: sandbox.cliEnvironment(pane: nil))
        XCTAssertEqual(text.status, 0, text.output)
        let fields = try XCTUnwrap(text.stdout.split(separator: "\n").first { $0.hasPrefix("server/release/ship\t") }, text.stdout)
            .split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(fields.count, 4, text.stdout)
        XCTAssertEqual(sandbox.real(fields[2]), worktree, "the folder of the Session is its Worktree")
        XCTAssertEqual(fields[3], "ship")

        try sandbox.git(["switch", "-q", "-c", "ship-review"], in: worktree)
        let switched = try await run(cli, arguments: ["topic", "show", "--topic", id], environment: sandbox.cliEnvironment(pane: nil))
        XCTAssertEqual(switched.status, 0, switched.output)
        let line = switched.stdout.split(separator: "\n").first { $0.hasPrefix("server/release/ship\t") }
        XCTAssertEqual(line?.split(separator: "\t").last, "ship-review",
                       "the branch the Worktree has now, not the one the record remembers: \(switched.stdout)")
    }

    func testAgentListPrintsEachAgentWithItsStatusUnreadAndTopic() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let id = try await newTopic("Ship", in: sandbox.game, sandbox: sandbox)
        let blocked = try sandbox.fakeAgent(in: "game/ship", status: "blocked", unread: true, conversation: "conv-1")
        let working = try sandbox.fakeAgent(in: "main", status: "working", unread: false)
        let fresh = try sandbox.fakeAgent(in: "main", status: nil, unread: false)
        let environment = sandbox.cliEnvironment(pane: nil)

        let all = try await run(cli, arguments: ["agent", "list"], environment: environment)
        XCTAssertEqual(all.status, 0, all.output)
        XCTAssertEqual(all.stderr, "")
        XCTAssertEqual(Set(all.stdout.split(separator: "\n").map(String.init)), [
            "\(blocked.rawValue)\tclaude\tblocked\tunread\tShip\tgame/ship",
            "\(working.rawValue)\tclaude\tworking\t\t\tmain",
            "\(fresh.rawValue)\tclaude\t\t\t\tmain",
        ])

        let inTopic = try await run(cli, arguments: ["agent", "list", "--topic", "Ship", "--json"], environment: environment)
        XCTAssertEqual(inTopic.status, 0, inTopic.output)
        let rows = try XCTUnwrap(try jsonLine(inTopic.stdout)["agents"] as? [[String: Any]], inTopic.stdout)
        XCTAssertEqual(rows.map { $0["pane_id"] as? String }, [blocked.rawValue])
        XCTAssertEqual(rows.first?["topic"] as? NSDictionary, ["id": id, "label": "Ship", "pinned": false, "tags": [String]()] as NSDictionary)
        XCTAssertEqual(rows.first?["agent"] as? NSDictionary, ["kind": "claude", "status": "blocked", "unread": true, "conversation": "conv-1"] as NSDictionary)

        for (filter, expected) in [(["--status", "working"], [working]), (["--unread"], [blocked])] {
            let result = try await run(cli, arguments: ["agent", "list"] + filter, environment: environment)
            XCTAssertEqual(result.status, 0, result.output)
            XCTAssertEqual(result.stdout.split(separator: "\n").map { String($0.prefix { $0 != "\t" }) }, expected.map(\.rawValue),
                           "\(filter)")
        }
    }

    /// A Claude Transcript in a folder of its own, which CLAUDE_CONFIG_DIR names: two turns, each with one Bash call.
    private func claudeTranscript(id: String) throws -> (environment: [String: String], file: URL) {
        let config = FileManager.default.temporaryDirectory.appendingPathComponent("muxify-claude-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: config) }
        let file = config.appendingPathComponent("projects/-work/\(id).jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let records = (0..<2).flatMap { turn in [
            #"{"type":"user","timestamp":"2026-10-18T09:0\#(turn):00Z","message":{"role":"user","content":"ask \#(turn)"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t\#(turn)","name":"Bash","input":{"command":"make"}}]}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t\#(turn)","content":"PASS \#(turn)"}]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"answer \#(turn) \#(String(repeating: "x", count: 30))"}]}}"#,
        ] }
        try Data((records.joined(separator: "\n") + "\n").utf8).write(to: file)
        // The CLI names the file that it found, which is under /private/var, not the /var symlink.
        let real = try XCTUnwrap(realpath(file.path, nil))
        defer { free(real) }
        return (["CLAUDE_CONFIG_DIR": config.path], URL(fileURLWithPath: String(cString: real)))
    }

    func testAgentConversationReadsTheTranscriptOfThePanesAgent() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let agent = try sandbox.fakeAgent(in: "main", status: "done", unread: false, conversation: "conv-1")
        let transcript = try claudeTranscript(id: "conv-1")
        let environment = sandbox.cliEnvironment(pane: nil).merging(transcript.environment) { $1 }

        let read = try await run(cli, arguments: ["agent", "conversation", agent.rawValue, "--json", "--max-chars", "10"], environment: environment)
        XCTAssertEqual(read.status, 0, read.output)
        let lines = try read.stdout.split(separator: "\n").map { try XCTUnwrap(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? NSDictionary) }
        XCTAssertEqual(lines.first, ["kind": "claude", "conversation": "conv-1", "transcript": transcript.file.path] as NSDictionary)
        XCTAssertEqual(lines.dropFirst().map { $0["index"] as? Int }, [0, 3, 4, 7], "user and assistant Entries keep their index")
        XCTAssertEqual(lines[1], ["index": 0, "at": "2026-10-18T09:00:00Z", "role": "user", "tool": NSNull(), "text": "ask 0",
                                  "chars": 5, "truncated": false] as NSDictionary)
        XCTAssertEqual(lines[2]["truncated"] as? Bool, true)
        XCTAssertEqual(read.stderr, "muxify: showed 4 of 4 user and assistant Entries (index 0..7); 4 tool Entries hidden; "
                       + "2 Entries cut at 10 characters. Use --tools, --range or --full to read more.\n")

        let tools = try await run(cli, arguments: ["agent", "conversation", agent.rawValue, "--tool", "bash", "--after", "4"], environment: environment)
        XCTAssertEqual(tools.status, 0, tools.output)
        XCTAssertEqual(tools.stdout, """
        ==> claude conv-1 \(transcript.file.path) <==
        [5] tool_call Bash
        {"command":"make"}

        [6] tool_result Bash
        PASS 1


        """)

        let info = try await run(cli, arguments: ["agent", "conversation", "--transcript", transcript.file.path, "--info", "--json"],
                                 environment: environment)
        XCTAssertEqual(info.status, 0, info.output)
        XCTAssertEqual(try jsonLine(info.stdout) as NSDictionary, [
            "kind": "claude", "conversation": NSNull(), "transcript": transcript.file.path, "entries": 8,
            "first_at": "2026-10-18T09:00:00Z", "last_at": "2026-10-18T09:01:00Z",
            "roles": ["user": 2, "assistant": 2, "tool_call": 2, "tool_result": 2],
        ] as NSDictionary)
    }

    func testAgentConversationFailsWithoutAnAgentAConversationIdOrATranscript() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let transcript = try claudeTranscript(id: "conv-1")
        let environment = sandbox.cliEnvironment(pane: nil).merging(transcript.environment) { $1 }
        let shell = try sandbox.pane(of: "main")
        let fresh = try sandbox.fakeAgent(in: "main", status: nil, unread: false)
        let notTranscript = transcript.file.deletingLastPathComponent().appendingPathComponent("notes.jsonl")
        try Data("{\"type\":\"note\"}\n".utf8).write(to: notTranscript)
        let folder = try XCTUnwrap(transcript.environment["CLAUDE_CONFIG_DIR"]) + "/projects"
        let cases: [([String], String)] = [
            ([shell.rawValue], "No Agent runs in Pane \(shell.rawValue)."),
            ([fresh.rawValue], "The Agent in Pane \(fresh.rawValue) has no conversation id yet."),
            (["%999"], "No tmux Pane %999."),
            (["--conversation", "nope", "--kind", "claude"], "No Transcript of claude conversation nope in \(folder)."),
            (["--transcript", notTranscript.path], "No Entries could be read as claude from \(notTranscript.path)."),
        ]
        for (arguments, message) in cases {
            let result = try await run(cli, arguments: ["agent", "conversation"] + arguments, environment: environment)
            XCTAssertEqual(result.status, 1, "\(arguments): \(result.output)")
            XCTAssertEqual(result.stdout, "", "\(arguments)")
            XCTAssertEqual(result.stderr, "muxify: \(message)\n", "\(arguments)")
        }
    }

    func testTopicShowListsTheConversationsOfItsLiveAndRememberedAgentsOnlyWhenAsked() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let id = try await newTopic("Ship", in: sandbox.game, sandbox: sandbox)
        _ = try sandbox.fakeAgent(in: "game/ship", status: "done", unread: false, conversation: "live-1")
        let environment = sandbox.cliEnvironment(pane: nil)

        let plain = try await run(cli, arguments: ["topic", "show", "--topic", id], environment: environment)
        XCTAssertEqual(plain.status, 0, plain.output)
        XCTAssertFalse(plain.stdout.contains("conversation"), plain.stdout)

        let text = try await run(cli, arguments: ["topic", "show", "--topic", id, "--conversations"], environment: environment)
        XCTAssertEqual(text.status, 0, text.output)
        XCTAssertEqual(text.stdout, plain.stdout + "conversation\tclaude\tlive-1\n")

        let json = try await run(cli, arguments: ["topic", "show", "--topic", id, "--conversations", "--json"], environment: environment)
        XCTAssertEqual(json.status, 0, json.output)
        let object = try jsonLine(json.stdout)
        XCTAssertEqual((object["topic"] as? [String: Any])?["id"] as? String, id)
        XCTAssertEqual(object["conversations"] as? [NSDictionary], [["kind": "claude", "conversation": "live-1"]])
    }

    func testAgentListWithATopicThatIsNotOpenFails() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let result = try await run(cli, arguments: ["agent", "list", "--topic", "Nope"], environment: sandbox.cliEnvironment(pane: nil))
        XCTAssertEqual(result.status, 1, result.output)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "muxify: No open Topic matches Nope.\n")
    }

    func testMarkReadVerbsChangeTheTopicAndEachAgentInTheirScopeAndMarkAllReadClearsBoth() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let id = try await newTopic("Read", in: sandbox.game, sandbox: sandbox)
        let done = try sandbox.fakeAgent(in: "game/read", status: "done", unread: false)
        let working = try sandbox.fakeAgent(in: "game/read", status: "working", unread: false)
        let other = try sandbox.fakeAgent(in: "main", status: "done", unread: false)
        let environment = sandbox.cliEnvironment(pane: nil)
        /// Unread of the Topic, then of the done and the working Agent in it, then of the Agent outside it.
        func state() throws -> [Bool] {
            try [XCTUnwrap(sandbox.records().only).isUnread] + [done, working, other].map {
                try sandbox.tmux(["display-message", "-p", "-t", $0.rawValue, "#{@muxify_agent_unread}"]) == "1"
            }
        }
        func readChanged(_ result: CLIRun) throws -> NSDictionary? { try jsonLine(result.stdout)["read_changed"] as? NSDictionary }

        let marked = try await run(cli, arguments: ["topic", "mark-unread", "--topic", id, "--json"], environment: environment)
        XCTAssertEqual(marked.status, 0, marked.output)
        XCTAssertEqual(try readChanged(marked), ["topic_ids": [id], "pane_ids": [done.rawValue]] as NSDictionary)
        XCTAssertEqual(try state(), [true, true, false, false], "Mark Unread changes the Topic and each Agent in it that is not working")

        for changed in [[id], []] {
            let only = try await run(cli, arguments: ["topic", "mark-read", "--topic-only", "--topic", id, "--json"], environment: environment)
            XCTAssertEqual(only.status, 0, only.output)
            XCTAssertEqual(try readChanged(only), ["topic_ids": changed, "pane_ids": [String]()] as NSDictionary)
            XCTAssertEqual(try state(), [false, true, false, false], "--topic-only changed an Agent, or left the Topic Unread")
        }
        let again = try await run(cli, arguments: ["topic", "mark-unread", "--topic", id], environment: environment)
        XCTAssertEqual(again.status, 0, again.output)

        let read = try await run(cli, arguments: ["agent", "mark-read"], environment: sandbox.cliEnvironment(pane: done))
        XCTAssertEqual(read.status, 0, read.output)
        XCTAssertEqual(try state(), [true, false, false, false], "agent mark-read changes only the Agent of its Pane")

        let window = try await run(cli, arguments: ["window", "mark-unread", "--pane", done.rawValue], environment: environment)
        XCTAssertEqual(window.status, 0, window.output)
        XCTAssertEqual(try state(), [true, true, false, false], "window mark-unread changes only the Agents of that Window")

        let unread = try await run(cli, arguments: ["agent", "mark-unread"], environment: sandbox.cliEnvironment(pane: other))
        XCTAssertEqual(unread.status, 0, unread.output)
        let cleared = try await run(cli, arguments: ["mark-all-read", "--json"], environment: environment)
        XCTAssertEqual(cleared.status, 0, cleared.output)
        XCTAssertEqual(try state(), [false, false, false, false], "mark-all-read left an Unread")
    }

    func testATopicEditStopsWithTheConfigSyntaxError() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        try Data("sessions: [\n".utf8).write(to: sandbox.config)
        let result = try await run(cli, arguments: ["topic", "new", "Ship"], environment: sandbox.cliEnvironment(pane: try sandbox.pane(of: "main")))
        XCTAssertEqual(result.status, 1, result.output)
        XCTAssertEqual(result.output, "muxify: \(sandbox.config.path):2: while parsing a flow node: did not find expected node content\n")
        XCTAssertEqual(try sandbox.records().count, 0)
        XCTAssertEqual(try sandbox.sessions(), ["main"])
    }

    // MARK: - Browser

    /// With no app on the server, `browser tabs` lists the Tabs that the app shows when it starts: the stored
    /// Tabs, then the queued opens. A queued page that a Tab already has selects that Tab, as in the app.
    func testBrowserTabsWithoutTheAppListsTheStoredTabsAndTheQueuedOpens() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let pane = try sandbox.pane(of: "main")
        let window = try sandbox.tmux(["display-message", "-p", "-t", pane.rawValue, "#{window_id}"])
        _ = try sandbox.tmux(["set-option", "-w", "-t", window, "@muxify_tabs", "https://github.com/ about:blank"])
        _ = try sandbox.tmux(["set-option", "-w", "-t", window, "@muxify_active_tab", "1"])
        _ = try sandbox.tmux(["set-option", "-w", "-t", window, "@muxify_open",
                              " example.com https://GitHub.com#readme https://example.com/"])
        let expected = [
            BrowserAgentTab(id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
                            url: "https://github.com/", title: "", active: false),
            BrowserAgentTab(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                            url: "https://example.com", title: "", active: true),
        ]

        let noApp = try await run(cli, arguments: ["browser", "tabs", "--json"], environment: sandbox.cliEnvironment(pane: pane))
        XCTAssertEqual(noApp.status, 0, noApp.output)
        XCTAssertEqual(try JSONDecoder().decode([BrowserAgentTab].self, from: Data(noApp.output.utf8)), expected)

        // An app that stopped without removing its socket option is no app either.
        _ = try sandbox.tmux(["set-option", "-s", BrowserAgentChannel.option, sandbox.root.appendingPathComponent("gone.sock").path])
        let stale = try await run(cli, arguments: ["browser", "tabs", "--window", window, "--json"],
                                  environment: sandbox.cliEnvironment(pane: nil))
        XCTAssertEqual(stale.status, 0, stale.output)
        XCTAssertEqual(try JSONDecoder().decode([BrowserAgentTab].self, from: Data(stale.output.utf8)), expected)
        XCTAssertEqual(try sandbox.tmux(["show-options", "-wqv", "-t", window, "@muxify_open"]),
                       "example.com https://GitHub.com#readme https://example.com/", "a read leaves the queue for the app")
    }

    /// The phone reads a Window's Tabs from its Host Server: `browser_tabs` answers the JSON that `muxify browser tabs
    /// --window <id> --json` prints with no Mac, and an unknown Window fails with the CLI's words.
    func testTheHostServersBrowserTabsAnswerTheJSONThatTheCLIPrintsWithNoMac() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let window = try sandbox.tmux(["display-message", "-p", "-t", try sandbox.pane(of: "main").rawValue, "#{window_id}"])
        _ = try sandbox.tmux(["set-option", "-w", "-t", window, "@muxify_tabs", "https://github.com/ about:blank https://example.com/a"])
        _ = try sandbox.tmux(["set-option", "-w", "-t", window, "@muxify_active_tab", "2"])
        _ = try sandbox.tmux(["set-option", "-w", "-t", window, "@muxify_open", "https://GitHub.com#readme"])
        let environment = sandbox.cliEnvironment(pane: nil)
        let server = try startServer(environment: environment, capabilities: [HostCapability.browserTabs.rawValue])
        defer { stopIfRunning(server.process) }
        try await server.client.connect()

        let printed = try await run(cli, arguments: ["browser", "tabs", "--window", window, "--json"], environment: environment)
        XCTAssertEqual(printed.status, 0, printed.output)
        let answer = try await server.client.call(HostRequest.browserTabs(BrowserTabsRequest(window: window)), as: JSONValue.self)
        XCTAssertEqual(answer, try JSONDecoder().decode(JSONValue.self, from: Data(printed.stdout.utf8)), printed.stdout)
        XCTAssertEqual(try JSONDecoder().decode([BrowserAgentTab].self, from: Data(printed.stdout.utf8)).map(\.active), [true, false, false],
                       "the queued page that the first Tab has selects it")

        let unknown = try await run(cli, arguments: ["browser", "tabs", "--window", "@999", "--json"], environment: environment)
        XCTAssertEqual(unknown.status, 1, unknown.output)
        do {
            _ = try await server.client.call(HostRequest.browserTabs(BrowserTabsRequest(window: "@999")), as: JSONValue.self)
            XCTFail("an unknown Window must not end ok")
        } catch let error as ProtocolError {
            XCTAssertEqual(error.code, .failed)
            XCTAssertEqual("muxify: \(error.message)\n", unknown.stderr)
        }
    }

    // MARK: - Requests

    func testTopicNewTwiceWithOneRequestMakesOneTopicAndPrintsTheSameJSON() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let environment = sandbox.cliEnvironment(pane: nil)
        let request = UUID().uuidString
        let first = try await run(cli, arguments: ["topic", "new", "Fix login", "--json", "--request", request], environment: environment)
        XCTAssertEqual(first.status, 0, first.output)
        let id = try XCTUnwrap(try XCTUnwrap(try jsonLine(first.stdout)["changed"] as? [String: Any])["topic_id"] as? String)
        XCTAssertEqual(id, request.lowercased(), "the Topic of a Request has the Request's id")
        // The option goes anywhere before `--`, and its id is the same in upper and lower case.
        let second = try await run(cli, arguments: ["--request=" + request.lowercased(), "topic", "new", "Fix login", "--json"], environment: environment)
        XCTAssertEqual(second.status, 0, second.output)
        XCTAssertEqual(second.stdout, first.stdout)
        XCTAssertEqual(second.stderr, "")
        XCTAssertEqual(try sandbox.records().compactMap(\.slug), ["fix-login"], "one Topic, and no fix-login-2")

        let other = try await run(cli, arguments: ["topic", "new", "Fix login", "--json", "--request", UUID().uuidString], environment: environment)
        XCTAssertEqual(other.status, 0, other.output)
        XCTAssertEqual(try sandbox.records().compactMap(\.slug).sorted(), ["fix-login", "fix-login-2"], "a new id runs the command")
    }

    func testARequestIDWithOtherArgumentsFailsWithItsOwnStatusAndChangesNothing() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let environment = sandbox.cliEnvironment(pane: nil)
        let request = UUID().uuidString.lowercased()
        let first = try await run(cli, arguments: ["topic", "new", "Fix login", "--request", request], environment: environment)
        XCTAssertEqual(first.status, 0, first.output)
        for arguments in [["topic", "new", "Other"], ["topic", "rename", "Other", "--topic", request]] {
            let mismatch = try await run(cli, arguments: arguments + ["--request", request], environment: environment)
            XCTAssertEqual(mismatch.status, 3, mismatch.output)
            XCTAssertEqual(mismatch.stdout, "")
            XCTAssertTrue(mismatch.stderr.contains(request) && mismatch.stderr.contains("topic new"), mismatch.stderr)
        }
        XCTAssertEqual(try sandbox.records().map(\.title), ["Fix login"])
    }

    func testARefusalIsKeptSoASecondSendGetsItAgainWithoutANewJudgment() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let environment = sandbox.cliEnvironment(pane: nil)
        let made = try await run(cli, arguments: ["topic", "new", "Ship"], environment: environment)
        XCTAssertEqual(made.status, 0, made.output)
        let request = UUID().uuidString
        let tag = ["topic", "tag", "add", "bazel", "--topic", "Ship", "--json"]
        let refused = try await run(cli, arguments: tag + ["--request", request], environment: environment)
        XCTAssertEqual(refused.status, 1, refused.output)
        XCTAssertEqual(try XCTUnwrap(try jsonLine(refused.stdout)["failed"] as? [String: Any])["kind"] as? String, "tag_undefined")

        try Data("sessions:\n  paths:\n    - path: \(sandbox.root.path)/work/*\ntopics:\n  tags:\n    bazel: {}\n".utf8).write(to: sandbox.config)
        let again = try await run(cli, arguments: tag + ["--request", request], environment: environment)
        XCTAssertEqual(again.status, refused.status)
        XCTAssertEqual(again.stdout, refused.stdout)
        XCTAssertEqual(again.stderr, refused.stderr)
        XCTAssertEqual(try XCTUnwrap(sandbox.records().only).tags, [], "the second send changes nothing")

        let fresh = try await run(cli, arguments: tag + ["--request", UUID().uuidString], environment: environment)
        XCTAssertEqual(fresh.status, 0, fresh.output)
        XCTAssertEqual(try XCTUnwrap(sandbox.records().only).tags.map(\.name).sorted(), ["bazel"], "a new Request sees the Tag that the Config has now")
    }

    func testAFailureThatCanChangeIsNotKeptSoTheSameRequestCanRunLater() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let pane = try sandbox.pane(of: "main")
        let request = UUID().uuidString
        let arguments = ["window", "new", "--json", "--request", request]
        try sandbox.stopServer()
        let stopped = try await run(cli, arguments: arguments, environment: sandbox.cliEnvironment(pane: pane))
        XCTAssertEqual(stopped.status, 1, stopped.output)
        XCTAssertEqual(try XCTUnwrap(try jsonLine(stopped.stdout)["failed"] as? [String: Any])["kind"] as? String, "tmux_failed")

        try sandbox.startServer()
        XCTAssertEqual(try sandbox.pane(of: "main"), pane, "the new server gives its first Pane the same id")
        let windows = try sandbox.tmux(["list-windows", "-a", "-F", "#{window_id}"]).split(separator: "\n").count
        let started = try await run(cli, arguments: arguments, environment: sandbox.cliEnvironment(pane: pane))
        XCTAssertEqual(started.status, 0, started.output)
        XCTAssertEqual(try sandbox.tmux(["list-windows", "-a", "-F", "#{window_id}"]).split(separator: "\n").count, windows + 1)

        let again = try await run(cli, arguments: arguments, environment: sandbox.cliEnvironment(pane: pane))
        XCTAssertEqual(again.stdout, started.stdout)
        XCTAssertEqual(try sandbox.tmux(["list-windows", "-a", "-F", "#{window_id}"]).split(separator: "\n").count, windows + 1,
                       "the success is kept: a third send makes no second Window")
    }

    /// A run that ends after its record write leaves the changed records and a `started` row.
    func testARequestThatChangedTheRecordsAndDidNotFinishRunsAgainOnlyWhenItsVerbConverges() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let environment = sandbox.cliEnvironment(pane: nil)

        let new = UUID().uuidString.lowercased()
        let made = try await run(cli, arguments: ["topic", "new", "Fix login", "--json", "--request", new], environment: environment)
        XCTAssertEqual(made.status, 0, made.output)
        try sandbox.leaveStarted(new)
        let converged = try await run(cli, arguments: ["topic", "new", "Fix login", "--json", "--request", new], environment: environment)
        XCTAssertEqual(converged.status, 0, converged.output)
        XCTAssertEqual(converged.stdout, made.stdout, "topic new finds the Topic that has the Request's id")
        XCTAssertEqual(try sandbox.records().compactMap(\.slug), ["fix-login"])
        XCTAssertEqual(try sandbox.requestState(new), "done")

        let other = try await run(cli, arguments: ["topic", "new", "Plan"], environment: environment)
        XCTAssertEqual(other.status, 0, other.output)
        let move = UUID().uuidString.lowercased()
        let listed = try await run(cli, arguments: ["topic", "list"], environment: environment).stdout
        let top = try XCTUnwrap(listed.split(separator: "\n").first?.split(separator: "\t").first.map(String.init))
        let moved = try await run(cli, arguments: ["topic", "move", "down", "--topic", top, "--request", move], environment: environment)
        XCTAssertEqual(moved.status, 0, moved.output)
        let order = try await run(cli, arguments: ["topic", "list"], environment: environment).stdout
        try sandbox.leaveStarted(move)
        let doubt = try await run(cli, arguments: ["topic", "move", "down", "--topic", top, "--request", move], environment: environment)
        XCTAssertEqual(doubt.status, 4, doubt.output)
        XCTAssertEqual(doubt.stdout, "")
        XCTAssertTrue(doubt.stderr.contains(move) && doubt.stderr.contains("topic move"), doubt.stderr)
        let after = try await run(cli, arguments: ["topic", "list"], environment: environment).stdout
        XCTAssertEqual(after, order, "a move does not run a second time")
        XCTAssertEqual(try sandbox.requestState(move), "started")
    }

    func testSessionNewTwiceWithOneRequestMakesOneSessionAndPrintsTheSameJSON() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let environment = sandbox.cliEnvironment(pane: nil)
        let arguments = ["session", "new", sandbox.game.path, "--name", "api", "--json", "--request", UUID().uuidString.lowercased()]
        let first = try await run(cli, arguments: arguments, environment: environment)
        XCTAssertEqual(first.status, 0, first.output)
        let again = try await run(cli, arguments: arguments, environment: environment)
        XCTAssertEqual(again.status, 0, again.output)
        XCTAssertEqual(again.stdout, first.stdout)
        XCTAssertEqual(try sandbox.sessions(), ["api", "main"], "one Session, and no api+2")
    }

    func testAddSessionWithANameAndARequestMakesOneSession() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let environment = sandbox.cliEnvironment(pane: nil)
        let made = try await run(cli, arguments: ["topic", "new", "Ship"], environment: environment)
        XCTAssertEqual(made.status, 0, made.output)
        let request = UUID().uuidString.lowercased()
        let add = ["topic", "add-session", sandbox.game.path, "--name", "api", "--topic", "Ship", "--json", "--request", request]
        let first = try await run(cli, arguments: add, environment: environment)
        XCTAssertEqual(first.status, 0, first.output)
        XCTAssertEqual(try XCTUnwrap(try jsonLine(first.stdout)["changed"] as? [String: Any])["session_name"] as? String, "api/ship")
        try sandbox.leaveStarted(request)
        let again = try await run(cli, arguments: add, environment: environment)
        XCTAssertEqual(again.status, 0, again.output)
        XCTAssertEqual(try sandbox.sessions(), ["api/ship", "main"])
        XCTAssertEqual(try XCTUnwrap(sandbox.records().only).sessions.count, 1, "the record gains no second entry")

        let unnamed = UUID().uuidString.lowercased()
        let plain = ["topic", "add-session", sandbox.game.path, "--topic", "Ship", "--request", unnamed]
        let added = try await run(cli, arguments: plain, environment: environment)
        XCTAssertEqual(added.status, 0, added.output)
        try sandbox.leaveStarted(unnamed)
        let doubt = try await run(cli, arguments: plain, environment: environment)
        XCTAssertEqual(doubt.status, 4, "without a name, a second run would make a second Session: " + doubt.output)
        XCTAssertEqual(try sandbox.sessions(), ["api/ship", "game/ship", "main"])
    }

    func testEnvironmentShowJSONListsTheCapabilitiesAndAReadRefusesARequest() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let environment = sandbox.cliEnvironment(pane: nil)
        let shown = try await run(cli, arguments: ["environment", "show", "--json"], environment: environment)
        XCTAssertEqual(shown.status, 0, shown.output)
        XCTAssertTrue(shown.stdout.contains(#""capabilities":["request","session-paths"]"#), shown.stdout)
        XCTAssertEqual(try jsonLine(shown.stdout)["capabilities"] as? [String], ["request", "session-paths"])
        let text = try await run(cli, arguments: ["environment", "show"], environment: environment)
        XCTAssertFalse(text.stdout.contains("capabilities"), text.stdout)

        for verb in [["environment", "show"], ["topic", "list"], ["topic", "exec", "--topic", "Ship", "--request", UUID().uuidString, "--", "true"],
                     ["session", "list"], ["agent", "list"]] {
            let arguments = verb.contains("--") ? verb : verb + ["--request", UUID().uuidString]
            let refused = try await run(cli, arguments: arguments, environment: environment)
            XCTAssertEqual(refused.status, 2, refused.output)
            XCTAssertEqual(refused.stdout, "")
            XCTAssertTrue(refused.stderr.contains(verb.prefix(2).joined(separator: " ")) && refused.stderr.contains("--request"), refused.stderr)
        }
        let bad = try await run(cli, arguments: ["topic", "new", "Ship", "--request", "soon"], environment: environment)
        XCTAssertEqual(bad.status, 2, bad.output)
        XCTAssertEqual(try sandbox.records().count, 0)
        // After `--`, the words are the command's own.
        XCTAssertNoThrow(try CLICommand(arguments: ["topic", "exec", "--topic", "Ship", "--", "echo", "--request", "soon"], environment: [:]))
    }

    func testSessionPathsRanksByTheLastVisitAndByTheQueryAndAVisitRequestAppliesOnce() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let environment = sandbox.cliEnvironment(pane: nil)
        let source = sandbox.tools.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        func rows(_ arguments: [String] = []) async throws -> [[String: Any]] {
            let listed = try await run(cli, arguments: ["session-paths", "--json"] + arguments, environment: environment)
            XCTAssertEqual(listed.status, 0, listed.output)
            return try XCTUnwrap(try jsonLine(listed.stdout)["rows"] as? [[String: Any]])
        }
        func names(_ rows: [[String: Any]]) -> [String] { rows.compactMap { $0["name"] as? String } }
        let visits = VisitStore(paths: MuxifyPaths(environment: environment, home: "/nonexistent"))

        let unvisited = try await rows()
        XCTAssertEqual(names(unvisited), ["game", "tools"], "with no visit, the order of the Config")
        XCTAssertTrue(unvisited.allSatisfy { $0["last_visit"] is NSNull && $0["in_this_topic"] == nil && $0["kind"] as? String == "session_path" })

        let request = UUID().uuidString
        let visit = try await run(cli, arguments: ["session-paths", "visit", source.path, "--json", "--request", request], environment: environment)
        XCTAssertEqual(visit.status, 0, visit.output)
        let visited = try XCTUnwrap(try jsonLine(visit.stdout)["visited"] as? [String: String])
        XCTAssertEqual(visited["directory"], sandbox.tools.path, "the visit is to the Session Path that holds the folder")
        let stamp = try XCTUnwrap(visited["last_visit"])
        let time = try XCTUnwrap(ISO8601DateFormatter().date(from: stamp), stamp)
        XCTAssertLessThan(abs(time.timeIntervalSinceNow), 60)
        let saved = try XCTUnwrap(try visits.times()[.directory(sandbox.tools.path)])

        let ranked = try await rows()
        XCTAssertEqual(names(ranked), ["tools", "game"], "the last visited first")
        XCTAssertEqual(ranked[0]["last_visit"] as? String, stamp)
        let text = try await run(cli, arguments: ["session-paths"], environment: environment)
        XCTAssertEqual(text.stdout, "tools\tsession_path\t\(sandbox.tools.path)\t\(stamp)\ngame\tsession_path\t\(sandbox.game.path)\t\n")

        let again = try await run(cli, arguments: ["session-paths", "visit", source.path, "--json", "--request", request], environment: environment)
        XCTAssertEqual(again.stdout, visit.stdout)
        XCTAssertEqual(again.status, 0, again.output)
        XCTAssertEqual(try visits.times()[.directory(sandbox.tools.path)], saved, "a second send of the Request records no new visit")
        let other = try await run(cli, arguments: ["session-paths", "visit", source.path, "--request", UUID().uuidString], environment: environment)
        XCTAssertEqual(other.stdout, sandbox.tools.path + "\n")
        XCTAssertGreaterThan(try XCTUnwrap(try visits.times()[.directory(sandbox.tools.path)]), saved, "a new id is a new visit")

        let matches = try await rows(["--query", "gam"])
        XCTAssertEqual(names(matches), ["game"])
        let all = try await rows(["--query", "work"])
        XCTAssertEqual(names(all), ["game", "tools"], "an equal match of the folder: the shorter title first, as in Go to…")
        let none = try await rows(["--query", "zzz"])
        XCTAssertEqual(names(none), [])

        let id = try await newTopic("Ship", in: sandbox.game, sandbox: sandbox)
        let topic = try await run(cli, arguments: ["topic", "session-paths", "--topic", id, "--json"], environment: environment)
        let topicRows = try XCTUnwrap(try jsonLine(topic.stdout)["rows"] as? [[String: Any]])
        XCTAssertEqual(topicRows.map { $0["last_visit"] as? String }, [nil, try visits.times()[.directory(sandbox.tools.path)].map(ISO8601DateFormatter().string)])
        XCTAssertEqual(topicRows.map { $0["in_this_topic"] as? Bool }, [true, false])

        let missing = try await run(cli, arguments: ["session-paths", "visit", sandbox.root.appendingPathComponent("missing").path,
                                                     "--request", UUID().uuidString], environment: environment)
        XCTAssertEqual(missing.status, 2, missing.output)
        let read = try await run(cli, arguments: ["session-paths", "--request", UUID().uuidString], environment: environment)
        XCTAssertEqual(read.status, 2, "a read takes no Request: \(read.output)")
    }

    /// The fake git takes 3 seconds for each call, so an answer that waited for the discovery, or a refresh that
    /// held the answer's pipes, would not be back in 2.
    func testSessionPathsAnswersFromTheDiscoveryCacheAndFindsTheFoldersAgainAfterTheAnswer() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        // Discovery runs git only in a repository.
        try sandbox.makeRepository(sandbox.game)
        var environment = sandbox.cliEnvironment(pane: nil)
        func names() async throws -> [String] {
            let listed = try await run(cli, arguments: ["session-paths", "--json"], environment: environment)
            XCTAssertEqual(listed.status, 0, listed.output)
            return try XCTUnwrap(try jsonLine(listed.stdout)["rows"] as? [[String: Any]]).compactMap { $0["name"] as? String }
        }
        let cache = MuxifyPaths(environment: environment, home: "/nonexistent").sessionPathCache(remote: nil)
        let first = try await names()
        XCTAssertEqual(first, ["game", "tools"], "with no cache, the answer waits for the discovery")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path), "and saves it")

        try FileManager.default.createDirectory(at: sandbox.root.appendingPathComponent("work/late"), withIntermediateDirectories: true)
        let bin = sandbox.root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data("#!/bin/sh\nsleep 3\nexec /usr/bin/git \"$@\"\n".utf8).write(to: bin.appendingPathComponent("git"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("git").path)
        environment["PATH"] = bin.path + ":/usr/bin:/bin"

        let start = Date()
        let cached = try await names()
        XCTAssertLessThan(Date().timeIntervalSince(start), 2, "the answer does not wait for git")
        XCTAssertEqual(cached, ["game", "tools"], "the answer is the cache's")
        XCTAssertEqual((try? String(contentsOf: cache, encoding: .utf8))?.contains("late"), false, "the discovery is still running")

        let deadline = Date().addingTimeInterval(30)
        var refreshed = false
        while !refreshed, Date() < deadline {
            refreshed = (try? String(contentsOf: cache, encoding: .utf8))?.contains("late") == true
            if !refreshed { try await Task.sleep(for: .milliseconds(100)) }
        }
        XCTAssertTrue(refreshed, "the refresh that the answer started saved the new folder")
        environment["PATH"] = "/usr/bin:/bin"
        let later = try await names()
        XCTAssertEqual(later, ["game", "late", "tools"])
    }

    /// `muxify server` through pipes, as the phone reaches it, against the CLI on the same Config, cache and visits.
    func testTheHostServerAnswersSessionPathsAsTheCLIPrintsThemAndAVisitOfEitherRanksForBoth() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let environment = sandbox.cliEnvironment(pane: nil)
        let source = sandbox.tools.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let up = Pipe(), down = Pipe(), errors = Pipe()
        let server = makeProcess(cli, arguments: ["server"], output: down, errors: errors, environment: environment)
        server.standardInput = up
        try server.run()
        defer { stopIfRunning(server) }
        let client = ProtocolClient(input: down.fileHandleForReading, output: up.fileHandleForWriting, build: "phone",
                                    capabilities: [HostCapability.rankedSessionPaths.rawValue], helloTimeout: 10)
        defer { client.close() }
        try await client.connect()

        func object(_ value: some Encodable) throws -> NSDictionary {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return try XCTUnwrap(try JSONSerialization.jsonObject(with: try encoder.encode(value)) as? NSDictionary)
        }
        func printed(_ arguments: [String]) async throws -> NSDictionary {
            let listed = try await run(cli, arguments: arguments + ["--json"], environment: environment)
            XCTAssertEqual(listed.status, 0, listed.output)
            return try jsonLine(listed.stdout) as NSDictionary
        }
        func answered(_ ask: SessionPathsRequest.Ask) async throws -> NSDictionary {
            if case .topic = ask {
                return try object(try await client.call(HostRequest.sessionPaths(SessionPathsRequest(ask)), as: TopicSessionPathsAnswer.self))
            }
            return try object(try await client.call(HostRequest.sessionPaths(SessionPathsRequest(ask)), as: RankedSessionPathsAnswer.self))
        }
        func names(_ answer: NSDictionary) -> [String] { (answer["rows"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String } }

        let unvisited = try await answered(.ranked(query: ""))
        XCTAssertEqual(names(unvisited), ["game", "tools"])
        let printedUnvisited = try await printed(["session-paths"])
        XCTAssertEqual(unvisited, printedUnvisited)
        let empty = try await client.call(HostRequest.sessionPaths(try JSONDecoder().decode(SessionPathsRequest.self, from: Data("{}".utf8))),
                                          as: RankedSessionPathsAnswer.self)
        XCTAssertEqual(try object(empty), unvisited, "session_paths {} is the ranking for an empty query")

        _ = try await client.call(HostRequest.visitSessionPath(VisitSessionPath(folder: source.path)), as: ProtocolEmpty.self)
        let afterServerVisit = try await printed(["session-paths"])
        XCTAssertEqual(names(afterServerVisit), ["tools", "game"], "the server's visit ranks the Session Path first for the CLI")
        let answeredAfterServerVisit = try await answered(.ranked(query: ""))
        XCTAssertEqual(answeredAfterServerVisit, afterServerVisit)

        let visited = try await run(cli, arguments: ["session-paths", "visit", sandbox.game.path], environment: environment)
        XCTAssertEqual(visited.status, 0, visited.output)
        let afterCLIVisit = try await answered(.ranked(query: ""))
        XCTAssertEqual(names(afterCLIVisit), ["game", "tools"], "the CLI's visit ranks the Session Path first for the server")
        let printedAfterCLIVisit = try await printed(["session-paths"])
        XCTAssertEqual(afterCLIVisit, printedAfterCLIVisit)

        for query in ["gam", "work", "zzz"] {
            let answer = try await answered(.ranked(query: query))
            let line = try await printed(["session-paths", "--query", query])
            XCTAssertEqual(answer, line, query)
        }

        let id = try await newTopic("Ship", in: sandbox.game, sandbox: sandbox)
        let topic = try await answered(.topic(id))
        let printedTopic = try await printed(["topic", "session-paths", "--topic", id])
        XCTAssertEqual(topic, printedTopic)
        XCTAssertEqual((topic["rows"] as? [[String: Any]])?.map { $0["in_this_topic"] as? Bool }, [true, false])

        do {
            _ = try await client.call(HostRequest.visitSessionPath(VisitSessionPath(folder: sandbox.root.appendingPathComponent("missing").path)),
                                      as: ProtocolEmpty.self)
            XCTFail("a visit to a missing folder must fail")
        } catch let error as ProtocolError {
            XCTAssertEqual(error.code, .failed)
            XCTAssertTrue(error.message.contains("no directory"), error.message)
        }
    }

    func testEnvironmentShowJSONSaysWhichSidebarListsTheConfigShows() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let environment = sandbox.cliEnvironment(pane: nil)
        let config = try String(contentsOf: sandbox.config, encoding: .utf8)
        func sidebar() async throws -> [String: Bool] {
            let shown = try await run(cli, arguments: ["environment", "show", "--json"], environment: environment)
            XCTAssertEqual(shown.status, 0, shown.output)
            return try XCTUnwrap(try jsonLine(shown.stdout)["sidebar"] as? [String: Bool], shown.stdout)
        }
        let absent = try await sidebar()
        XCTAssertEqual(absent, ["topics": true, "sessions": true], "both lists show when the Config has no keys")
        try (config + "\nsidebar:\n  topics: false\n").write(to: sandbox.config, atomically: true, encoding: .utf8)
        let sessionsOnly = try await sidebar()
        XCTAssertEqual(sessionsOnly, ["topics": false, "sessions": true])
        try (config + "\nsidebar:\n  sessions: false\n").write(to: sandbox.config, atomically: true, encoding: .utf8)
        let topicsOnly = try await sidebar()
        XCTAssertEqual(topicsOnly, ["topics": true, "sessions": false])
    }

    private func standaloneCLI() throws -> URL {
        let binary = cli
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: binary.path))
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent(".build/cli-smoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let tool = folder.appendingPathComponent("muxify")
        try FileManager.default.copyItem(at: binary, to: tool)
        // No resource bundle or desktop app accompanies it.
        return tool
    }
}

/// A throwaway tmux server, state folder and Config in one run directory. The CLI and every tmux command here
/// get `TMUX_TMPDIR` set to that directory and no `TMUX`, so nothing reaches the user's own server.
private final class TopicSandbox {
    let root: URL
    let game: URL
    let tools: URL
    let config: URL
    private let tmuxBinary: String
    /// The socket that tmux makes from `TMUX_TMPDIR`, so the CLI and the test talk to the same server.
    private let socket: URL
    private var clients: [(process: Process, input: Pipe)] = []

    init() throws {
        tmuxBinary = try requireTmux()
        // A short path, because a socket path must fit in 104 bytes. Real, because tmux reports the real socket path.
        let made = URL(fileURLWithPath: "/tmp/mxc-" + UUID().uuidString.prefix(8), isDirectory: true)
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        guard let real = realpath(made.path, nil) else { throw CLIError("cannot resolve \(made.path)") }
        root = URL(fileURLWithPath: String(cString: real), isDirectory: true)
        free(real)
        game = root.appendingPathComponent("work/game", isDirectory: true)
        tools = root.appendingPathComponent("work/tools", isDirectory: true)
        config = root.appendingPathComponent("config.yaml")
        for folder in [game, tools] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try Data("sessions:\n  paths:\n    - path: \(root.path)/work/*\ntopics:\n  tags:\n    backend: {}\n    release: {}\n".utf8).write(to: config)
        let socketFolder = root.appendingPathComponent("tmux-\(getuid())", isDirectory: true)
        try FileManager.default.createDirectory(at: socketFolder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        socket = socketFolder.appendingPathComponent("default")
        try tmux(["-f", "/dev/null", "new-session", "-d", "-s", "main", "-c", root.path])
        guard try ownsServer() else { throw CLIError("the sandbox server is not in \(root.path)") }
    }

    private var tmuxEnvironment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["TMUX"] = nil
        environment["TMUX_PANE"] = nil
        environment["TMUX_TMPDIR"] = root.path
        environment["SHELL"] = "/bin/sh"
        return environment
    }

    /// The CLI's environment: this sandbox's server, state folder and Config, called from `pane`, or from
    /// outside tmux when `pane` is nil.
    func cliEnvironment(pane: PaneID?) -> [String: String] {
        var environment = tmuxEnvironment
        environment["XDG_STATE_HOME"] = root.appendingPathComponent("state").path
        environment["MUXIFY_CONFIG"] = config.path
        environment["TMUX_PANE"] = pane?.rawValue
        return environment
    }

    func session(of pane: PaneID) throws -> String {
        try tmux(["display-message", "-p", "-t", pane.rawValue, "#{session_name}"])
    }

    func topicOption(of session: String) throws -> String {
        try tmux(["show-options", "-qv", "-t", "=" + session + ":", "@muxify_topic"])
    }

    @discardableResult
    func tmux(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmuxBinary)
        // `-u`, as TmuxServer does: xcodebuild runs the tests without a UTF-8 locale, and then tmux prints a tab as `_`.
        process.arguments = ["-u", "-S", socket.path] + arguments
        process.environment = tmuxEnvironment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        // start(), not isRunning: on Linux, Foundation sees the exit of a tmux that started the server only when the
        // server exits.
        let exit = try process.start()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard exit.wait().status == 0 else { throw CLIError("tmux \(arguments.joined(separator: " ")): \(text)") }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A bare repository in `work/<name>`, which the Config names, with one Worktree folder per branch.
    /// The first branch is the repository's HEAD.
    func makeBareRepository(_ name: String, worktrees branches: [String]) throws -> URL {
        let seed = root.appendingPathComponent("seed-" + name).path
        try git(["init", "-q", "-b", branches[0], seed], in: root.path)
        try git(["commit", "-q", "--allow-empty", "-m", "init"], in: seed)
        let bare = root.appendingPathComponent("work/" + name)
        try git(["clone", "-q", "--bare", seed, bare.path], in: root.path)
        for (index, branch) in branches.enumerated() {
            try git(["worktree", "add", "-q", bare.path + "/" + branch] + (index == 0 ? [branch] : ["-b", branch]), in: bare.path)
        }
        return bare
    }

    @discardableResult
    /// Makes `folder` a repository on main with one commit of readme.txt.
    func makeRepository(_ folder: URL) throws {
        _ = try git(["init", "-q", "-b", "main"], in: folder.path)
        try Data("readme\n".utf8).write(to: folder.appendingPathComponent("readme.txt"))
        _ = try git(["add", "readme.txt"], in: folder.path)
        _ = try git(["commit", "-q", "-m", "first"], in: folder.path)
    }

    func git(_ arguments: [String], in directory: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgSign=false"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let exit = try process.start()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard exit.wait().status == 0 else { throw CLIError("git \(arguments.joined(separator: " ")): \(text)") }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A Pane in `session` that runs a program, as an Agent does, with the pane options that its Extension and
    /// Muxify write. `status` nil is an Agent before its first turn.
    func fakeAgent(in session: String, status: String?, unread: Bool, conversation: String? = nil) throws -> PaneID {
        // exec: Linux's sh, dash, would otherwise stay the Pane's command in front of sleep.
        let id = try tmux(["split-window", "-d", "-P", "-F", "#{pane_id}", "-t", "=" + session + ":", "exec sleep 600"])
        guard let pane = PaneID(rawValue: id) else { throw CLIError("split-window printed no Pane id: \(id)") }
        try tmux(["set-option", "-p", "-t", id, "@muxify_agent", "claude"])
        if let status { try tmux(["set-option", "-p", "-t", id, "@muxify_agent_status", status]) }
        if unread { try tmux(["set-option", "-p", "-t", id, "@muxify_agent_unread", "1"]) }
        if let conversation { try tmux(["set-option", "-p", "-t", id, "@muxify_agent_conversation", conversation]) }
        return pane
    }

    /// Every Pane of `session` runs `cat` into a file of its own, so a line typed into any Pane lands in one of the
    /// returned files. Each file stays empty while no input arrives.
    func listeners(in session: String) throws -> [URL] {
        try tmux(["split-window", "-d", "-t", "=" + session + ":"])
        return try tmux(["list-panes", "-s", "-t", "=" + session, "-F", "#{pane_id}"]).split(separator: "\n").map { pane in
            let file = root.appendingPathComponent("heard-" + pane.dropFirst())
            FileManager.default.createFile(atPath: file.path, contents: Data())
            try tmux(["respawn-pane", "-k", "-t", String(pane), "cat >> " + Tmux.shellQuote(file.path)])
            return file
        }
    }

    func pane(of session: String) throws -> PaneID {
        let id = try tmux(["display-message", "-p", "-t", "=" + session + ":", "#{pane_id}"])
        guard let pane = PaneID(rawValue: id) else { throw CLIError("no Pane in \(session): \(id)") }
        return pane
    }

    func sessions() throws -> [String] {
        try tmux(["list-sessions", "-F", "#{session_name}"]).split(separator: "\n").map(String.init).sorted()
    }

    /// A terminal attached to `session` through a pseudo-terminal, as a user's terminal is, or a control-mode
    /// client such as iTerm's. Returns its tty.
    @discardableResult
    func attachClient(to session: String, control: Bool = false) throws -> String {
        let mode = control ? "1" : "0"
        let before = try tmux(["list-clients", "-F", "#{client_tty}"]).split(separator: "\n")
        let process = Process()
        let command = [tmuxBinary] + (control ? ["-C"] : []) + ["attach-session", "-t", "=" + session]
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        #if os(macOS)
        process.arguments = ["-q", "/dev/null"] + command
        #else
        // util-linux's script runs one shell command line, and -e returns its exit status.
        process.arguments = ["-qec", command.map(Tmux.shellQuote).joined(separator: " "), "/dev/null"]
        #endif
        var environment = tmuxEnvironment
        environment["TERM"] = "xterm-256color"
        process.environment = environment
        // An open input that is never written: at end of input, script would type ^D into the Pane's shell.
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        clients.append((process, input))
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let attached = try tmux(["list-clients", "-F", "#{client_tty} #{client_control_mode}"]).split(separator: "\n")
            if let line = attached.first(where: { $0.hasSuffix(" " + mode) && !before.contains($0.dropLast(2)) }) {
                return String(line.dropLast(2))
            }
            usleep(20_000)
        }
        throw CLIError("no client attached to \(session)")
    }

    func clientSession(_ tty: String) throws -> String {
        // Not display-message -c: without -t it formats the most recent Session, not the client's.
        let clients = try tmux(["list-clients", "-F", "#{client_tty}\t#{client_session}"]).split(separator: "\n")
        guard let line = clients.first(where: { $0.hasPrefix(tty + "\t") }) else { throw CLIError("client \(tty) is gone") }
        return String(line.dropFirst(tty.count + 1))
    }

    /// The Topic records in the state database, in id order, as the CLI wrote them.
    func records() throws -> [TopicRecord] {
        try TopicStore(paths: paths).read().records
    }

    /// The Muxify Worktree records in the state database, oldest first.
    func worktrees() throws -> [MuxifyWorktreeRecord] {
        try MuxifyWorktreeStore(paths: paths).all()
    }

    /// The remembered Session of `record` in `sessionPath`.
    func session(of record: TopicRecord, in sessionPath: URL) -> JSONValue? {
        record.sessions.first { real($0["repository_path"]?.string) == real(sessionPath.path) }
    }

    /// The path with symlinks resolved, so `/tmp` and `/private/tmp` compare equal; nil when it is no path.
    func real(_ value: Any?) -> String? {
        guard let path = value as? String, let resolved = realpath(path, nil) else { return value as? String }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    func repositoryPaths(of record: TopicRecord) -> [String] {
        record.sessions.compactMap { $0["directory"]?.string }
            .map { path in realpath(path, nil).map { real in defer { free(real) }; return String(cString: real) } ?? path }
    }

    private var paths: MuxifyPaths {
        MuxifyPaths(environment: ["XDG_STATE_HOME": root.appendingPathComponent("state").path], home: "/nonexistent")
    }

    /// Makes the ledger row of a finished Request the row that a run leaves when it ends after its record write.
    func leaveStarted(_ request: String) throws {
        try StateDatabase.open(paths).execute(
            "UPDATE applied_requests SET state = 'started', stdout = NULL, stderr = NULL, exit_code = NULL WHERE id = ?", request)
    }

    func requestState(_ request: String) throws -> String? {
        try StateDatabase.open(paths).query("SELECT state FROM applied_requests WHERE id = ?", request) { $0.text(0) }.first ?? nil
    }

    /// Stops this sandbox's server only, after it checks the socket path.
    func stopServer() throws {
        guard try ownsServer() else { throw CLIError("the sandbox server is not in \(root.path)") }
        try tmux(["kill-server"])
    }

    func startServer() throws {
        try tmux(["-f", "/dev/null", "new-session", "-d", "-s", "main", "-c", root.path])
        guard try ownsServer() else { throw CLIError("the sandbox server is not in \(root.path)") }
    }

    private func ownsServer() throws -> Bool {
        try tmux(["display-message", "-p", "#{socket_path}"]).hasPrefix(root.path + "/")
    }

    /// Stops the attached terminals by PID, then this sandbox's server only, after it checks the socket path.
    func stop() {
        for client in clients where client.process.isRunning {
            kill(client.process.processIdentifier, SIGKILL)
            while client.process.isRunning { usleep(5_000) }
        }
        if (try? ownsServer()) == true { _ = try? tmux(["kill-server"]) }
        try? FileManager.default.removeItem(at: root)
    }
}

/// The latest item of a `topic` subscription, as the JSON object that it encodes to.
private final class LatestTopicItem: @unchecked Sendable {
    private let lock = NSLock()
    private var item: TopicDetailItem??

    func set(_ item: TopicDetailItem) { lock.lock(); self.item = item; lock.unlock() }

    func json() throws -> Any? {
        lock.lock()
        let item = self.item
        lock.unlock()
        guard let item else { return nil }
        return try JSONSerialization.jsonObject(with: try JSONEncoder().encode(item), options: .fragmentsAllowed)
    }
}

private struct CLIRun {
    let status: Int32
    let stdout: String
    let stderr: String
    /// Both streams, for a check that does not care which one a line went to.
    var output: String { stdout + stderr }
}

private extension Array {
    /// The one element, else nil.
    var only: Element? { count == 1 ? first : nil }
}
