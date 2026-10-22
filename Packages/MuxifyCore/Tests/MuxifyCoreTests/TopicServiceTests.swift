import XCTest
@testable import MuxifyCore

/// The service against a throwaway tmux server and state folder in the test's own run directory.
final class TopicServiceTests: XCTestCase {
    private var root: URL!
    private var paths: MuxifyPaths!
    private var server: TmuxServer!
    private var sessionPath: SessionPath!
    private var tools: SessionPath!

    override func setUpWithError() throws {
        try XCTSkipIf(Tmux.binary == nil, "tmux is not installed")
        // A short path: a socket path must fit in 104 bytes.
        root = URL(fileURLWithPath: "/tmp/mxt-" + UUID().uuidString.prefix(8), isDirectory: true)
        let work = root.appendingPathComponent("work/game", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        paths = MuxifyPaths(environment: ["XDG_STATE_HOME": root.appendingPathComponent("state").path], home: "/nonexistent")
        server = TmuxServer(socketPath: root.appendingPathComponent("tmux").path, configPath: "/dev/null")
        try server.run(["new-session", "-d", "-s", "main", "-c", root.path])
        try assertThrowawayServer()
        sessionPath = SessionPath(path: work.path, name: "game")
        let toolsWork = root.appendingPathComponent("work/tools", isDirectory: true)
        try FileManager.default.createDirectory(at: toolsWork, withIntermediateDirectories: true)
        tools = SessionPath(path: toolsWork.path, name: "tools")
    }

    override func tearDownWithError() throws {
        if let server, let socket = try? server.run(["display-message", "-p", "#{socket_path}"]),
           socket.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(root.path + "/") {
            _ = try? server.run(["kill-server"])
        }
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func service(tags: [String] = ["backend", "release"]) -> TopicService {
        var topics = Config.Topics()
        topics.tags = ConfigTags(tags.map { TagDefinition(tag: Tag(name: $0)!) })
        return TopicService(paths: paths, server: server, sessionPaths: [sessionPath, tools], topics: topics)
    }

    private func records() throws -> [TopicRecord] { try TopicStore(paths: paths).read().records }

    private func change(_ response: TopicResponse, file: StaticString = #filePath, line: UInt = #line) throws -> TopicChange {
        guard case .changed(let change) = response else { XCTFail("\(response)", file: file, line: line); throw CancellationError() }
        return change
    }

    private func failure(_ response: TopicResponse, file: StaticString = #filePath, line: UInt = #line) throws -> TopicFailure {
        guard case .failed(let failure) = response else { XCTFail("\(response)", file: file, line: line); throw CancellationError() }
        return failure
    }

    private func assertThrowawayServer() throws {
        let socket = try server.run(["display-message", "-p", "#{socket_path}"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard socket.hasPrefix(root.path + "/") else { throw CancellationError() }
    }

    func testConfirmationRejectsChangedSessionsBeforeAnyEdits() throws {
        for dormant in [false, true] {
            let id = try XCTUnwrap(change(service().handle(TopicRequest(.create(title: dormant ? "Dormant" : "Live", sessionPath: dormant ? nil : sessionPath.folder.path)))).topicID)
            var reviewed = try service().settleChoices(for: .topic(.id(id))).get()
            for index in reviewed.indices { reviewed[index].disposition = .keep }
            _ = try change(service().handle(TopicRequest(.addSession(sessionPath: tools.folder.path, workingCopy: .directory), target: .topic(.id(id)))))
            let before = try records()
            let windows = server.snapshot().windows
            for command in [TopicCommand.settle(choices: reviewed, outcome: "Done"), .forget(choices: reviewed, worktrees: [])] {
                try assertThrowawayServer()
                let failed = try failure(service().handle(TopicRequest(command, target: .topic(.id(id)), expectedSessionIDs: reviewed.map(\.id))))
                XCTAssertEqual(failed.kind, .topicMembershipChanged)
                XCTAssertEqual(failed.phase, .nothingChanged)
                XCTAssertEqual(try records(), before)
                let after = server.snapshot().windows
                XCTAssertEqual(after.map(\.id), windows.map(\.id))
                XCTAssertEqual(after.map(\.sessionID), windows.map(\.sessionID))
                XCTAssertEqual(after.map(\.sessionName), windows.map(\.sessionName))
                XCTAssertEqual(after.map(\.topicID), windows.map(\.topicID))
                XCTAssertEqual(after.map(\.activePaneID), windows.map(\.activePaneID))
                XCTAssertEqual(after.map(\.paneCount), windows.map(\.paneCount))
            }
        }
    }

    func testConfirmationRejectsNewWindowsAndPanesInReviewedSessions() throws {
        for addWindow in [false, true] {
            let id = try XCTUnwrap(change(service().handle(TopicRequest(.create(title: "Changed impact", sessionPath: sessionPath.folder.path)))).topicID)
            let choices = try service().settleChoices(for: .topic(.id(id))).get()
            let session = try XCTUnwrap(choices.first)
            let window = try XCTUnwrap(server.snapshot().windows.first { $0.sessionID == session.id })
            if addWindow {
                _ = try server.run(["new-window", "-d", "-t", session.id + ":"])
            } else {
                _ = try server.run(["split-window", "-d", "-t", window.id])
            }
            let before = try records()
            let panes = Set(server.snapshot().panes.map(\.id))
            for command in [TopicCommand.settle(choices: choices, outcome: "Done"), .forget(choices: choices, worktrees: [])] {
                try assertThrowawayServer()
                let failed = try failure(service().handle(TopicRequest(command, target: .topic(.id(id)), expectedSessionIDs: choices.map(\.id))))
                XCTAssertEqual(failed.kind, .topicMembershipChanged)
                XCTAssertEqual(failed.phase, .nothingChanged)
                XCTAssertEqual(try records(), before)
                XCTAssertEqual(Set(server.snapshot().panes.map(\.id)), panes)
            }
            var refreshed = try service().settleChoices(for: .topic(.id(id))).get()
            for index in refreshed.indices { refreshed[index].disposition = .kill }
            _ = try change(service().handle(TopicRequest(.settle(choices: refreshed, outcome: "Reviewed again"),
                                                        target: .topic(.id(id)), expectedSessionIDs: refreshed.map(\.id))))
            XCTAssertFalse(server.snapshot().windows.contains { $0.sessionID == session.id })
        }
    }

    func testConfirmationAcceptsTheSameSessionSet() throws {
        for forget in [false, true] {
            let id = try XCTUnwrap(change(service().handle(TopicRequest(.create(title: forget ? "Forget reviewed" : "Settle reviewed", sessionPath: sessionPath.folder.path)))).topicID)
            _ = try change(service().handle(TopicRequest(.addSession(sessionPath: tools.folder.path, workingCopy: .directory), target: .topic(.id(id)))))
            var choices = try service().settleChoices(for: .topic(.id(id))).get()
            for index in choices.indices { choices[index].disposition = .keep }
            let command: TopicCommand = forget ? .forget(choices: choices, worktrees: []) : .settle(choices: choices, outcome: "Done")
            try assertThrowawayServer()
            _ = try change(service().handle(TopicRequest(command, target: .topic(.id(id)), expectedSessionIDs: choices.reversed().map(\.id))))
            let windows = server.snapshot().windows
            for choice in choices {
                let kept = try XCTUnwrap(windows.first { $0.sessionID == choice.id })
                XCTAssertNil(kept.topicID)
            }
            if forget { XCTAssertFalse(try records().contains { $0.id == id }) }
            else { XCTAssertNotNil(try records().first { $0.id == id }?.settledAt) }
        }
    }

    func testForgetKillsOrKeepsLiveSessionsAndCannotReopenTheTopic() throws {
        let id = try XCTUnwrap(change(service().handle(TopicRequest(.create(title: "Forget", sessionPath: sessionPath.folder.path)))).topicID)
        _ = try change(service().handle(TopicRequest(.addSession(sessionPath: tools.folder.path, workingCopy: .directory), target: .topic(.id(id)))))
        var choices = try service().forgetChoices(for: .topic(.id(id))).get().sessions
        choices[0].disposition = .kill
        choices[1].disposition = .keep
        try assertThrowawayServer()
        let forgotten = try change(service().handle(TopicRequest(.forget(choices: choices, worktrees: []), target: .topic(.id(id)))))
        XCTAssertEqual(forgotten.topicID, id)
        XCTAssertFalse(forgotten.created)
        XCTAssertFalse(try records().contains { $0.id == id })
        XCTAssertFalse(server.snapshot().windows.contains { $0.sessionID == choices[0].id })
        let kept = try XCTUnwrap(server.snapshot().windows.first { $0.sessionID == choices[1].id })
        XCTAssertNil(kept.topicID)
        XCTAssertEqual(try failure(service().handle(TopicRequest(.reopen, target: .topic(.id(id))))).kind, .topicUnavailable)
    }

    func testForgetRemovesDormantSnoozedAndSettledRecords() throws {
        for state in ["dormant", "snoozed", "settled"] {
            var record = TopicRecord(id: state, title: state)
            if state == "snoozed" { record.snoozedUntil = "never" }
            if state == "settled" { record.settledAt = "2026-10-11T00:00:00Z" }
            try TopicStore(paths: paths).write { try $0.create(record) }
            try assertThrowawayServer()
            _ = try change(service().handle(TopicRequest(.forget(choices: [], worktrees: []), target: .topic(.id(state)))))
            XCTAssertFalse(FileManager.default.fileExists(atPath: paths.topics.appendingPathComponent(state + ".json").path))
        }
    }

    func testForgetRemovesAnUnmergedCleanWorktreeAndKeepsItsBranch() throws {
        let app = try repository()
        _ = try addNewWorktree(of: app, base: nil, title: "Forget clean")
        let id = try XCTUnwrap(records().first?.id)
        let path = paths.worktrees.appendingPathComponent("app/forget-clean").path
        try git(["commit", "-q", "--allow-empty", "-m", "unmerged"], in: path)
        let service = TopicService(paths: paths, server: server, sessionPaths: [app])
        XCTAssertTrue(try service.settleChoices(for: .topic(.id(id))).get().allSatisfy { $0.worktree == nil })
        XCTAssertEqual(try service.forgetChoices(for: .topic(.id(id))).get().worktrees.filter(\.isClean).map(\.id), [path])
        try assertThrowawayServer()
        var killed = try service.forgetChoices(for: .topic(.id(id))).get().sessions
        for index in killed.indices { killed[index].disposition = .kill }
        _ = try change(service.handle(TopicRequest(.forget(choices: killed, worktrees: [path]), target: .topic(.id(id)))))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertFalse(try git(["branch", "--list", "forget-clean"], in: app.folder.path).isEmpty)
    }

    func testForgetOfASettledTopicRemovesItsRememberedWorktree() throws {
        let app = try repository()
        _ = try addNewWorktree(of: app, base: nil, title: "Remembered")
        let id = try XCTUnwrap(records().first?.id)
        let path = paths.worktrees.appendingPathComponent("app/remembered").path
        let service = TopicService(paths: paths, server: server, sessionPaths: [app])
        try assertThrowawayServer()
        var killed = try service.settleChoices(for: .topic(.id(id))).get()
        for index in killed.indices { killed[index].disposition = .kill }
        _ = try change(service.handle(TopicRequest(.settle(choices: killed, outcome: "Done"), target: .topic(.id(id)))))
        let choices = try service.forgetChoices(for: .topic(.id(id))).get()
        XCTAssertTrue(choices.sessions.isEmpty)
        XCTAssertEqual(choices.worktrees.map(\.id), [path])
        try assertThrowawayServer()
        _ = try change(service.handle(TopicRequest(.forget(choices: [], worktrees: [path]), target: .topic(.id(id)))))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(try records().isEmpty)
    }

    func testForgetKeepsDirtyWorktreesAndWorktreesUsedByKeptSessions() throws {
        let app = try repository()
        for dirty in [false, true] {
            let title = dirty ? "Dirty" : "Kept"
            _ = try addNewWorktree(of: app, base: nil, title: title)
            let id = try XCTUnwrap(records().first { $0.title == title }?.id)
            let path = paths.worktrees.appendingPathComponent("app/" + title.lowercased()).path
            if dirty { try "draft".write(toFile: path + "/draft", atomically: true, encoding: .utf8) }
            let service = TopicService(paths: paths, server: server, sessionPaths: [app])
            var choices = try service.forgetChoices(for: .topic(.id(id))).get()
            XCTAssertEqual(choices.worktrees.first?.isClean, !dirty)
            if !dirty { choices.sessions[0].disposition = .keep }
            try assertThrowawayServer()
            _ = try change(service.handle(TopicRequest(.forget(choices: choices.sessions, worktrees: [path]), target: .topic(.id(id)))))
            XCTAssertTrue(FileManager.default.fileExists(atPath: path))
            XCTAssertFalse(try records().contains { $0.id == id })
        }
    }

    func testCreateInASessionPathWritesTheRecordAndStartsItsSession() throws {
        let created = try change(service().handle(TopicRequest(.create(title: "Fix reward", sessionPath: sessionPath.folder.path))))
        let record = try XCTUnwrap(records().first)
        XCTAssertEqual(created.topicID, record.id)
        XCTAssertTrue(created.created)
        XCTAssertEqual(record.title, "Fix reward")
        let windows = server.snapshot().windows.filter { $0.topicID == record.id }
        XCTAssertEqual(windows.map(\.sessionName), ["game/fix-reward"])
        XCTAssertEqual(created.shown, WindowID(rawValue: windows[0].id).map { .window($0) })
    }

    func testCreateWithNoSessionPathAndNoTargetMakesATopicWithNoSession() throws {
        let sessions = server.snapshot().windows.count
        let created = try change(service().handle(TopicRequest(.create(title: "  Plan the week ", sessionPath: nil))))
        let record = try XCTUnwrap(records().first)
        XCTAssertEqual(record.title, "Plan the week")
        XCTAssertEqual(created.shown, .emptyTopic(id: record.id))
        XCTAssertEqual(server.snapshot().windows.count, sessions)
    }

    func testTwoEditsAtOnceChooseDifferentNamesBecauseOneWaitsForTheOther() throws {
        let service = service()
        let responses = Responses()
        DispatchQueue.concurrentPerform(iterations: 2) { _ in
            responses.append(service.handle(TopicRequest(.create(title: "Fix", sessionPath: sessionPath.folder.path))))
        }
        for response in responses.all { _ = try change(response) }
        XCTAssertEqual(Set(try records().compactMap(\.slug)), ["fix", "fix-2"])
        XCTAssertEqual(Set(server.snapshot().windows.filter { $0.topicID != nil }.map(\.sessionName)), ["game/fix", "game/fix-2"])
    }

    func testMoveTakesAWholeSessionIntoTheTopicThatARefNames() throws {
        try server.run(["new-session", "-d", "-s", "loose", "-c", sessionPath.folder.path])
        let topic = try XCTUnwrap(change(service().handle(TopicRequest(.create(title: "Release", sessionPath: nil)))).topicID)
        let loose = try XCTUnwrap(server.snapshot().windows.first { $0.sessionName == "loose" })
        let moved = try change(service().handle(TopicRequest(.move(to: .topic(.named("Release"))),
                                                             target: .session(SessionID(rawValue: loose.sessionID)!))))
        XCTAssertEqual(moved.shown, .window(WindowID(rawValue: loose.id)!))
        let window = try XCTUnwrap(server.snapshot().windows.first { $0.id == loose.id })
        XCTAssertEqual(window.topicID, topic)
        XCTAssertEqual(window.sessionName, "loose/release")
        let again = try change(service().handle(TopicRequest(.move(to: .topic(.id(topic))), target: .session(SessionID(rawValue: loose.sessionID)!))))
        XCTAssertNil(again.topicID, "a second move changes nothing")
    }

    /// The Topics list as the app orders it: Topic ids, and `lock:` with the Session name for a Locked Session.
    private func topicList() throws -> [String] {
        let windows = server.snapshot().windows
        return TopicOrder.sorted(TopicListEntry.all(records: try records(), windows: windows)).map { entry in
            switch entry {
            case .topic(let record): return record.title ?? record.id
            case .lock(let lock): return "lock:" + (windows.first { $0.sessionID == lock.sessionID }?.sessionName ?? "?")
            }
        }
    }

    func testLockPutsANoTopicSessionLastAmongTheTopicsAndUnlockEndsIt() throws {
        try server.run(["new-session", "-d", "-s", "notes", "-c", sessionPath.folder.path])
        _ = try change(service().handle(TopicRequest(.create(title: "First", sessionPath: nil))))
        _ = try change(service().handle(TopicRequest(.create(title: "Second", sessionPath: sessionPath.folder.path))))
        let locked = try change(service().handle(TopicRequest(.lock, target: .sessionName("notes"))))
        XCTAssertNil(locked.topicID)
        XCTAssertEqual(try topicList(), ["First", "Second", "lock:notes"])
        _ = try change(service().handle(TopicRequest(.create(title: "Third", sessionPath: nil))))
        _ = try change(service().handle(TopicRequest(.lock, target: .sessionName("notes"))))
        XCTAssertEqual(try topicList(), ["First", "Second", "lock:notes", "Third"], "a Locked Session keeps its place")

        let inTopic = try failure(service().handle(TopicRequest(.lock, target: .sessionName("game/second"))))
        XCTAssertEqual(inTopic.kind, .sessionInTopic)
        XCTAssertEqual(inTopic.phase, .nothingChanged)
        XCTAssertEqual(try failure(service().handle(TopicRequest(.lock, target: .sessionName("missing")))).kind, .sourceUnavailable)

        _ = try change(service().handle(TopicRequest(.unlock, target: .sessionName("notes"))))
        XCTAssertEqual(try topicList(), ["First", "Second", "Third"])
        XCTAssertEqual(try server.run(["show-options", "-qv", "-t", "notes", SessionLock.option]), "")
    }

    func testSnoozeOfSeveralTopicsWritesEachOnceAndReportsTheShortenedOnes() throws {
        let first = try XCTUnwrap(change(service().handle(TopicRequest(.create(title: "First", sessionPath: nil)))).topicID)
        let second = try XCTUnwrap(change(service().handle(TopicRequest(.create(title: "Second", sessionPath: nil)))).topicID)
        _ = try service().handle(TopicRequest(.snooze(until: .never, topics: [.id(second)])))
        let tomorrow = SnoozeDeadline.at(Date().addingTimeInterval(86_400))
        let response = service().handle(TopicRequest(.snooze(until: tomorrow, topics: [.named("Second"), .id(first), .id(second)])))
        XCTAssertEqual(response, .snoozeChanged(TopicSnoozeChange(topicIDs: [second, first], shortened: [second])))
        func snoozes() throws -> [String: String?] { Dictionary(uniqueKeysWithValues: try records().map { ($0.id, $0.snoozedUntil) }) }
        XCTAssertEqual(try snoozes(), [first: tomorrow.stored, second: tomorrow.stored])

        let both = try failure(service().handle(TopicRequest(.unsnooze(topics: [.id(first)]), target: .topic(.id(second)))))
        XCTAssertEqual(both.kind, .unsupported)
        XCTAssertEqual(try snoozes(), [first: tomorrow.stored, second: tomorrow.stored], "a request with a target and Topics changes nothing")
        XCTAssertEqual(service().handle(TopicRequest(.unsnooze(topics: [.id(first)]))), .snoozeChanged(TopicSnoozeChange(topicIDs: [first])))
        XCTAssertEqual(try snoozes(), [first: nil, second: tomorrow.stored])
    }

    func testTagsChangeOnlyTheTagsOfTheTargetsOpenTopicAndANewTopicGetsItsTags() throws {
        let backend = Tag(name: "backend")!, release = Tag(name: "release")!
        let id = try XCTUnwrap(change(service().handle(TopicRequest(.create(title: "Fix", sessionPath: nil, tags: [release])))).topicID)
        func current() throws -> TopicRecord { try XCTUnwrap(records().first { $0.id == id }) }
        XCTAssertEqual(try current().tags, [release])
        let before = try current()
        XCTAssertEqual(try change(service().handle(TopicRequest(.tags(.add([backend])), target: .topic(.named("Fix"))))).topicID, id)
        XCTAssertEqual(try current().tags, [backend, release])
        _ = try change(service().handle(TopicRequest(.tags(.remove([release])), target: .topic(.id(id)))))
        var expected = before
        expected.tags = [backend]
        XCTAssertEqual(try current(), expected, "a Tag change changes nothing else in the record")
        _ = try change(service().handle(TopicRequest(.tags(.set([])), target: .topic(.id(id)))))
        XCTAssertEqual(try current().tags, [])

        let withSession = try XCTUnwrap(change(service().handle(TopicRequest(.create(title: "Live", sessionPath: sessionPath.folder.path,
                                                                                         tags: [backend])))).topicID)
        XCTAssertEqual(try records().first { $0.id == withSession }?.tags, [backend], "a new Topic with a Session gets its Tags too")

        let missing = try failure(service().handle(TopicRequest(.tags(.add([backend])), target: .topic(.id("nope")))))
        XCTAssertEqual(missing.kind, .topicUnavailable)
        XCTAssertEqual(missing.phase, .nothingChanged)
        let noTarget = try failure(service().handle(TopicRequest(.tags(.add([backend])))))
        XCTAssertEqual(noTarget.kind, .noTarget)
    }

    func testOnlyTheTagsTheConfigDefinesCanBeAddedAndATagItNoLongerDefinesCanStayOrGo() throws {
        let backend = Tag(name: "backend")!, release = Tag(name: "release")!, old = Tag(name: "old")!
        let id = try XCTUnwrap(change(service().handle(TopicRequest(.create(title: "Fix", sessionPath: nil, tags: [release])))).topicID)
        func current() throws -> Set<Tag> { try XCTUnwrap(records().first { $0.id == id }).tags }
        try TopicStore(paths: paths).write { try $0.changeTags(of: id, .add([old])) }

        let undefined = try failure(service().handle(TopicRequest(.tags(.add([backend, Tag(name: "bazel")!])), target: .topic(.id(id)))))
        XCTAssertEqual(undefined.kind, .tagUndefined)
        XCTAssertEqual(undefined.phase, .nothingChanged)
        XCTAssertTrue(undefined.message.contains("#bazel") && undefined.message.contains("topics.tags"), undefined.message)
        XCTAssertEqual(try current(), [old, release], "a refused change writes nothing, also not its defined Tags")

        _ = try change(service().handle(TopicRequest(.tags(.set([old, backend])), target: .topic(.id(id)))))
        XCTAssertEqual(try current(), [old, backend], "a Tag the Config no longer defines stays when the change keeps it")
        _ = try change(service().handle(TopicRequest(.tags(.remove([old])), target: .topic(.id(id)))))
        XCTAssertEqual(try current(), [backend])
        XCTAssertEqual(try failure(service().handle(TopicRequest(.tags(.add([old])), target: .topic(.id(id))))).kind, .tagUndefined,
                       "nothing adds a Tag the Config no longer defines again")

        let off = try failure(service(tags: []).handle(TopicRequest(.create(title: "Untagged", sessionPath: nil, tags: [backend]))))
        XCTAssertEqual(off.kind, .tagUndefined, "with Tags off, no Tag can be added")
        XCTAssertFalse(try records().contains { $0.title == "Untagged" }, "a refused New Topic writes no record")
    }

    func testUnsnoozePutsTheTopicBelowTheLocksAtTheConfiguredEnd() throws {
        try server.run(["new-session", "-d", "-s", "notes", "-c", sessionPath.folder.path])
        let first = try XCTUnwrap(change(service().handle(TopicRequest(.create(title: "First", sessionPath: nil)))).topicID)
        _ = try change(service().handle(TopicRequest(.create(title: "Second", sessionPath: nil))))
        _ = try change(service().handle(TopicRequest(.lock, target: .sessionName("notes"))))
        _ = service().handle(TopicRequest(.snooze(until: .never, topics: [.id(first)])))
        XCTAssertEqual(try topicList(), ["First", "Second", "lock:notes"], "a Snoozed Topic keeps its stored order")
        XCTAssertEqual(service().handle(TopicRequest(.unsnooze(topics: [.id(first)]))), .snoozeChanged(TopicSnoozeChange(topicIDs: [first])))
        XCTAssertEqual(try topicList(), ["Second", "lock:notes", "First"])
        let top = TopicService(paths: paths, server: server, sessionPaths: [sessionPath], topics: { var topics = Config.Topics(); topics.insertPosition = .top; return topics }())
        _ = top.handle(TopicRequest(.snooze(until: .never, topics: [.id(first)])))
        _ = top.handle(TopicRequest(.unsnooze(topics: [.id(first)])))
        XCTAssertEqual(try topicList(), ["First", "Second", "lock:notes"])
    }

    func testALockedSessionThatGoesIntoATopicLosesItsLock() throws {
        try server.run(["new-session", "-d", "-s", "notes", "-c", sessionPath.folder.path])
        try server.run(["new-session", "-d", "-s", "chores", "-c", tools.folder.path])
        _ = try change(service().handle(TopicRequest(.create(title: "First", sessionPath: nil))))
        _ = try change(service().handle(TopicRequest(.lock, target: .sessionName("notes"))))
        _ = try change(service().handle(TopicRequest(.lock, target: .sessionName("chores"))))
        _ = try change(service().handle(TopicRequest(.create(title: "Second", sessionPath: nil))))
        XCTAssertEqual(try topicList(), ["First", "lock:notes", "lock:chores", "Second"])

        let notes = try XCTUnwrap(SessionID(rawValue: server.snapshot().windows.first { $0.sessionName == "notes" }!.sessionID))
        let created = try change(service().handle(TopicRequest(.move(to: .newTopic(title: "Notes work")), target: .session(notes))))
        XCTAssertTrue(created.created)
        XCTAssertEqual(try topicList(), ["First", "Notes work", "lock:chores", "Second"], "the new Topic takes the Lock's place")

        let chores = try XCTUnwrap(SessionID(rawValue: server.snapshot().windows.first { $0.sessionName == "chores" }!.sessionID))
        _ = try change(service().handle(TopicRequest(.move(to: .topic(.named("Second"))), target: .session(chores))))
        XCTAssertEqual(try topicList(), ["First", "Notes work", "Second"], "the Topic that the Session moves to keeps its place")
        XCTAssertTrue(server.snapshot().windows.allSatisfy { $0.lockOrder == nil })
    }

    func testTopInsertionAndReturningTopicsUseTheConfiguredEndAmongLocks() throws {
        let top = TopicService(paths: paths, server: server, sessionPaths: [sessionPath], topics: { var topics = Config.Topics(); topics.insertPosition = .top; return topics }())
        _ = try change(top.handle(TopicRequest(.create(title: "First", sessionPath: nil))))
        let returning = try XCTUnwrap(change(top.handle(TopicRequest(.create(title: "Returning", sessionPath: nil)))).topicID)
        XCTAssertEqual(try topicList(), ["Returning", "First"])
        try server.run(["new-session", "-d", "-s", "notes", "-c", sessionPath.folder.path])
        try server.run(["set-option", "-t", "notes", SessionLock.option, String(Double.greatestFiniteMagnitude)])
        try TopicStore(paths: paths).write { try $0.update(returning) { $0.settledAt = "2026-10-01T00:00:00Z" } }
        _ = try change(service().handle(TopicRequest(.reopen, target: .topic(.id(returning)))))
        XCTAssertEqual(try topicList(), ["First", "lock:notes", "Returning"])
        let lockOrder = try XCTUnwrap(Double(server.run(["show-options", "-qv", "-t", "notes", SessionLock.option]).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertLessThan(lockOrder, Double.greatestFiniteMagnitude, "Reopen must save normalized Lock ranks to tmux")
        try TopicStore(paths: paths).write { try $0.update(returning) { $0.settledAt = "2026-10-01T00:00:00Z" } }
        _ = try change(top.handle(TopicRequest(.startFresh, target: .topic(.id(returning)))))
        XCTAssertEqual(try topicList(), ["Returning", "First", "lock:notes"])
    }

    func testAPathThroughASymlinkFindsTheSessionPathThatTheConfigNames() throws {
        // The Config names the SessionPaths through dev, a symlink to work, as ~/Dev can be; the CLI gives the real path.
        let dev = root.appendingPathComponent("dev")
        try FileManager.default.createSymbolicLink(atPath: dev.path, withDestinationPath: "work")
        let game = SessionPath(path: dev.appendingPathComponent("game").path, name: "game")
        let tools = SessionPath(path: dev.appendingPathComponent("tools").path, name: "tools")
        let service = TopicService(paths: paths, server: server, sessionPaths: [game, tools])
        let real = { (sessionPath: SessionPath) in String(cString: realpath(sessionPath.folder.path, nil)) }
        let id = try XCTUnwrap(change(service.handle(TopicRequest(.create(title: "Ship", sessionPath: real(game))))).topicID)
        _ = try change(service.handle(TopicRequest(.addSession(sessionPath: real(tools), workingCopy: .directory), target: .topic(.id(id)))))
        let record = try XCTUnwrap(records().first { $0.id == id })
        XCTAssertEqual(record.sessions.first?["directory"]?.string, game.folder.path, "the record keeps the path that the Config wrote")
        XCTAssertEqual(record.sessions.map { $0["directory"]?.string }, [game.folder.path, tools.folder.path])
    }

    func testAFailureSaysHowFarTheRequestGot() throws {
        let unknown = try failure(service().handle(TopicRequest(.create(title: "X", sessionPath: "/nowhere"))))
        XCTAssertEqual(unknown.kind, .sessionPathUnavailable)
        XCTAssertEqual(unknown.phase, .nothingChanged)
        XCTAssertEqual(try failure(service().handle(TopicRequest(.rename(title: "Y")))).kind, .noTarget)
        _ = try change(service().handle(TopicRequest(.create(title: "Same", sessionPath: nil))))
        _ = try change(service().handle(TopicRequest(.create(title: "Same", sessionPath: nil))))
        XCTAssertEqual(try failure(service().handle(TopicRequest(.rename(title: "Z"), target: .topic(.named("Same"))))).kind, .topicAmbiguous)
        XCTAssertEqual(try failure(service().handle(TopicRequest(.reopen, target: .topic(.id("missing"))))).kind, .topicUnavailable)
        XCTAssertTrue(try records().allSatisfy { $0.title == "Same" })
    }

    func testAFailureOfTheStateFolderNamesTheFolderAndAPlainReason() throws {
        try FileManager.default.createDirectory(at: paths.state, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: paths.state.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.state.path) }
        let denied = try failure(service().handle(TopicRequest(.create(title: "X", sessionPath: nil))))
        XCTAssertEqual(denied.kind, .storeFailed)
        XCTAssertEqual(denied.message, "Muxify could not read or write the Topic records in \(paths.state.path). Permission denied.")
        XCTAssertEqual(denied.phase.summary, "No changes were made.")

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.state.path)
        XCTAssertEqual(try failure(service().handle(TopicRequest(.create(title: "X", sessionPath: "/nowhere")))).message,
                       "No launch directory is available at /nowhere.")
        try FileManager.default.removeItem(at: paths.state)
        try Data().write(to: paths.state)
        let notAFolder = try failure(service().handle(TopicRequest(.list)))
        XCTAssertEqual(notAFolder.message, "Muxify could not read or write the Topic records in \(paths.state.path). "
                       + "The file “muxify” couldn’t be saved in the folder “state” because a file with the same name already exists.")
    }

    func testAnEditWaitsForTheEditLockAndGivesUpAsStoreBusy() throws {
        let holder = try hold(paths.editLock)
        defer { if holder.isRunning { kill(holder.processIdentifier, SIGKILL) } }
        let service = TopicService(paths: paths, server: server, sessionPaths: [sessionPath, tools], editLockTimeout: 0.3)
        let busy = try failure(service.handle(TopicRequest(.create(title: "Blocked", sessionPath: nil))))
        XCTAssertEqual(busy.kind, .storeBusy)
        XCTAssertEqual(busy.phase, .nothingChanged)
        XCTAssertEqual(try records(), [])
        guard case .topics = service.handle(TopicRequest(.list)) else { return XCTFail("a list does not wait for an edit") }
    }

    func testListGivesTheOpenTopicsWithTheirLabelsAndSkipsInvalidFiles() throws {
        try FileManager.default.createDirectory(at: paths.topics, withIntermediateDirectories: true)
        let files = [
            "a.json": #"{"id":"a","title":"Fix"}"#, "b.json": #"{"id":"b","slug":"fix-login"}"#, "c.json": #"{"id":"c","title":""}"#,
            "d.json": #"{"id":"d","title":"Done","settled_at":"2026-10-01T10:00:00Z"}"#,
            "e.json": #"{"id":"e","title":7}"#, "f.json": #"{"id":"other"}"#,
        ]
        for (name, text) in files { try Data(text.utf8).write(to: paths.topics.appendingPathComponent(name)) }
        XCTAssertEqual(service().handle(TopicRequest(.list)), .topics([
            TopicSummary(id: "a", label: "Fix"), TopicSummary(id: "b", label: "fix-login"), TopicSummary(id: "c", label: "Untitled Topic"),
        ]))
    }

    func testTheSettlePreviewOffersEachLiveSessionAndChangesNothing() throws {
        let id = try XCTUnwrap(change(service().handle(TopicRequest(.create(title: "Ship", sessionPath: sessionPath.folder.path)))).topicID)
        let before = try Data(contentsOf: paths.topics.appendingPathComponent(id + ".json"))
        let choices = try service().settleChoices(for: .topic(.id(id))).get()
        XCTAssertEqual(choices.map(\.name), ["game/ship"])
        XCTAssertEqual(try Data(contentsOf: paths.topics.appendingPathComponent(id + ".json")), before)
    }

    /// A Topic with a Session in game and one in tools.
    private func twoSessionPathTopic(_ title: String) throws -> String {
        let id = try XCTUnwrap(change(service().handle(TopicRequest(.create(title: title, sessionPath: sessionPath.folder.path)))).topicID)
        _ = try change(service().handle(TopicRequest(.addSession(sessionPath: tools.folder.path, workingCopy: .directory), target: .topic(.id(id)))))
        return id
    }

    private func sessions(of topic: String) -> [String] {
        Set(server.snapshot().windows.filter { $0.topicID == topic }.map(\.sessionName)).sorted()
    }

    func testMovingASessionKeepsTheTopicsSessionsInThatOrderAndSortingByCreationLetsThemGo() throws {
        let id = try twoSessionPathTopic("Order")
        let live = server.snapshot().windows.filter { $0.topicID == id }
        let game = try XCTUnwrap(live.first { $0.sessionName == "game/order" }), tools = try XCTUnwrap(live.first { $0.sessionName == "tools/order" })
        let paths = { try XCTUnwrap(self.records().first { $0.id == id }).sessions.compactMap { $0["directory"]?.string }.map(Folder.local) }
        _ = try change(service().handle(TopicRequest(.moveSession(to: .before(SessionID(rawValue: game.sessionID)!)),
                                                     target: .session(SessionID(rawValue: tools.sessionID)!))))
        XCTAssertEqual(try paths(), [tools.sessionPath, game.sessionPath].map(Folder.local))
        XCTAssertEqual(try records().first { $0.id == id }?.hasManualSessionOrder, true)

        _ = try change(service().handle(TopicRequest(.sortSessions, target: .topic(.id(id)))))
        XCTAssertEqual(try records().first { $0.id == id }?.hasManualSessionOrder, false)
        let missing = try failure(service().handle(TopicRequest(.moveSession(to: .after(SessionID(rawValue: "$999")!)),
                                                                target: .session(SessionID(rawValue: tools.sessionID)!))))
        XCTAssertEqual(missing.kind, .sourceUnavailable)
        XCTAssertEqual(missing.phase, .nothingChanged)
    }

    func testSettleSavesTheOutcomeAndKillsOrKeepsEachSessionAsChosen() throws {
        let id = try twoSessionPathTopic("Ship")
        var choices = try service().settleChoices(for: .topic(.id(id))).get()
        XCTAssertEqual(choices.map(\.disposition), [.keep, .keep])
        for index in choices.indices { choices[index].disposition = .kill }
        let toolsIndex = try XCTUnwrap(choices.firstIndex { $0.name == "tools/ship" })
        choices[toolsIndex].disposition = .keep
        _ = try change(service().handle(TopicRequest(.settle(choices: choices, outcome: " Shipped 1.2 "), target: .topic(.id(id)))))
        let record = try XCTUnwrap(records().first { $0.id == id })
        XCTAssertNotNil(record.settledAt)
        XCTAssertEqual(record.outcome, "Shipped 1.2")
        XCTAssertEqual(record.sessions.compactMap { $0["directory"]?.string }, [sessionPath.folder.path, tools.folder.path])
        let names = server.snapshot().windows.map(\.sessionName)
        XCTAssertFalse(names.contains("game/ship"), "the killed Session is gone")
        XCTAssertEqual(server.snapshot().windows.filter { $0.sessionName == "tools" }.map(\.topicID), [nil],
                       "the kept Session stays with no Topic")
        XCTAssertEqual(service().handle(TopicRequest(.list)), .topics([]))
    }

    func testRenameChangesTheTitleAndRenamesEverySessionOfTheTopic() throws {
        let id = try twoSessionPathTopic("Ship")
        let before = Set(server.snapshot().windows.filter { $0.topicID == id }.map(\.sessionID))
        _ = try change(service().handle(TopicRequest(.rename(title: " Ship it "), target: .topic(.id(id)))))
        let record = try XCTUnwrap(records().first { $0.id == id })
        XCTAssertEqual(record.title, "Ship it")
        XCTAssertEqual(record.slug, "ship-it")
        XCTAssertEqual(sessions(of: id), ["game/ship-it", "tools/ship-it"])
        XCTAssertEqual(Set(server.snapshot().windows.filter { $0.topicID == id }.map(\.sessionID)), before, "the same Sessions, renamed")
    }

    func testReopenCreatesTheRememberedSessionsAndWindowsOfASettledTopic() throws {
        let id = try XCTUnwrap(change(service().handle(TopicRequest(.create(title: "Ship", sessionPath: sessionPath.folder.path)))).topicID)
        try server.run(["rename-window", "-t", "=game/ship:", "notes"])
        try server.run(["new-window", "-d", "-t", "=game/ship:", "-n", "logs", "-c", root.path])
        try waitForPath(sessionPath.folder.path, of: "=game/ship:notes")
        try waitForPath(root.path, of: "=game/ship:logs")
        _ = try change(service().handle(TopicRequest(.settle(choices: [], outcome: "Paused"), target: .topic(.id(id)))))
        XCTAssertEqual(sessions(of: id), [])
        let reopened = try change(service().handle(TopicRequest(.reopen, target: .topic(.id(id)))))
        XCTAssertEqual(reopened.topicID, id)
        let record = try XCTUnwrap(records().first { $0.id == id })
        XCTAssertNil(record.settledAt)
        let windows = server.snapshot().windows.filter { $0.topicID == id }.sorted { $0.index < $1.index }
        XCTAssertEqual(windows.map(\.sessionName), ["game/ship", "game/ship"])
        XCTAssertEqual(windows.map(\.name), ["notes", "logs"])
        // tmux reports /tmp as /private/tmp.
        XCTAssertEqual(windows.map { ($0.path as NSString).resolvingSymlinksInPath }, [sessionPath.folder.path, root.path])
        XCTAssertEqual(reopened.shown, WindowID(rawValue: windows[0].id).map { .window($0) })
    }

    func testNewTopicFromPaneMovesThePanesWindowIntoANewUntitledTopic() throws {
        try server.run(["new-session", "-d", "-s", "loose", "-c", sessionPath.folder.path])
        let windowID = try server.run(["new-window", "-d", "-P", "-F", "#{window_id}", "-t", "=loose:", "-c", sessionPath.folder.path])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let paneID = try server.run(["display-message", "-p", "-t", windowID, "#{pane_id}"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let extracted = try change(service().handle(TopicRequest(.extract(sessionPath: nil), target: .pane(try XCTUnwrap(PaneID(rawValue: paneID))))))
        let record = try XCTUnwrap(records().first)
        XCTAssertEqual(extracted.topicID, record.id)
        XCTAssertTrue(extracted.created)
        XCTAssertNil(record.title)
        XCTAssertEqual(record.sessions.first?["directory"]?.string.map(Folder.local), sessionPath.folder)
        XCTAssertEqual(extracted.shown, WindowID(rawValue: windowID).map { .window($0) })
        let topicWindows = server.snapshot().windows.filter { $0.topicID == record.id }
        XCTAssertEqual(topicWindows.map(\.id), [windowID], "the new Session holds only the moved Window")
        XCTAssertEqual(topicWindows.first?.sessionName, "loose/" + (record.slug ?? ""))
        XCTAssertEqual(server.snapshot().windows.filter { $0.sessionName == "loose" }.count, 1, "the other Window stays")
    }

    func testNewTopicFromPaneTakesOnlyThatPaneOutOfASplitWindow() throws {
        try server.run(["new-session", "-d", "-s", "loose", "-c", sessionPath.folder.path])
        let paneID = try server.run(["split-window", "-d", "-P", "-F", "#{pane_id}", "-t", "=loose:", "-c", sessionPath.folder.path])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let source = try XCTUnwrap(server.snapshot().windows.first { $0.sessionName == "loose" })
        let extracted = try change(service().handle(TopicRequest(.extract(sessionPath: nil), target: .pane(try XCTUnwrap(PaneID(rawValue: paneID))))))
        let record = try XCTUnwrap(records().first)
        let topicWindows = server.snapshot().windows.filter { $0.topicID == record.id }
        XCTAssertEqual(topicWindows.map(\.paneCount), [1])
        XCTAssertEqual(extracted.shown, topicWindows.first.flatMap { WindowID(rawValue: $0.id) }.map { .window($0) })
        let paneWindow = try server.run(["display-message", "-p", "-t", paneID, "#{window_id}"]).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(topicWindows.map(\.id), [paneWindow])
        XCTAssertEqual(server.snapshot().windows.filter { $0.id == source.id }.map(\.paneCount), [1], "the other Pane stays in its Window")
    }

    func testMovePaneToExistingOrNewTopicKeepsItsProcessAndOtherPanes() throws {
        for existing in [false, true] {
            for split in [false, true] {
                let suffix = "\(existing)-\(split)"
                try server.run(["new-session", "-d", "-s", "source-" + suffix, "-c", sessionPath.folder.path])
                let source = try XCTUnwrap(server.snapshot().windows.first { $0.sessionName == "source-" + suffix })
                let pane: String
                if split {
                    pane = try server.run(["split-window", "-d", "-P", "-F", "#{pane_id}", "-t", source.id])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    pane = try server.run(["display-message", "-p", "-t", source.id, "#{pane_id}"])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                let process = try server.run(["display-message", "-p", "-t", pane, "#{pane_pid}"])
                let destination: TopicDestination
                var expectedTopic: String?
                var previousWindow: String?
                if existing {
                    expectedTopic = try XCTUnwrap(change(service().handle(TopicRequest(.create(title: suffix, sessionPath: sessionPath.folder.path)))).topicID)
                    previousWindow = server.snapshot().windows.first { $0.topicID == expectedTopic }?.id
                    destination = .topic(.id(expectedTopic!))
                } else {
                    destination = .newTopic(title: suffix)
                }
                try assertThrowawayServer()
                let moved = try change(service().handle(TopicRequest(.move(to: destination), target: .pane(try XCTUnwrap(PaneID(rawValue: pane))))))
                let result = server.snapshot()
                let movedPane = try XCTUnwrap(result.panes.first { $0.id == pane })
                let movedWindow = try XCTUnwrap(result.windows.first { $0.id == movedPane.windowID })
                XCTAssertEqual(moved.shown, .window(try XCTUnwrap(WindowID(rawValue: movedWindow.id))))
                XCTAssertEqual(movedWindow.topicID, expectedTopic ?? moved.topicID)
                XCTAssertEqual(movedWindow.paneCount, 1)
                XCTAssertEqual(try server.run(["display-message", "-p", "-t", pane, "#{pane_pid}"]), process)
                if split {
                    XCTAssertNotEqual(movedWindow.id, source.id)
                    XCTAssertEqual(result.windows.first { $0.id == source.id }?.paneCount, 1)
                } else {
                    XCTAssertEqual(movedWindow.id, source.id)
                }
                if let previousWindow {
                    XCTAssertTrue(result.windows.contains { $0.id == previousWindow })
                    XCTAssertEqual(result.windows.filter { $0.topicID == expectedTopic }.count, 2)
                }
            }
        }
    }

    func testExtractAcceptsATitleAndKeepsThePane() throws {
        let pane = try server.run(["display-message", "-p", "-t", "=main:", "#{pane_id}"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try assertThrowawayServer()
        let extracted = try change(service().handle(TopicRequest(.extract(sessionPath: sessionPath.folder.path, title: " Named work "),
                                                                 target: .pane(try XCTUnwrap(PaneID(rawValue: pane))))))
        XCTAssertEqual(try records().first { $0.id == extracted.topicID }?.title, "Named work")
        XCTAssertTrue(server.snapshot().panes.contains { $0.id == pane })
    }

    func testMovePaneToNewWindowStaysInItsSessionAndSetsTheTitle() throws {
        let source = try XCTUnwrap(server.snapshot().windows.first { $0.sessionName == "main" })
        let pane = try server.run(["split-window", "-d", "-P", "-F", "#{pane_id}", "-t", source.id])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let target = TopicTarget.pane(try XCTUnwrap(PaneID(rawValue: pane)))
        let moved = try change(service().handle(TopicRequest(.move(to: .newWindow(title: " Notes ")), target: target)))
        let result = server.snapshot()
        let movedPane = try XCTUnwrap(result.panes.first { $0.id == pane })
        let window = try XCTUnwrap(result.windows.first { $0.id == movedPane.windowID })
        XCTAssertEqual(window.sessionID, source.sessionID)
        XCTAssertEqual(window.name, "Notes")
        XCTAssertNotEqual(window.id, source.id)
        XCTAssertEqual(result.windows.first { $0.id == source.id }?.paneCount, 1)
        XCTAssertEqual(moved.shown, .window(try XCTUnwrap(WindowID(rawValue: window.id))))
        XCTAssertTrue(try records().isEmpty)
        let again = try change(service().handle(TopicRequest(.move(to: .newWindow(title: "Renamed")), target: target)))
        XCTAssertEqual(again.shown, moved.shown)
        XCTAssertEqual(server.snapshot().windows.count, result.windows.count)
        XCTAssertEqual(server.snapshot().windows.first { $0.id == window.id }?.name, "Renamed")
    }

    func testRemoveWindowFromTopicKeepsItsPanesAndSiblingWindowInTheTopic() throws {
        for existing in [false, true] {
            let id = try XCTUnwrap(change(service().handle(TopicRequest(.create(title: "Remove-\(existing)", sessionPath: sessionPath.folder.path)))).topicID)
            let source = try XCTUnwrap(server.snapshot().windows.first { $0.topicID == id })
            let sibling = try server.run(["new-window", "-d", "-P", "-F", "#{window_id}", "-t", source.sessionID + ":", "-c", sessionPath.folder.path])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let pane = try server.run(["split-window", "-d", "-P", "-F", "#{pane_id}", "-t", source.id])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let before = server.snapshot()
            let destination = before.windows.first { $0.topicID == nil && $0.sessionName == sessionPath.name }
            XCTAssertEqual(destination != nil, existing)
            let record = try XCTUnwrap(records().first { $0.id == id })
            try assertThrowawayServer()
            let target = TopicTarget.window(try XCTUnwrap(WindowID(rawValue: source.id)))
            let to: TopicDestination = destination.map { .session(SessionID(rawValue: $0.sessionID)!) } ?? .newSession(topic: nil)
            let removed = try change(service().handle(TopicRequest(.move(to: to), target: target)))
            let result = server.snapshot()
            let moved = try XCTUnwrap(result.windows.first { $0.id == source.id })
            XCTAssertNil(moved.topicID)
            XCTAssertEqual(moved.sessionName, sessionPath.name)
            XCTAssertNotEqual(moved.sessionID, source.sessionID)
            if let destination { XCTAssertEqual(moved.sessionID, destination.sessionID) }
            XCTAssertEqual(moved.paneCount, 2)
            XCTAssertEqual(result.panes.first { $0.id == pane }?.windowID, source.id)
            XCTAssertEqual(result.windows.first { $0.id == sibling }?.topicID, id)
            XCTAssertEqual(result.windows.first { $0.id == sibling }?.sessionID, source.sessionID)
            XCTAssertEqual(result.windows.count, before.windows.count)
            XCTAssertEqual(removed.shown, .window(try XCTUnwrap(WindowID(rawValue: source.id))))
            XCTAssertEqual(try records().first { $0.id == id }, record)
        }
    }

    /// A Topic whose Session the user took out remembers no Session: it is Empty, and Reopen does not make it again.
    private func assertEmpty(_ id: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let record = try XCTUnwrap(records().first { $0.id == id }, file: file, line: line)
        XCTAssertEqual(record.sessions, [], file: file, line: line)
        XCTAssertNil(record.settledAt, file: file, line: line)
        XCTAssertFalse(server.snapshot().windows.contains { $0.topicID == id }, file: file, line: line)
    }

    func testRemovingTheOnlySessionLeavesTheTopicEmptyAndTheSessionLive() throws {
        let id = try XCTUnwrap(change(service().handle(TopicRequest(.create(title: "Only", sessionPath: sessionPath.folder.path)))).topicID)
        let session = try XCTUnwrap(server.snapshot().windows.first { $0.topicID == id })
        try assertThrowawayServer()
        _ = try change(service().handle(TopicRequest(.removeFromTopic, target: .session(try XCTUnwrap(SessionID(rawValue: session.sessionID))))))
        try assertEmpty(id)
        XCTAssertEqual(try records().first { $0.id == id }?.title, "Only")
        XCTAssertTrue(server.snapshot().windows.contains { $0.sessionID == session.sessionID && $0.topicID == nil })
    }

    func testRemovingTheLastWindowLeavesTheTopicEmpty() throws {
        let id = try XCTUnwrap(change(service().handle(TopicRequest(.create(title: "Last window", sessionPath: sessionPath.folder.path)))).topicID)
        let window = try XCTUnwrap(server.snapshot().windows.first { $0.topicID == id })
        try assertThrowawayServer()
        _ = try change(service().handle(TopicRequest(.move(to: .newSession(topic: nil)), target: .window(try XCTUnwrap(WindowID(rawValue: window.id))))))
        try assertEmpty(id)
        XCTAssertNil(server.snapshot().windows.first { $0.id == window.id }?.topicID)
    }

    func testMovingTheOnlySessionLeavesTheSourceEmptyAndTheDestinationRemembersIt() throws {
        let source = try XCTUnwrap(change(service().handle(TopicRequest(.create(title: "From", sessionPath: sessionPath.folder.path)))).topicID)
        let destination = try XCTUnwrap(change(service().handle(TopicRequest(.create(title: "To", sessionPath: nil)))).topicID)
        let session = try XCTUnwrap(server.snapshot().windows.first { $0.topicID == source })
        try assertThrowawayServer()
        _ = try change(service().handle(TopicRequest(.move(to: .topic(.id(destination))),
                                                     target: .session(try XCTUnwrap(SessionID(rawValue: session.sessionID))))))
        try assertEmpty(source)
        XCTAssertEqual(try records().first { $0.id == destination }?.sessions.compactMap { $0["directory"]?.string }, [sessionPath.folder.path])
        XCTAssertEqual(server.snapshot().windows.first { $0.sessionID == session.sessionID }?.topicID, destination)
    }

    func testRemovingOneOfTwoSessionsForgetsItInTheSameEdit() throws {
        let id = try XCTUnwrap(change(service().handle(TopicRequest(.create(title: "Two", sessionPath: sessionPath.folder.path)))).topicID)
        _ = try change(service().handle(TopicRequest(.addSession(sessionPath: tools.folder.path, workingCopy: .directory), target: .topic(.id(id)))))
        let session = try XCTUnwrap(server.snapshot().windows.first { $0.topicID == id && $0.sessionName.hasPrefix(tools.name + "/") })
        try assertThrowawayServer()
        _ = try change(service().handle(TopicRequest(.removeFromTopic, target: .session(try XCTUnwrap(SessionID(rawValue: session.sessionID))))))
        XCTAssertEqual(try records().first { $0.id == id }?.sessions.compactMap { $0["directory"]?.string }, [sessionPath.folder.path])
    }

    func testRemoveAndKillStopsTheOnlySessionAndShowsTheEmptyTopic() throws {
        let id = try XCTUnwrap(change(service().handle(TopicRequest(.create(title: "Stop", sessionPath: sessionPath.folder.path)))).topicID)
        let session = try XCTUnwrap(server.snapshot().windows.first { $0.topicID == id })
        try assertThrowawayServer()
        let removed = try change(service().handle(TopicRequest(.removeAndKill(worktrees: []),
                                                               target: .session(try XCTUnwrap(SessionID(rawValue: session.sessionID))))))
        try assertEmpty(id)
        XCTAssertFalse(server.snapshot().windows.contains { $0.sessionID == session.sessionID })
        XCTAssertEqual(removed.shown, .emptyTopic(id: id))
    }

    func testRemoveAndKillOfOneOfTwoSessionsShowsTheOtherSession() throws {
        let id = try XCTUnwrap(change(service().handle(TopicRequest(.create(title: "Stop one", sessionPath: sessionPath.folder.path)))).topicID)
        _ = try change(service().handle(TopicRequest(.addSession(sessionPath: tools.folder.path, workingCopy: .directory), target: .topic(.id(id)))))
        let windows = server.snapshot().windows.filter { $0.topicID == id }
        let killed = try XCTUnwrap(windows.first { $0.sessionName.hasPrefix(tools.name + "/") })
        let other = try XCTUnwrap(windows.first { $0.sessionID != killed.sessionID })
        try assertThrowawayServer()
        let removed = try change(service().handle(TopicRequest(.removeAndKill(worktrees: []),
                                                               target: .session(try XCTUnwrap(SessionID(rawValue: killed.sessionID))))))
        XCTAssertFalse(server.snapshot().windows.contains { $0.sessionID == killed.sessionID })
        XCTAssertEqual(try records().first { $0.id == id }?.sessions.compactMap { $0["directory"]?.string }, [sessionPath.folder.path])
        XCTAssertEqual(removed.shown, .window(try XCTUnwrap(WindowID(rawValue: other.id))))
    }

    func testRemoveAndKillRemovesTheCleanWorktreeOnlyWhenTheRequestNamesIt() throws {
        let app = try repository()
        let service = TopicService(paths: paths, server: server, sessionPaths: [sessionPath, app])
        for remove in [false, true] {
            let title = remove ? "Remove tree" : "Keep tree"
            let session = try addNewWorktree(of: app, base: nil, title: title)
            let id = try XCTUnwrap(records().first { $0.title == title }?.id)
            let worktree = try XCTUnwrap(session["worktree_path"]?.string)
            let live = try XCTUnwrap(server.snapshot().windows.first { $0.topicID == id })
            try assertThrowawayServer()
            _ = try change(service.handle(TopicRequest(.removeAndKill(worktrees: remove ? [worktree] : []),
                                                       target: .session(try XCTUnwrap(SessionID(rawValue: live.sessionID))))))
            try assertEmpty(id)
            XCTAssertEqual(FileManager.default.fileExists(atPath: worktree), !remove)
            XCTAssertNoThrow(try git(["rev-parse", "--verify", "refs/heads/" + (session["branch"]?.string ?? "")], in: app.folder.path))
        }
    }

    @discardableResult
    private func git(_ arguments: [String], in directory: String) throws -> String {
        try Shell.run("/usr/bin/git", ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgSign=false"] + arguments, directory: directory)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A plain repository `work/app` whose main branch has the commits `first`, tagged `v1`, and `second`.
    private func repository() throws -> SessionPath {
        let path = root.appendingPathComponent("work/app").path
        try git(["init", "-q", "-b", "main", path], in: root.path)
        try git(["commit", "-q", "--allow-empty", "-m", "first"], in: path)
        try git(["-c", "tag.gpgSign=false", "tag", "-a", "-m", "v1", "v1"], in: path)
        try git(["commit", "-q", "--allow-empty", "-m", "second"], in: path)
        return SessionPath(path: path, name: "app", layout: RepositoryLayout.detect(at: path))
    }

    /// Adds `app` to a new Topic `title` with a new Worktree from the main checkout. Returns the remembered Session.
    private func addNewWorktree(of app: SessionPath, base: String?, title: String) throws -> JSONValue {
        let service = TopicService(paths: paths, server: server, sessionPaths: [sessionPath, app])
        let id = try XCTUnwrap(change(service.handle(TopicRequest(.create(title: title, sessionPath: nil)))).topicID)
        _ = try change(service.handle(TopicRequest(.addSession(sessionPath: app.folder.path, workingCopy: .newWorktree(from: app.folder.path, base: base)),
                                                   target: .topic(.id(id)))))
        return try XCTUnwrap(records().first { $0.id == id }?.sessions.first)
    }

    func testANewWorktreeStartsAtTheBaseHeadAndTheRecordKeepsThatCommit() throws {
        let app = try repository()
        let session = try addNewWorktree(of: app, base: nil, title: "Ship")
        let head = try git(["rev-parse", "HEAD"], in: app.folder.path)
        let worktree = paths.worktrees.appendingPathComponent("app/ship").path
        XCTAssertEqual(session["base"], .string(head))
        XCTAssertEqual(session["worktree_path"], .string(worktree))
        XCTAssertEqual(session["branch"], .string("ship"))
        XCTAssertEqual(session["worktree_created"], .bool(true))
        XCTAssertEqual(try git(["rev-parse", "HEAD"], in: worktree), head)
        XCTAssertEqual(try git(["symbolic-ref", "--short", "HEAD"], in: worktree), "ship")
    }

    func testANewWorktreeFromABaseRefStartsAtTheCommitThatTheRefNames() throws {
        let app = try repository()
        let session = try addNewWorktree(of: app, base: "v1", title: "Hotfix")
        let tagged = try git(["rev-parse", "v1^{commit}"], in: app.folder.path)
        XCTAssertNotEqual(tagged, try git(["rev-parse", "HEAD"], in: app.folder.path))
        XCTAssertEqual(session["base"], .string(tagged))
        XCTAssertEqual(try git(["rev-parse", "HEAD"], in: paths.worktrees.appendingPathComponent("app/hotfix").path), tagged)
    }

    func testABaseRefThatNamesNoCommitFailsAndMakesNoWorktree() throws {
        let app = try repository()
        let service = TopicService(paths: paths, server: server, sessionPaths: [sessionPath, app])
        let id = try XCTUnwrap(change(service.handle(TopicRequest(.create(title: "Ship", sessionPath: nil)))).topicID)
        let failed = try failure(service.handle(TopicRequest(.addSession(sessionPath: app.folder.path, workingCopy: .newWorktree(from: app.folder.path, base: "nope")),
                                                             target: .topic(.id(id)))))
        XCTAssertEqual(failed, TopicFailure(kind: .gitFailed, phase: .nothingChanged, message: "No commit matches nope in \(app.folder.path)."))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.worktrees.appendingPathComponent("app/ship").path))
        XCTAssertEqual(try records().first { $0.id == id }?.sessions, [])
    }

    /// A Settled Topic whose new Worktree `app/ship` and branch `ship` are both gone, and whose SessionPath HEAD moved on.
    private func settledWithGoneWorktree(of app: SessionPath) throws -> (id: String, base: String) {
        let session = try addNewWorktree(of: app, base: nil, title: "Ship")
        let id = try XCTUnwrap(records().first?.id)
        let base = try XCTUnwrap(session["base"]?.string)
        let service = TopicService(paths: paths, server: server, sessionPaths: [sessionPath, app])
        _ = try change(service.handle(TopicRequest(.settle(choices: [], outcome: "Paused"), target: .topic(.id(id)))))
        try git(["worktree", "remove", "--force", paths.worktrees.appendingPathComponent("app/ship").path], in: app.folder.path)
        try git(["branch", "-D", "ship"], in: app.folder.path)
        try git(["commit", "-q", "--allow-empty", "-m", "third"], in: app.folder.path)
        XCTAssertNotEqual(try git(["rev-parse", "HEAD"], in: app.folder.path), base)
        return (id, base)
    }

    func testReopenStartsAGoneBranchAgainAtTheRecordedBase() throws {
        let app = try repository()
        let (id, base) = try settledWithGoneWorktree(of: app)
        let service = TopicService(paths: paths, server: server, sessionPaths: [sessionPath, app])
        _ = try change(service.handle(TopicRequest(.reopen, target: .topic(.id(id)))))
        let worktree = paths.worktrees.appendingPathComponent("app/ship").path
        XCTAssertEqual(try git(["rev-parse", "ship"], in: app.folder.path), base, "the new branch starts at the recorded base, not at HEAD")
        XCTAssertEqual(try git(["symbolic-ref", "--short", "HEAD"], in: worktree), "ship")
        let record = try XCTUnwrap(records().first { $0.id == id })
        XCTAssertNil(record.settledAt)
        XCTAssertEqual(record.sessions.first?["base"], .string(base))
    }

    func testReopenFailsAndChangesNothingWhenTheRecordedBaseIsGone() throws {
        let app = try repository()
        let (id, base) = try settledWithGoneWorktree(of: app)
        let file = paths.topics.appendingPathComponent(id + ".json")
        let missing = String(repeating: "0", count: 40)
        try String(contentsOf: file, encoding: .utf8).replacingOccurrences(of: base, with: missing).write(to: file, atomically: true, encoding: .utf8)
        let before = try records()
        let service = TopicService(paths: paths, server: server, sessionPaths: [sessionPath, app])
        let worktree = paths.worktrees.appendingPathComponent("app/ship").path
        let failed = try failure(service.handle(TopicRequest(.reopen, target: .topic(.id(id)))))
        XCTAssertEqual(failed, TopicFailure(kind: .gitFailed, phase: .nothingChanged, message: "The Worktree \(worktree) and its branch are gone, "
                       + "and the repository does not have their base commit \(missing). Muxify did not make the Worktree again."))
        XCTAssertEqual(try records(), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree))
        XCTAssertEqual(try git(["branch", "--list", "ship"], in: app.folder.path), "")
        XCTAssertEqual(sessions(of: id), [])
    }

    func testSettleRefusesToRemoveAWorktreeWithUncommittedWorkAndChangesNothing() throws {
        let app = try repository()
        _ = try addNewWorktree(of: app, base: nil, title: "Ship")
        let id = try XCTUnwrap(records().first?.id)
        let worktree = paths.worktrees.appendingPathComponent("app/ship").path
        try "draft".write(toFile: worktree + "/notes.txt", atomically: true, encoding: .utf8)
        let service = TopicService(paths: paths, server: server, sessionPaths: [sessionPath, app])
        var choices = try service.settleChoices(for: .topic(.id(id))).get()
        XCTAssertEqual(choices.map(\.worktree?.path), [worktree], "Settle offers to remove the merged Worktree")
        choices[0].removeWorktree = true
        choices[0].disposition = .kill
        let before = try records()
        let failed = try failure(service.handle(TopicRequest(.settle(choices: choices, outcome: "Done"), target: .topic(.id(id)))))
        XCTAssertEqual(failed, TopicFailure(kind: .gitFailed, phase: .nothingChanged,
                                            message: "The Worktree \(worktree) has uncommitted changes. Commit or remove them, or keep the Worktree."))
        XCTAssertEqual(try records(), before, "the Topic is not Settled")
        XCTAssertEqual(sessions(of: id), ["app/ship"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree + "/notes.txt"))
    }

    func testSettleRemovesAMergedWorktreeInTheServicesOwnWorktreesFolder() throws {
        let app = try repository()
        _ = try addNewWorktree(of: app, base: nil, title: "Ship")
        let id = try XCTUnwrap(records().first?.id)
        let worktree = paths.worktrees.appendingPathComponent("app/ship").path
        let service = TopicService(paths: paths, server: server, sessionPaths: [sessionPath, app])
        var choices = try service.settleChoices(for: .topic(.id(id))).get()
        choices[0].removeWorktree = true
        choices[0].disposition = .kill
        guard case .changed = service.handle(TopicRequest(.settle(choices: choices, outcome: "Done"), target: .topic(.id(id)))) else {
            return XCTFail("Settle failed")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree), "Settle kept the Worktree")
    }

    /// Settle remembers each Window's current path. Until a new shell has started, tmux reports its own folder.
    private func waitForPath(_ path: String, of window: String) throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let current = try server.run(["display-message", "-p", "-t", window, "#{pane_current_path}"])
            if (current.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).resolvingSymlinksInPath == path { return }
            usleep(20_000)
        }
        XCTFail("\(window) is not in \(path)")
    }

    /// A process that holds an exclusive flock on `url` until it is killed.
    private func hold(_ url: URL) throws -> Process {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        holder.arguments = ["-e", #"use Fcntl ":flock"; open(F, ">>", $ARGV[0]) or die; flock(F, LOCK_EX) or die; $| = 1; print "held\n"; sleep 30"#, url.path]
        let output = Pipe()
        holder.standardOutput = output
        try holder.run()
        XCTAssertEqual(String(data: output.fileHandleForReading.availableData, encoding: .utf8), "held\n")
        return holder
    }
}

private final class Responses: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TopicResponse] = []
    var all: [TopicResponse] { lock.lock(); defer { lock.unlock() }; return values }
    func append(_ response: TopicResponse) { lock.lock(); values.append(response); lock.unlock() }
}
