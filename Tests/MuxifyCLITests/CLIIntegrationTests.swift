import Darwin
import Foundation
import XCTest
@testable import MuxifyCLI
import MuxifyCore

final class CLIIntegrationTests: XCTestCase {
    func testShortLivedProcessesCanBeAwaitedRepeatedly() async throws {
        for _ in 0..<10 {
            for (executable, status) in [("/usr/bin/true", Int32(0)), ("/usr/bin/false", Int32(1))] {
                let process = makeProcess(URL(fileURLWithPath: executable), arguments: [], output: Pipe())
                try process.run()
                defer { stopIfRunning(process) }
                try await waitForExit(process)
                XCTAssertEqual(process.terminationStatus, status)
            }
        }
    }

    func testSubprocessWaitTimesOutAndCleanupKillsProcess() async throws {
        let process = makeProcess(URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], output: Pipe())
        try process.run()
        defer { stopIfRunning(process) }
        let start = Date()
        do {
            try await waitForExit(process, timeout: 0.05)
            XCTFail("Expected subprocess wait to time out")
        } catch {
            XCTAssertEqual(error.localizedDescription, "CLI did not exit before the timeout")
        }
        XCTAssertTrue(process.isRunning)
        stopIfRunning(process)
        XCTAssertFalse(process.isRunning)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testRelocatedBinaryAndInstalledSymlinkSupportHelpAndValidation() async throws {
        let tool = try standaloneCLI()
        defer { try? FileManager.default.removeItem(at: tool.deletingLastPathComponent()) }
        let link = tool.deletingLastPathComponent().appendingPathComponent("installed-muxify")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tool)
        for executable in [tool, link] {
            let help = try await run(executable, arguments: ["--help"])
            XCTAssertEqual(help.status, 0, help.output)
            XCTAssertTrue(help.output.contains("usage: muxify browser open"))
            let unknown = try await run(executable, arguments: ["unknown"])
            XCTAssertEqual(unknown.status, 2)
        }
    }

    /// Pins the exact bytes of `topic list` for valid records, so moving the reader into MuxifyCore cannot change them.
    func testTopicListPrintsTheSameBytesForValidRecords() async throws {
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("muxify-cli-golden-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: state) }
        let topics = state.appendingPathComponent("muxify/topics")
        try FileManager.default.createDirectory(at: topics, withIntermediateDirectories: true)
        let records = [
            #"{"id":"a-null","title":"Settled null","settled_at":null}"#,
            #"{"id":"b-absent","title":"No settled field"}"#,
            #"{"id":"c-settled","title":"Done","settled_at":"2026-10-01T10:00:00Z","outcome":"merged"}"#,
            #"{"id":"d-tabs","title":"Fix\treward\nflow\r\nnow"}"#,
            #"{"id":"e-empty","title":"","slug":"fix-login"}"#,
            #"{"id":"f-both-empty","title":"","slug":""}"#,
            #"{"id":"g-none"}"#,
            #"{"id":"h-slug-only","slug":"untitled-3"}"#,
            #"{"id":"Upper","title":"Sorts before lower case","tags":["release","backend"]}"#,
            #"{"id":"café","title":"Crème brûlée"}"#,
            #"{"id":"日本","title":"東京 🚀","order":2,"snoozed_until":"never","sessions":[{"repository_path":"/p"}],"extra":{"k":1}}"#,
        ]
        for text in records {
            let id = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["id"] as? String)
            try Data(text.utf8).write(to: topics.appendingPathComponent(id + ".json"))
        }
        let binary = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("muxify")
        let result = try await run(binary, arguments: ["topic", "list"], environment: ["XDG_STATE_HOME": state.path])
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(Array(result.output.utf8), Array("""
            Upper\tSorts before lower case\t#backend #release
            a-null\tSettled null\t
            b-absent\tNo settled field\t
            café\tCrème brûlée\t
            d-tabs\tFix reward flow\r now\t
            e-empty\tfix-login\t
            f-both-empty\tUntitled Topic\t
            g-none\tUntitled Topic\t
            h-slug-only\tuntitled-3\t
            日本\t東京 🚀\t

            """.utf8))
    }

    func testTopicListLeavesOutFilesThatAreNotValidRecords() async throws {
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("muxify-cli-invalid-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: state) }
        let binary = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("muxify")
        let empty = try await run(binary, arguments: ["topic", "list"], environment: ["XDG_STATE_HOME": state.path])
        XCTAssertEqual(empty.status, 0, empty.output)
        XCTAssertEqual(empty.output, "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.path), "a list creates no state folder")

        let topics = state.appendingPathComponent("muxify/topics")
        try FileManager.default.createDirectory(at: topics, withIntermediateDirectories: true)
        let files = [
            "a.json": #"{"id":"a","title":"Valid"}"#,
            "b.json": #"{"id":"other","title":"Renamed file"}"#,
            "c.json": #"{"id":"c","title":"#,
            "d.json": #"{"id":"d","title":7}"#,
            "e.txt": #"{"id":"e","title":"Not a record"}"#,
        ]
        for (name, text) in files { try Data(text.utf8).write(to: topics.appendingPathComponent(name)) }
        let result = try await run(binary, arguments: ["topic", "list"], environment: ["XDG_STATE_HOME": state.path])
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.output, "a\tValid\t\n")
    }

    func testTopicListExitsWithAnErrorWhenItCannotReadTheRecords() async throws {
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("muxify-cli-unreadable-" + UUID().uuidString)
        let folder = state.appendingPathComponent("muxify")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: state)
        }
        let topics = folder.appendingPathComponent("topics")
        try FileManager.default.createDirectory(at: topics, withIntermediateDirectories: true)
        try Data(#"{"id":"a","title":"Valid"}"#.utf8).write(to: topics.appendingPathComponent("a.json"))
        // The read takes the record lock, and it cannot make the lock file in a read-only state folder.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        let binary = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("muxify")
        let result = try await run(binary, arguments: ["topic", "list"], environment: ["XDG_STATE_HOME": state.path])
        XCTAssertEqual(result.status, 1, result.output)
        XCTAssertEqual(result.output, "muxify: Muxify could not read or write the Topic records in \(folder.path). Permission denied. No changes were made.\n")
    }

    func testTopicNewThenAddSessionLeavesEveryClientWhereItWas() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let caller = try sandbox.pane(of: "main")
        let control = try sandbox.attachClient(to: "main", control: true)
        let client = try sandbox.attachClient(to: "main")
        let made = try await run(cli, arguments: ["topic", "new", "Ship it"], environment: sandbox.cliEnvironment(pane: caller))
        XCTAssertEqual(made.status, 0, made.output)
        let id = try XCTUnwrap(sandbox.records().only?["id"] as? String)
        XCTAssertEqual(made.output, id + "\n")
        let result = try await run(cli, arguments: ["topic", "add-session", sandbox.game.path, "--topic", id],
                                   environment: sandbox.cliEnvironment(pane: caller))
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.output, id + "\n")
        let record = try XCTUnwrap(sandbox.records().only)
        XCTAssertEqual(record["title"] as? String, "Ship it")
        XCTAssertEqual(sandbox.repositoryPaths(of: record), [sandbox.game.path])
        XCTAssertEqual(try sandbox.tmux(["show-options", "-qv", "-t", "game/ship-it:", "@muxify_topic"]), id)
        XCTAssertEqual(try sandbox.clientSession(client), "main", "a command changes what the terminal shows only when asked")
        XCTAssertEqual(try sandbox.clientSession(control), "main", "a command changes what the control-mode client shows only when asked")
        XCTAssertEqual(try sandbox.tmux(["display-message", "-p", "-t", caller.rawValue, "#{session_name}"]), "main", "the caller Pane stays")
    }

    func testWindowMoveToANewTopicMovesTheCallerPaneIntoAnUntitledTopic() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        try sandbox.tmux(["new-session", "-d", "-s", "loose", "-c", sandbox.game.path])
        try sandbox.tmux(["new-window", "-d", "-t", "=loose:", "-c", sandbox.game.path])
        let pane = try sandbox.pane(of: "loose")
        let result = try await run(cli, arguments: ["window", "move", "--new-topic"], environment: sandbox.cliEnvironment(pane: pane))
        XCTAssertEqual(result.status, 0, result.output)
        let record = try XCTUnwrap(sandbox.records().only)
        let id = try XCTUnwrap(record["id"] as? String)
        XCTAssertEqual(result.output, id + "\n")
        XCTAssertNil(record["title"] as? String)
        XCTAssertEqual(try sandbox.tmux(["display-message", "-p", "-t", pane.rawValue, "#{session_name}"]), "loose/untitled-1")
        XCTAssertEqual(try sandbox.tmux(["show-options", "-qv", "-t", "loose/untitled-1:", "@muxify_topic"]), id)
        XCTAssertEqual(try sandbox.tmux(["list-windows", "-t", "=loose", "-F", "#{window_id}"]).split(separator: "\n").count, 1,
                       "the other Window stays")
    }

    func testTopicNewWithATitleMakesAnEmptyTopicInOrOutsideTmux() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        try sandbox.tmux(["new-session", "-d", "-s", "loose", "-c", sandbox.game.path])
        let pane = try sandbox.pane(of: "loose")
        for (title, caller) in [("Fix it", Optional(pane)), ("Plan it", nil)] {
            let result = try await run(cli, arguments: ["topic", "new", title], environment: sandbox.cliEnvironment(pane: caller))
            XCTAssertEqual(result.status, 0, result.output)
            let record = try XCTUnwrap(sandbox.records().first { $0["title"] as? String == title })
            XCTAssertEqual(result.output, try XCTUnwrap(record["id"] as? String) + "\n")
            XCTAssertEqual(sandbox.repositoryPaths(of: record), [], "an Empty Topic has no Session")
        }
        XCTAssertEqual(try sandbox.sessions(), ["loose", "main"], "topic new starts no Session")
        XCTAssertEqual(try sandbox.tmux(["display-message", "-p", "-t", pane.rawValue, "#{session_name}"]), "loose", "the caller Pane stays")
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
        XCTAssertEqual(sandbox.real(session["worktree_path"]), server.path + "/release")
        XCTAssertEqual(session["branch"] as? String, "release")
        XCTAssertEqual(session["worktree_created"] as? Bool, false)
        XCTAssertEqual(sandbox.real(try sandbox.tmux(["display-message", "-p", "-t", "=server/release/ship:", "#{session_path}"])), server.path + "/release")
    }

    func testTopicAddSessionWithWorktreeMakesAWorktreeOnTheTopicBranchInMuxifysFolder() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let server = try sandbox.makeBareRepository("server", worktrees: ["main", "release"])
        let release = server.path + "/release"
        let id = try await newTopic("Ship", in: sandbox.game, sandbox: sandbox)
        let result = try await run(cli, arguments: ["topic", "add-session", release, "--worktree", "--topic", id],
                                   environment: sandbox.cliEnvironment(pane: nil))
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.stdout, id + "\n")
        let worktree = sandbox.root.path + "/state/muxify/worktrees/server/ship"
        let session = try XCTUnwrap(sandbox.session(of: try XCTUnwrap(sandbox.records().only), in: server))
        XCTAssertEqual(sandbox.real(session["worktree_path"]), worktree)
        XCTAssertEqual(session["branch"] as? String, "ship")
        XCTAssertEqual(session["worktree_created"] as? Bool, true)
        XCTAssertEqual(session["base"] as? String, try sandbox.git(["rev-parse", "HEAD"], in: release), "the HEAD of the row's Worktree")
        XCTAssertEqual(try sandbox.git(["rev-parse", "HEAD"], in: worktree), session["base"] as? String)
        XCTAssertEqual(try sandbox.git(["symbolic-ref", "--short", "HEAD"], in: worktree), "ship")
        XCTAssertEqual(sandbox.real(try sandbox.tmux(["display-message", "-p", "-t", "=server/release/ship:", "#{session_path}"])), worktree)
        XCTAssertEqual(try sandbox.topicOption(of: "server/release/ship"), id)
    }

    func testTopicAddSessionWithWorktreeAndBaseStartsTheWorktreeAtThatRef() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let server = try sandbox.makeBareRepository("server", worktrees: ["main", "release"])
        let release = server.path + "/release"
        try sandbox.git(["commit", "-q", "--allow-empty", "-m", "release only"], in: release)
        let id = try await newTopic("Ship", in: sandbox.game, sandbox: sandbox)
        let result = try await run(cli, arguments: ["topic", "add-session", release, "--worktree", "--base", "main", "--topic", id],
                                   environment: sandbox.cliEnvironment(pane: nil))
        XCTAssertEqual(result.status, 0, result.output)
        let main = try sandbox.git(["rev-parse", "main"], in: release)
        XCTAssertNotEqual(main, try sandbox.git(["rev-parse", "HEAD"], in: release))
        let session = try XCTUnwrap(sandbox.session(of: try XCTUnwrap(sandbox.records().only), in: server))
        XCTAssertEqual(session["base"] as? String, main)
        XCTAssertEqual(try sandbox.git(["rev-parse", "HEAD"], in: sandbox.root.path + "/state/muxify/worktrees/server/ship"), main)
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
        XCTAssertEqual(try sandbox.records() as NSArray, before as NSArray)
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

    func testTopicSettleWithRemoveWorktreesRefusesAWorktreeWithUncommittedWorkAndChangesNothing() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let server = try sandbox.makeBareRepository("server", worktrees: ["main"])
        let id = try await newTopic("Ship", in: sandbox.game, sandbox: sandbox)
        let added = try await run(cli, arguments: ["topic", "add-session", server.path + "/main", "--worktree", "--topic", id],
                                  environment: sandbox.cliEnvironment(pane: nil))
        XCTAssertEqual(added.status, 0, added.output)
        let worktree = sandbox.root.path + "/state/muxify/worktrees/server/ship"
        try "draft".write(toFile: worktree + "/notes.txt", atomically: true, encoding: .utf8)
        let before = try sandbox.records()
        let sessions = try sandbox.sessions()
        let result = try await run(cli, arguments: ["topic", "settle", "--kill-sessions", "--remove-worktrees", "--topic", id],
                                   environment: sandbox.cliEnvironment(pane: nil))
        XCTAssertEqual(result.status, 1, result.output)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "muxify: The Worktree \(worktree) has uncommitted changes. Commit or remove them, or keep the Worktree. "
                       + "No changes were made.\n")
        XCTAssertEqual(try sandbox.records() as NSArray, before as NSArray, "the Topic is not Settled")
        XCTAssertEqual(try sandbox.sessions(), sessions)
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree + "/notes.txt"))
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
        XCTAssertNotNil(try XCTUnwrap(sandbox.records().only)["settled_at"] as? String)
        XCTAssertEqual(try sandbox.sessions(), ["main"])
    }

    func testTopicSnoozeSnoozesTheCallerPanesTopicAndLeavesItsSession() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let id = try await newTopic("Ship", in: sandbox.game, sandbox: sandbox)
        let start = Date()
        let result = try await run(cli, arguments: ["topic", "snooze", "2h"],
                                   environment: sandbox.cliEnvironment(pane: try sandbox.pane(of: "game/ship")))
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.stdout, id + "\n", "a write prints the id of the Topic it changed")
        XCTAssertEqual(result.stderr, "")
        let stored = try XCTUnwrap(sandbox.records().only?["snoozed_until"] as? String)
        guard case .at(let date)? = SnoozeDeadline(stored: stored) else { return XCTFail("snoozed_until is \(stored)") }
        XCTAssertEqual(date.timeIntervalSince(start), 2 * 60 * 60, accuracy: 30)
        XCTAssertEqual(try sandbox.sessions(), ["game/ship", "main"], "a Snooze changes nothing in tmux")
        XCTAssertEqual(try sandbox.topicOption(of: "game/ship"), id)
    }

    func testTopicTagAddsRemovesAndSetsTheTagsOfTheTopicInTheRecord() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let id = try await newTopic("Ship", in: sandbox.game, sandbox: sandbox)
        let add = try await run(cli, arguments: ["topic", "tag", "add", "Release", "#backend"],
                                environment: sandbox.cliEnvironment(pane: try sandbox.pane(of: "game/ship")))
        XCTAssertEqual(add.status, 0, add.output)
        XCTAssertEqual(add.stdout, id + "\n", "a write prints the id of the Topic it changed")
        XCTAssertEqual(try XCTUnwrap(sandbox.records().only)["tags"] as? [String], ["backend", "release"])
        let undefined = try await run(cli, arguments: ["topic", "tag", "set", "backend", "bazel", "--topic", "Ship"],
                                      environment: sandbox.cliEnvironment(pane: nil))
        XCTAssertNotEqual(undefined.status, 0, undefined.output)
        XCTAssertTrue(undefined.stderr.contains("#bazel") && undefined.stderr.contains("topics.tags"), undefined.stderr)
        XCTAssertEqual(try XCTUnwrap(sandbox.records().only)["tags"] as? [String], ["backend", "release"],
                       "a Tag that the Config does not define writes nothing")
        let remove = try await run(cli, arguments: ["topic", "tag", "remove", "release", "--topic", "Ship"], environment: sandbox.cliEnvironment(pane: nil))
        XCTAssertEqual(remove.status, 0, remove.output)
        XCTAssertEqual(try XCTUnwrap(sandbox.records().only)["tags"] as? [String], ["backend"])
        let set = try await run(cli, arguments: ["topic", "tag", "set", "--topic", id, "--json"], environment: sandbox.cliEnvironment(pane: nil))
        XCTAssertEqual(set.status, 0, set.output)
        XCTAssertEqual(try XCTUnwrap(try jsonLine(set.stdout)["changed"] as? [String: Any], set.stdout)["topic_id"] as? String, id)
        XCTAssertNil(try XCTUnwrap(sandbox.records().only)["tags"], "set with no Tag removes the key")
        XCTAssertEqual(try sandbox.sessions(), ["game/ship", "main"], "a Tag change changes nothing in tmux")
    }

    func testTopicSnoozeWithATopicIdReplacesALaterSnoozeFromOutsideTmux() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let id = try await newTopic("Ship", in: sandbox.game, sandbox: sandbox)
        let forever = try await run(cli, arguments: ["topic", "snooze", "forever", "--topic", id], environment: sandbox.cliEnvironment(pane: nil))
        XCTAssertEqual(forever.status, 0, forever.output)
        XCTAssertEqual(try XCTUnwrap(sandbox.records().only)["snoozed_until"] as? String, "never")
        let start = Date()
        let tomorrow = try await run(cli, arguments: ["topic", "snooze", "tomorrow", "10:15", "--topic", "Ship", "--json"],
                                     environment: sandbox.cliEnvironment(pane: nil))
        XCTAssertEqual(tomorrow.status, 0, tomorrow.output)
        let change = try XCTUnwrap(try jsonLine(tomorrow.stdout)["snooze_changed"] as? [String: Any], tomorrow.stdout)
        XCTAssertEqual(change["topic_ids"] as? [String], [id])
        XCTAssertEqual(change["shortened"] as? [String], [id], "a time replaces a Snooze forever")
        let stored = try XCTUnwrap(sandbox.records().only?["snoozed_until"] as? String)
        guard case .at(let date)? = SnoozeDeadline(stored: stored) else { return XCTFail("snoozed_until is \(stored)") }
        let expected = try XCTUnwrap(Calendar.current.date(bySettingHour: 10, minute: 15, second: 0,
                                                           of: try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 1, to: start))))
        XCTAssertEqual(date, expected, "the shorter time replaces a Snooze forever")
    }

    func testTopicSnoozeOfAPastTimeOrASettledTopicFailsAndChangesNothing() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let id = try await newTopic("Ship", in: sandbox.game, sandbox: sandbox)
        let open = try sandbox.records()
        let past = try await run(cli, arguments: ["topic", "snooze", "today", "0:00", "--topic", id], environment: sandbox.cliEnvironment(pane: nil))
        XCTAssertEqual(past.status, 2, past.output)
        XCTAssertEqual(past.stderr, "muxify: that time has already passed\n")
        XCTAssertEqual(try sandbox.records() as NSArray, open as NSArray)
        let settle = try await run(cli, arguments: ["topic", "settle", "--topic", id], environment: sandbox.cliEnvironment(pane: nil))
        XCTAssertEqual(settle.status, 0, settle.output)
        let settled = try sandbox.records()
        let result = try await run(cli, arguments: ["topic", "snooze", "2h", "--topic", id], environment: sandbox.cliEnvironment(pane: nil))
        XCTAssertEqual(result.status, 1, result.output)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "muxify: No open Topic matches \(id). No changes were made.\n")
        XCTAssertEqual(try sandbox.records() as NSArray, settled as NSArray)
    }

    func testTopicSnoozeWithSeveralTopicsSnoozesEachOrNoneAndUnsnoozeEndsIt() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let ship = try await newTopic("Ship", in: sandbox.game, sandbox: sandbox)
        let fix = try await newTopic("Fix", in: sandbox.game, sandbox: sandbox)
        func snoozes() throws -> [String: String] {
            Dictionary(uniqueKeysWithValues: try sandbox.records().map { ($0["id"] as! String, $0["snoozed_until"] as? String ?? "") })
        }
        let environment = sandbox.cliEnvironment(pane: try sandbox.pane(of: "main"))
        let missing = try await run(cli, arguments: ["topic", "snooze", "forever", "--topic", ship, "--topic", "Nope"], environment: environment)
        XCTAssertEqual(missing.status, 1, missing.output)
        XCTAssertEqual(missing.stderr, "muxify: No open Topic matches Nope. No changes were made.\n")
        XCTAssertEqual(try snoozes(), [ship: "", fix: ""], "one Topic that is not open changes nothing")

        let both = try await run(cli, arguments: ["topic", "snooze", "forever", "--topic", "Fix", "--topic", ship, "--topic", fix], environment: environment)
        XCTAssertEqual(both.status, 0, both.output)
        XCTAssertEqual(both.stdout, "\(fix)\n\(ship)\n", "one line for each Topic, once, in the order of the options")
        XCTAssertEqual(try snoozes(), [ship: "never", fix: "never"])
        XCTAssertEqual(try sandbox.sessions(), ["game/fix", "game/ship", "main"], "a Snooze changes nothing in tmux")

        let one = try await run(cli, arguments: ["topic", "unsnooze"], environment: sandbox.cliEnvironment(pane: try sandbox.pane(of: "game/ship")))
        XCTAssertEqual(one.status, 0, one.output)
        XCTAssertEqual(one.stdout, ship + "\n")
        XCTAssertEqual(try snoozes(), [ship: "", fix: "never"])

        let again = try await run(cli, arguments: ["topic", "unsnooze", "--topic", ship, "--topic", fix, "--json"], environment: environment)
        XCTAssertEqual(again.status, 0, again.output)
        XCTAssertEqual(try jsonLine(again.stdout)["snooze_changed"] as? [String: [String]], ["topic_ids": [ship, fix], "shortened": []],
                       "a Topic that is not Snoozed stays as it is")
        XCTAssertEqual(try snoozes(), [ship: "", fix: ""])
        XCTAssertEqual(try sandbox.sessions(), ["game/fix", "game/ship", "main"], "an Unsnooze changes nothing in tmux")
    }

    func testRepeatedDirectorySessionsHaveIndependentNamesAndExactSelectors() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let id = try await newTopic("Repeated", in: sandbox.game, sandbox: sandbox)
        let environment = sandbox.cliEnvironment(pane: nil)
        let added = try await run(cli, arguments: ["topic", "add-session", sandbox.game.path, "--topic", id], environment: environment)
        XCTAssertEqual(added.status, 0, added.output)
        let record = try XCTUnwrap(sandbox.records().only)
        let sessions = try XCTUnwrap(record["sessions"] as? [[String: Any]])
        XCTAssertEqual(sessions.compactMap { $0["name"] as? String }, ["game/repeated", "game+2/repeated"])
        XCTAssertEqual(Set(sessions.compactMap { $0["id"] as? String }).count, 2)
        XCTAssertEqual(sessions.compactMap { $0["directory"] as? String }, [sandbox.game.path, sandbox.game.path])
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

    func testWindowMoveToATopicThatDoesNotExistFailsAndChangesNothing() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        _ = try await newTopic("Ship", in: sandbox.game, sandbox: sandbox)
        let before = try sandbox.records()
        let pane = try sandbox.pane(of: "main")
        let result = try await run(cli, arguments: ["window", "move", "--topic", "Nope"], environment: sandbox.cliEnvironment(pane: pane))
        XCTAssertEqual(result.status, 1, result.output)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "muxify: No open Topic matches Nope. No changes were made.\n")
        XCTAssertEqual(try sandbox.records() as NSArray, before as NSArray)
        XCTAssertEqual(try sandbox.tmux(["show-options", "-qv", "-t", "main:", "@muxify_topic"]), "")
    }

    func testTopicAddSessionWithATopicLabelAddsToThatTopicFromAPaneOutsideIt() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let id = try await newTopic("Ship", in: sandbox.game, sandbox: sandbox)
        let result = try await run(cli, arguments: ["topic", "add-session", sandbox.tools.path, "--topic", "Ship"],
                                   environment: sandbox.cliEnvironment(pane: try sandbox.pane(of: "main")))
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.stdout, id + "\n")
        XCTAssertEqual(sandbox.repositoryPaths(of: try XCTUnwrap(sandbox.records().only)), [sandbox.game.path, sandbox.tools.path])
        XCTAssertEqual(try sandbox.topicOption(of: "tools/ship"), id)
        XCTAssertEqual(try sandbox.topicOption(of: "main"), "", "the caller Pane's Session stays out of the Topic")
    }

    func testTopicSettleWithATopicIdSettlesThatTopicFromOutsideTmux() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let id = try await newTopic("Ship", in: sandbox.game, sandbox: sandbox)
        let result = try await run(cli, arguments: ["topic", "settle", "--kill-sessions", "--topic", id], environment: sandbox.cliEnvironment(pane: nil))
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.stdout, id + "\n")
        XCTAssertNotNil(try XCTUnwrap(sandbox.records().only)["settled_at"] as? String)
        XCTAssertEqual(try sandbox.sessions(), ["main"])
    }

    func testWindowMoveWithAWindowMovesThatWindowAndNotTheCallers() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let id = try await newTopic("Ship", in: sandbox.game, sandbox: sandbox)
        try sandbox.tmux(["new-session", "-d", "-s", "loose", "-c", sandbox.tools.path])
        try sandbox.tmux(["new-window", "-d", "-t", "=loose:", "-c", sandbox.tools.path])
        let window = try sandbox.tmux(["display-message", "-p", "-t", "=loose:", "#{window_id}"])
        let caller = try sandbox.pane(of: "main")
        let result = try await run(cli, arguments: ["window", "move", "--window", window, "--topic", "Ship"],
                                   environment: sandbox.cliEnvironment(pane: caller))
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.stdout, id + "\n")
        let moved = try sandbox.tmux(["display-message", "-p", "-t", window, "#{session_name}"])
        XCTAssertEqual(try sandbox.topicOption(of: moved), id)
        XCTAssertEqual(try sandbox.session(of: caller), "main", "the caller Pane stays")
        XCTAssertEqual(try sandbox.topicOption(of: "main"), "")
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
        let id = try XCTUnwrap(sandbox.records().only?["id"] as? String)
        XCTAssertEqual(result.stdout, id + "\n")
        XCTAssertEqual(try sandbox.session(of: pane), "loose/untitled-1")
        XCTAssertEqual(try sandbox.topicOption(of: "loose/untitled-1"), id)
        XCTAssertEqual(try sandbox.session(of: caller), "main", "the caller Pane stays")
    }

    func testATopicTargetThatNamesNoOpenTopicFailsAndChangesNothing() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        _ = try await newTopic("Ship", in: sandbox.game, sandbox: sandbox)
        let before = try sandbox.records()
        let result = try await run(cli, arguments: ["topic", "settle", "--topic", "Nope"],
                                   environment: sandbox.cliEnvironment(pane: try sandbox.pane(of: "game/ship")))
        XCTAssertEqual(result.status, 1, result.output)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "muxify: No open Topic matches Nope. No changes were made.\n")
        XCTAssertEqual(try sandbox.records() as NSArray, before as NSArray)
        XCTAssertEqual(try sandbox.sessions(), ["game/ship", "main"])
    }

    func testATopicLabelThatTwoOpenTopicsShareFailsAndChangesNothing() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        _ = try await newTopic("Ship", in: sandbox.game, sandbox: sandbox)
        _ = try await newTopic("Ship", in: sandbox.game, sandbox: sandbox)
        let before = try sandbox.records()
        let sessions = try sandbox.sessions()
        let result = try await run(cli, arguments: ["topic", "add-session", sandbox.tools.path, "--topic", "Ship"],
                                   environment: sandbox.cliEnvironment(pane: try sandbox.pane(of: "main")))
        XCTAssertEqual(result.status, 1, result.output)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "muxify: More than one open Topic matches Ship. Use an id. No changes were made.\n")
        let json = try await run(cli, arguments: ["topic", "add-session", sandbox.tools.path, "--topic", "Ship", "--json"],
                                 environment: sandbox.cliEnvironment(pane: try sandbox.pane(of: "main")))
        XCTAssertEqual(json.status, 1, json.output)
        XCTAssertEqual((try jsonLine(json.stdout)["failed"] as? [String: Any])?["kind"] as? String, "topic_ambiguous", json.stdout)
        XCTAssertEqual(try sandbox.records() as NSArray, before as NSArray)
        XCTAssertEqual(try sandbox.sessions(), sessions)
    }

    func testSettleWithAPaneOutsideEveryTopicFailsAndChangesNothing() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        _ = try await newTopic("Ship", in: sandbox.game, sandbox: sandbox)
        let before = try sandbox.records()
        let outside = try sandbox.pane(of: "main")
        let result = try await run(cli, arguments: ["topic", "settle", "--pane", outside.rawValue],
                                   environment: sandbox.cliEnvironment(pane: try sandbox.pane(of: "game/ship")))
        XCTAssertEqual(result.status, 1, result.output)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "muxify: The Pane is not in an open Topic. No changes were made.\n")
        let json = try await run(cli, arguments: ["topic", "settle", "--pane", outside.rawValue, "--json"],
                                 environment: sandbox.cliEnvironment(pane: try sandbox.pane(of: "game/ship")))
        XCTAssertEqual(json.status, 1, json.output)
        XCTAssertEqual((try jsonLine(json.stdout)["failed"] as? [String: Any])?["kind"] as? String, "source_has_no_topic", json.stdout)
        XCTAssertEqual(try sandbox.records() as NSArray, before as NSArray)
        XCTAssertEqual(try sandbox.sessions(), ["game/ship", "main"])
    }

    func testJsonPrintsTheChangeAsOneLine() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let result = try await run(cli, arguments: ["topic", "new", "Ship", "--json"], environment: sandbox.cliEnvironment(pane: nil))
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.stderr, "")
        let id = try XCTUnwrap(sandbox.records().only?["id"] as? String)
        let change = try XCTUnwrap(try jsonLine(result.stdout)["changed"] as? [String: Any], result.stdout)
        XCTAssertEqual(change["topic_id"] as? String, id)
        XCTAssertEqual(change["created"] as? Bool, true)
    }

    func testJsonPrintsAFailureAndStillExitsWithAnError() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let result = try await run(cli, arguments: ["topic", "settle", "--topic", "Nope", "--json"],
                                   environment: sandbox.cliEnvironment(pane: nil))
        XCTAssertEqual(result.status, 1, result.output)
        XCTAssertEqual(result.stderr, "muxify: No open Topic matches Nope. No changes were made.\n")
        let failure = try XCTUnwrap(try jsonLine(result.stdout)["failed"] as? [String: Any], result.stdout)
        XCTAssertEqual(failure["kind"] as? String, "topic_unavailable")
        XCTAssertEqual(failure["phase"] as? String, "nothing_changed")
        XCTAssertEqual(failure["message"] as? String, "No open Topic matches Nope.")
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
        let recorded = try XCTUnwrap(sandbox.records().only.flatMap { record in
            (record["sessions"] as? [[String: Any]])?.compactMap { $0["base"] as? String }.first
        })
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

    func testTopicShowFromAPaneOutsideEveryTopicFails() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        _ = try await newTopic("Ship", in: sandbox.game, sandbox: sandbox)
        let result = try await run(cli, arguments: ["topic", "show"], environment: sandbox.cliEnvironment(pane: try sandbox.pane(of: "main")))
        XCTAssertEqual(result.status, 1, result.output)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "muxify: The Pane is not in an open Topic. No changes were made.\n")
    }

    func testAgentListPrintsEachAgentWithItsStatusUnreadAndTopic() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let id = try await newTopic("Ship", in: sandbox.game, sandbox: sandbox)
        let blocked = try sandbox.fakeAgent(in: "game/ship", status: "blocked", unread: true)
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
        XCTAssertEqual(rows.first?["agent"] as? NSDictionary, ["kind": "claude", "status": "blocked", "unread": true, "conversation": NSNull()] as NSDictionary)

        for (filter, expected) in [(["--status", "working"], [working]), (["--unread"], [blocked])] {
            let result = try await run(cli, arguments: ["agent", "list"] + filter, environment: environment)
            XCTAssertEqual(result.status, 0, result.output)
            XCTAssertEqual(result.stdout.split(separator: "\n").map { String($0.prefix { $0 != "\t" }) }, expected.map(\.rawValue),
                           "\(filter)")
        }
    }

    func testAgentListGivesTheConversationOfEachAgent() async throws {
        let sandbox = try TopicSandbox()
        defer { sandbox.stop() }
        let agent = try sandbox.fakeAgent(in: "main", status: "done", unread: false, conversation: "conv-1")
        let result = try await run(cli, arguments: ["agent", "list", "--json"], environment: sandbox.cliEnvironment(pane: nil))
        XCTAssertEqual(result.status, 0, result.output)
        let rows = try XCTUnwrap(try jsonLine(result.stdout)["agents"] as? [[String: Any]], result.stdout)
        XCTAssertEqual(rows.map { $0["pane_id"] as? String }, [agent.rawValue])
        XCTAssertEqual((rows.first?["agent"] as? [String: Any])?["conversation"] as? String, "conv-1")
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

    /// The one JSON object on the one line of `stdout`.
    private func jsonLine(_ stdout: String) throws -> [String: Any] {
        XCTAssertEqual(stdout.filter { $0 == "\n" }.count, 1, "one line: \(stdout)")
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any], stdout)
    }

    private var cli: URL { Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("muxify") }

    /// Makes a Topic with a Session in `sessionPath` through the CLI, as a user would before the command under test:
    /// an Empty Topic, then Add a Session.
    private func newTopic(_ title: String, in sessionPath: URL, sandbox: TopicSandbox) async throws -> String {
        let environment = sandbox.cliEnvironment(pane: try sandbox.pane(of: "main"))
        let made = try await run(cli, arguments: ["topic", "new", title], environment: environment)
        guard made.status == 0, let id = made.output.split(separator: "\n").first else { throw CLIError("topic new: \(made.output)") }
        let added = try await run(cli, arguments: ["topic", "add-session", sessionPath.path, "--topic", String(id)], environment: environment)
        guard added.status == 0 else { throw CLIError("topic add-session: \(added.output)") }
        return String(id)
    }

    private func standaloneCLI() throws -> URL {
        let binary = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("muxify")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: binary.path))
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent(".build/cli-smoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let tool = folder.appendingPathComponent("muxify")
        try FileManager.default.copyItem(at: binary, to: tool)
        // No resource bundle or desktop app accompanies it.
        return tool
    }

    private func makeProcess(_ tool: URL, arguments: [String], output: Pipe, errors: Pipe? = nil,
                             environment extra: [String: String] = [:]) -> Process {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.currentDirectoryURL = tool.deletingLastPathComponent()
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/bin:/bin"
        environment.removeValue(forKey: "TMUX")
        environment.removeValue(forKey: "TMUX_PANE")
        environment.merge(extra) { $1 }
        process.environment = environment
        process.standardOutput = output
        process.standardError = errors ?? output
        return process
    }

    private func run(_ tool: URL, arguments: [String], environment: [String: String] = [:]) async throws -> CLIRun {
        let output = Pipe()
        let errors = Pipe()
        let process = makeProcess(tool, arguments: arguments, output: output, errors: errors, environment: environment)
        try process.run()
        defer { stopIfRunning(process) }
        try await waitForExit(process)
        return CLIRun(status: process.terminationStatus,
                      stdout: String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                      stderr: String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    private func waitForExit(_ process: Process, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        guard !process.isRunning else { throw CLIError("CLI did not exit before the timeout") }
        // Async tasks can resume on a different thread than Process.run().
        // waitUntilExit() can then hang in a thread-local run loop even after exit.
        // Once isRunning is false, terminationStatus is already available.
    }

    private func stopIfRunning(_ process: Process) {
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            XCTAssertFalse(process.isRunning, "CLI did not exit after SIGKILL")
        }
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
        guard let binary = Tmux.binary else { throw XCTSkip("tmux is not installed") }
        tmuxBinary = binary
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
        process.arguments = ["-S", socket.path] + arguments
        process.environment = tmuxEnvironment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        while process.isRunning { usleep(5_000) }
        guard process.terminationStatus == 0 else { throw CLIError("tmux \(arguments.joined(separator: " ")): \(text)") }
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
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        while process.isRunning { usleep(5_000) }
        guard process.terminationStatus == 0 else { throw CLIError("git \(arguments.joined(separator: " ")): \(text)") }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A Pane in `session` that runs a program, as an Agent does, with the pane options that its Extension and
    /// Muxify write. `status` nil is an Agent before its first turn.
    func fakeAgent(in session: String, status: String?, unread: Bool, conversation: String? = nil) throws -> PaneID {
        let id = try tmux(["split-window", "-d", "-P", "-F", "#{pane_id}", "-t", "=" + session + ":", "sleep 600"])
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
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", tmuxBinary] + (control ? ["-C"] : []) + ["attach-session", "-t", "=" + session]
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

    /// The record files as JSON objects, as another reader of the state folder sees them.
    func records() throws -> [[String: Any]] {
        let folder = root.appendingPathComponent("state/muxify/topics")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return try names.filter { $0.hasSuffix(".json") }.sorted().map { name in
            let data = try Data(contentsOf: folder.appendingPathComponent(name))
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CLIError("\(name) is not an object") }
            return object
        }
    }

    /// The remembered Session of `record` in `sessionPath`.
    func session(of record: [String: Any], in sessionPath: URL) -> [String: Any]? {
        ((record["sessions"] as? [[String: Any]]) ?? []).first { real($0["repository_path"]) == real(sessionPath.path) }
    }

    /// The path with symlinks resolved, so `/tmp` and `/private/tmp` compare equal; nil when it is no path.
    func real(_ value: Any?) -> String? {
        guard let path = value as? String, let resolved = realpath(path, nil) else { return value as? String }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    func repositoryPaths(of record: [String: Any]) -> [String] {
        ((record["sessions"] as? [[String: Any]]) ?? []).compactMap { $0["directory"] as? String }
            .map { path in realpath(path, nil).map { real in defer { free(real) }; return String(cString: real) } ?? path }
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
