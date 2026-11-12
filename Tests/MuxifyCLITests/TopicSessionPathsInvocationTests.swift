import XCTest
@testable import MuxifyCLI
@testable import MuxifyCore

final class TopicSessionPathsInvocationTests: XCTestCase {
    func testTargetsAndUsage() throws {
        for arguments in [["--topic", "Build"], ["--window", "@2"], ["--pane", "%3"], []] {
            let command = try CLICommand(arguments: ["topic", "session-paths"] + arguments + ["--json"], environment: ["TMUX_PANE": "%1"])
            guard case .topicSessionPaths(let invocation) = command else { return XCTFail("Wrong command") }
            XCTAssertEqual(invocation.output, .json)
            if arguments.isEmpty { XCTAssertEqual(invocation.target, .pane(PaneID(rawValue: "%1")!)) }
        }
        for arguments in [[], ["--topic", "a", "extra"], ["--topic", "a", "--pane", "%1"], ["--window", "bad"]] {
            XCTAssertThrowsError(try CLICommand(arguments: ["topic", "session-paths"] + arguments, environment: [:])) {
                XCTAssertEqual(($0 as? CLIError)?.exitCode, 2)
            }
        }
    }

    func testCacheHitUsesCurrentAliasesAndDisplayDepthWithoutDiscoveryOrWrites() async throws {
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("config.yaml")
        let cache = SessionPathCache(file: root.appendingPathComponent("cache.json"))
        let pattern = root.path + "/missing/*"
        let directory = root.path + "/missing/project"
        let raw = ["H|/h", "R|0", "D|\(directory)|directory|\(directory)"].joined(separator: "\n").replacingOccurrences(of: "|", with: Tmux.separator)
        cache.save(raw, for: SessionPathDiscovery.arguments(for: [SessionPathRoot(path: pattern)]))
        let saved = try Data(contentsOf: cache.file)
        try "sessions:\n  paths:\n    - path: \(pattern)\n      display_depth: 2\n".write(to: file, atomically: true, encoding: .utf8)
        let first = try await ConfigSessions.load(file, cache: cache)
        XCTAssertEqual(first.sessionPaths.map(\.name), ["missing/project"])
        try "sessions:\n  paths:\n    - path: \(pattern)\n  aliases:\n    - \(directory): Current alias\n".write(to: file, atomically: true, encoding: .utf8)
        let aliased = try await ConfigSessions.load(file, cache: cache)
        XCTAssertEqual(aliased.sessionPaths.map(\.displayName), ["Current alias"])
        let filtered = try await ConfigSessions.load(file, within: [], cache: cache)
        XCTAssertTrue(filtered.sessionPaths.isEmpty)
        XCTAssertEqual(try Data(contentsOf: cache.file), saved)
        cache.save("", for: SessionPathDiscovery.arguments(for: [SessionPathRoot(path: pattern)]))
        let empty = try await ConfigSessions.load(file, cache: cache)
        XCTAssertTrue(empty.sessionPaths.isEmpty)
    }

    func testInvalidAndMismatchedCacheFallBackWithoutWriting() async throws {
        let root = try temporaryDirectory()
        let directory = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("config.yaml")
        try "sessions:\n  paths:\n    - path: \(directory.path)\n".write(to: file, atomically: true, encoding: .utf8)
        let cache = SessionPathCache(file: root.appendingPathComponent("cache.json"))
        for contents in ["invalid", "{\"arguments\":[\"different\"],\"output\":\"\"}"] {
            try contents.write(to: cache.file, atomically: true, encoding: .utf8)
            let found = try await ConfigSessions.load(file, cache: cache)
            XCTAssertEqual(found.sessionPaths.map(\.folder.path), [directory.path])
            XCTAssertEqual(try String(contentsOf: cache.file, encoding: .utf8), contents)
        }
    }

    func testMembershipAndWireNullsUseTheMacRows() throws {
        let selected = TopicRecord(id: "selected", title: "Selected")
        let other = TopicRecord(id: "other", title: "Other")
        var settled = TopicRecord(id: "settled", title: "Settled")
        settled.settledAt = "2026-01-01"
        let paths = SessionPathDiscovery.sessionPaths(in: [
            "H|/h", "R|0", "D|/repo|directory|/repo", "D|/bare|bare|/bare",
            "W|worktree /bare/main", "W|detached", "W|", "W|worktree /external", "W|branch refs/heads/fix"
        ].joined(separator: "\n").replacingOccurrences(of: "|", with: Tmux.separator), roots: [SessionPathRoot(path: "/*")], aliases: [:])
        let windows = [window("@1", session: "$1", topic: "selected", directory: "/repo/sub"),
                       window("@2", session: "$2", topic: "other", directory: "/repo/sub"),
                       window("@3", session: "$2", topic: "other", directory: "/other"),
                       window("@4", session: "$3", topic: nil, directory: "/loose"),
                       window("@5", session: "$4", topic: "settled", directory: "/old")]
        let choices = TopicSessionPathChoices(topic: selected, records: [selected, other, settled], windows: windows, sessionPaths: paths)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(TopicSessionPathsInvocation.render(choices, output: .json).utf8)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["topic", "rows", "sessions"])
        let rows = try XCTUnwrap(json["rows"] as? [[String: Any]])
        let repo = try XCTUnwrap(rows.first { $0["directory"] as? String == "/repo" })
        XCTAssertEqual(repo["in_this_topic"] as? Bool, false)
        XCTAssertTrue(repo["worktree"] is NSNull)
        XCTAssertTrue(repo["last_visit"] is NSNull)
        XCTAssertEqual((repo["also_in"] as? [[String: String]])?.first, ["id": "other", "label": "Other"])
        let bare = try XCTUnwrap(rows.first { $0["directory"] as? String == "/bare/main" })
        XCTAssertEqual(bare["kind"] as? String, "session_path")
        XCTAssertTrue((bare["worktree"] as? [String: Any])?["branch"] is NSNull)
        XCTAssertEqual(rows.first { $0["directory"] as? String == "/external" }?["kind"] as? String, "worktree")
        let sessions = try XCTUnwrap(json["sessions"] as? [[String: Any]])
        XCTAssertEqual(sessions.compactMap { $0["id"] as? String }, ["$2", "$3", "$4"])
        XCTAssertTrue(sessions[1]["topic"] is NSNull)
        XCTAssertTrue(sessions[2]["topic"] is NSNull)
    }

    func testReadResolvesEmptyAndDormantTopicsAndLeavesRecordsUnchanged() throws {
        let root = try temporaryDirectory()
        let paths = MuxifyPaths(environment: ["XDG_STATE_HOME": root.path], home: "/none")
        let store = TopicStore(paths: paths)
        try store.write { transaction in
            try transaction.create(TopicRecord(id: "empty", title: "Empty"))
            var dormant = TopicRecord(id: "dormant", title: "Dormant")
            dormant.sessions = [.object(["directory": .string("/repo")])]
            try transaction.create(dormant)
            try transaction.create(TopicRecord(id: "duplicate1", title: "Duplicate"))
            try transaction.create(TopicRecord(id: "duplicate2", title: "Duplicate"))
        }
        let saved = try store.read()
        let service = EnvironmentService(paths: paths, server: EmptyServer(), sessionPaths: [SessionPath(path: "/repo", name: "repo")])
        for value in ["empty", "Empty", "dormant", "Dormant"] {
            guard case .topicSessionPaths(let invocation) = try CLICommand(arguments: ["topic", "session-paths", "--topic", value], environment: [:]) else {
                return XCTFail("Wrong command")
            }
            let choices = try service.sessionPathChoices(for: invocation.target).get()
            XCTAssertEqual(choices.rows.first?.inThisTopic, value.lowercased() == "dormant")
        }
        for value in ["missing", "Duplicate"] {
            guard case .topicSessionPaths(let invocation) = try CLICommand(arguments: ["topic", "session-paths", "--topic", value, "--json"], environment: [:]) else {
                return XCTFail("Wrong command")
            }
            switch service.sessionPathChoices(for: invocation.target) {
            case .success: XCTFail("Expected target failure")
            case .failure(let failure):
                XCTAssertEqual(failure.phase, .nothingChanged)
                XCTAssertEqual(CLIError(failure).exitCode, 1)
            }
        }
        XCTAssertEqual(try TopicStore(paths: paths).read(), saved)
    }

    private struct EmptyServer: TmuxRunning {
        func run(_ arguments: [String]) throws -> String { throw CancellationError() }
        func snapshot() throws -> TmuxSnapshot {
            TmuxSnapshot(windows: [], clients: [], panes: [], serverRunning: false)
        }
    }

    func testExactRememberedAndLiveFolderIdentityIncludesSymlinks() throws {
        let root = try temporaryDirectory()
        let folder = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        let paths = [SessionPath(path: folder.path, name: "repo")]
        var topic = TopicRecord(id: "selected", title: "Selected")
        for directory in [folder.path + "/sub", link.path] {
            topic.sessions = [.object(["directory": .string(directory)])]
            let choices = TopicSessionPathChoices(topic: topic, records: [topic], windows: [], sessionPaths: paths)
            XCTAssertEqual(choices.rows.first?.inThisTopic, directory == link.path)
        }
        topic.sessions = []
        var live = window("@1", session: "$1", topic: topic.id, directory: link.path)
        live.sessionPath = ""
        let choices = TopicSessionPathChoices(topic: topic, records: [topic], windows: [live], sessionPaths: paths)
        XCTAssertEqual(choices.rows.first?.inThisTopic, true)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func window(_ id: String, session: String, topic: String?, directory: String) -> TmuxWindow {
        TmuxWindow(id: id, sessionID: session, sessionName: "s" + session, index: 0,
                   name: "shell", paneTitle: "", path: directory, command: "zsh",
                   isActive: true, paneCount: 1, hasBell: false, sessionActivity: 0, agent: "",
                   storedBrowser: StoredBrowser(), openRequests: [], topicID: topic, sessionPath: directory)
    }
}
