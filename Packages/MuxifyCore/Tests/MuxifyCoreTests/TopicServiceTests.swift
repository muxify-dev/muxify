import XCTest
@testable import MuxifyCore
import MuxifyTestSupport

/// The service against a throwaway tmux server and state folder in the test's own run directory. The tests of one class
/// run in order, in one process, so the tests are in one class for each area, and xcodebuild runs the classes side by side.
class TopicServiceTestCase: XCTestCase {
    fileprivate var root: URL!
    fileprivate var paths: MuxifyPaths!
    fileprivate var server: TmuxServer!
    fileprivate var sessionPath: SessionPath!
    fileprivate var tools: SessionPath!

    override func setUpWithError() throws {
        _ = try requireTmux()
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

    fileprivate func service(tags: [String] = ["backend", "release"]) -> EnvironmentService {
        var topics = Config.Topics()
        topics.tags = ConfigTags(tags.map { TagDefinition(tag: Tag(name: $0)!) })
        return EnvironmentService(paths: paths, server: server, sessionPaths: [sessionPath, tools], topics: topics)
    }

    fileprivate func records() throws -> [TopicRecord] { try TopicStore(paths: paths).read().records }

    fileprivate func change(_ response: EnvironmentResponse, file: StaticString = #filePath, line: UInt = #line) throws -> TopicChange {
        guard case .changed(let change) = response else { XCTFail("\(response)", file: file, line: line); throw CancellationError() }
        return change
    }

    fileprivate func failure(_ response: EnvironmentResponse, file: StaticString = #filePath, line: UInt = #line) throws -> TopicFailure {
        guard case .failed(let failure) = response else { XCTFail("\(response)", file: file, line: line); throw CancellationError() }
        return failure
    }

    /// A Topic with one Session at `path`, as the palette's New Topic makes it: an Empty Topic, then Add a Session.
    fileprivate func topicWithSession(_ title: String, at path: String, tags: [Tag]? = nil, using service: EnvironmentService) throws -> String {
        let id = try XCTUnwrap(change(service.handle(EnvironmentRequest(.create(title: title, tags: tags)))).topicID)
        _ = try change(service.handle(EnvironmentRequest(.addSession(sessionPath: path, workingCopy: .directory), target: .topic(.id(id)))))
        return id
    }

    /// A Topic that is not a Guest, for a test that needs a list of regular cards: New Topic makes a Guest, and Bench
    /// takes it to the first free place, else to the top of the Bench.
    @discardableResult
    fileprivate func regularTopic(_ title: String, using service: EnvironmentService) throws -> String {
        let id = try XCTUnwrap(change(service.handle(EnvironmentRequest(.create(title: title)))).topicID)
        _ = try change(service.handle(EnvironmentRequest(.benchTopic, target: .topic(.id(id)))))
        return id
    }

    fileprivate func assertThrowawayServer() throws {
        let socket = try server.run(["display-message", "-p", "#{socket_path}"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard socket.hasPrefix(root.path + "/") else { throw CancellationError() }
    }

    /// The Topics list as the app orders it: Topic ids, `lock:` with the Session name for a Locked Session, and `_` for
    /// an Open Place.
    fileprivate func topicList() throws -> [String] {
        let windows = try server.snapshot().windows
        let openPlaces = try TopicStore(paths: paths).read().openPlaces
        return TopicOrder.sorted(TopicListEntry.all(records: try records(), windows: windows, openPlaces: openPlaces)).map { entry in
            switch entry {
            case .topic(let record): return record.title ?? record.id
            case .lock(let lock): return "lock:" + (windows.first { $0.sessionID == lock.sessionID }?.sessionName ?? "?")
            case .openPlace: return "_"
            }
        }
    }

    /// A Topic with a Session in game and one in tools.
    fileprivate func twoSessionPathTopic(_ title: String) throws -> String {
        let id = try topicWithSession(title, at: sessionPath.folder.path, using: service())
        _ = try change(service().handle(EnvironmentRequest(.addSession(sessionPath: tools.folder.path, workingCopy: .directory), target: .topic(.id(id)))))
        return id
    }

    fileprivate func sessions(of topic: String) throws -> [String] {
        Set(try server.snapshot().windows.filter { $0.topicID == topic }.map(\.sessionName)).sorted()
    }

    /// A Topic whose Session the user took out remembers no Session: it is Empty, and Reopen does not make it again.
    fileprivate func assertEmpty(_ id: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let record = try XCTUnwrap(records().first { $0.id == id }, file: file, line: line)
        XCTAssertEqual(record.sessions, [], file: file, line: line)
        XCTAssertNil(record.settledAt, file: file, line: line)
        XCTAssertFalse(try server.snapshot().windows.contains { $0.topicID == id }, file: file, line: line)
    }
}

/// New Topic, Sessions added to it, Tags, Notes, Unread, the list, failures, Settle, Forget and Reopen.
final class TopicServiceTests: TopicServiceTestCase {
    /// Each Window's place and Panes, without its name, which tmux changes by itself once its shell starts.
    private func layout() throws -> [String] {
        try server.snapshot().windows.map { "\($0.id) \($0.sessionID) \($0.sessionName) \($0.topicID ?? "-") \($0.activePaneID) \($0.paneCount)" }
    }

    func testConfirmationRejectsChangedSessionsBeforeAnyEdits() throws {
        for dormant in [false, true] {
            let id = dormant ? try XCTUnwrap(change(service().handle(EnvironmentRequest(.create(title: "Dormant")))).topicID)
                             : try topicWithSession("Live", at: sessionPath.folder.path, using: service())
            var reviewed = try service().settleChoices(for: .topic(.id(id))).get()
            for index in reviewed.indices { reviewed[index].disposition = .keep }
            _ = try change(service().handle(EnvironmentRequest(.addSession(sessionPath: tools.folder.path, workingCopy: .directory), target: .topic(.id(id)))))
            let before = try records()
            let windows = try layout()
            for command in [EnvironmentCommand.settle(choices: reviewed), .forget(choices: reviewed, worktrees: [])] {
                try assertThrowawayServer()
                let failed = try failure(service().handle(EnvironmentRequest(command, target: .topic(.id(id)), expectedSessionIDs: reviewed.map(\.id))))
                XCTAssertEqual(failed.kind, .topicMembershipChanged)
                XCTAssertEqual(failed.phase, .nothingChanged)
                XCTAssertEqual(try records(), before)
                XCTAssertEqual(try layout(), windows)
            }
        }
    }

    func testConfirmationRejectsNewWindowsAndPanesInReviewedSessions() throws {
        for addWindow in [false, true] {
            let id = try topicWithSession("Changed impact", at: sessionPath.folder.path, using: service())
            let choices = try service().settleChoices(for: .topic(.id(id))).get()
            let session = try XCTUnwrap(choices.first)
            let window = try XCTUnwrap(try server.snapshot().windows.first { $0.sessionID == session.id })
            if addWindow {
                _ = try server.run(["new-window", "-d", "-t", session.id + ":"])
            } else {
                _ = try server.run(["split-window", "-d", "-t", window.id])
            }
            let before = try records()
            let windows = try layout()
            for command in [EnvironmentCommand.settle(choices: choices), .forget(choices: choices, worktrees: [])] {
                try assertThrowawayServer()
                let failed = try failure(service().handle(EnvironmentRequest(command, target: .topic(.id(id)), expectedSessionIDs: choices.map(\.id))))
                XCTAssertEqual(failed.kind, .topicMembershipChanged)
                XCTAssertEqual(failed.phase, .nothingChanged)
                XCTAssertEqual(try records(), before)
                XCTAssertEqual(try layout(), windows)
            }
            var refreshed = try service().settleChoices(for: .topic(.id(id))).get()
            for index in refreshed.indices { refreshed[index].disposition = .kill }
            _ = try change(service().handle(EnvironmentRequest(.settle(choices: refreshed),
                                                        target: .topic(.id(id)), expectedSessionIDs: refreshed.map(\.id))))
            XCTAssertFalse(try server.snapshot().windows.contains { $0.sessionID == session.id })
        }
    }

    func testConfirmationAcceptsTheSameSessionSet() throws {
        for forget in [false, true] {
            let id = try topicWithSession(forget ? "Forget reviewed" : "Settle reviewed", at: sessionPath.folder.path, using: service())
            _ = try change(service().handle(EnvironmentRequest(.addSession(sessionPath: tools.folder.path, workingCopy: .directory), target: .topic(.id(id)))))
            var choices = try service().settleChoices(for: .topic(.id(id))).get()
            for index in choices.indices { choices[index].disposition = .keep }
            let command: EnvironmentCommand = forget ? .forget(choices: choices, worktrees: []) : .settle(choices: choices)
            try assertThrowawayServer()
            _ = try change(service().handle(EnvironmentRequest(command, target: .topic(.id(id)), expectedSessionIDs: choices.reversed().map(\.id))))
            let windows = try server.snapshot().windows
            for choice in choices {
                let kept = try XCTUnwrap(windows.first { $0.sessionID == choice.id })
                XCTAssertNil(kept.topicID)
            }
            if forget { XCTAssertFalse(try records().contains { $0.id == id }) }
            else { XCTAssertNotNil(try records().first { $0.id == id }?.settledAt) }
        }
    }

    func testForgetKillsOrKeepsLiveSessionsAndCannotReopenTheTopic() throws {
        let id = try topicWithSession("Forget", at: sessionPath.folder.path, using: service())
        _ = try change(service().handle(EnvironmentRequest(.addSession(sessionPath: tools.folder.path, workingCopy: .directory), target: .topic(.id(id)))))
        var choices = try service().forgetChoices(for: .topic(.id(id))).get().sessions
        choices[0].disposition = .kill
        choices[1].disposition = .keep
        try assertThrowawayServer()
        let forgotten = try change(service().handle(EnvironmentRequest(.forget(choices: choices, worktrees: []), target: .topic(.id(id)))))
        XCTAssertEqual(forgotten.topicID, id)
        XCTAssertFalse(forgotten.created)
        XCTAssertFalse(try records().contains { $0.id == id })
        XCTAssertFalse(try server.snapshot().windows.contains { $0.sessionID == choices[0].id })
        let kept = try XCTUnwrap(try server.snapshot().windows.first { $0.sessionID == choices[1].id })
        XCTAssertNil(kept.topicID)
        XCTAssertEqual(try failure(service().handle(EnvironmentRequest(.reopen, target: .topic(.id(id))))).kind, .topicUnavailable)
    }

    func testForgetWithNoChoicesKeepsEveryLiveSession() throws {
        let id = try topicWithSession("Forget by URL", at: sessionPath.folder.path, using: service())
        let session = try XCTUnwrap(try server.snapshot().windows.first { $0.topicID == id }?.sessionID)
        try assertThrowawayServer()
        _ = try change(service().handle(EnvironmentRequest(.forget(choices: [], worktrees: []), target: .topic(.id(id)))))
        let kept = try XCTUnwrap(try server.snapshot().windows.first { $0.sessionID == session }, "a request without choices stops nothing")
        XCTAssertNil(kept.topicID)
    }

    func testForgetRemovesDormantAndSettledRecords() throws {
        for state in ["dormant", "settled"] {
            var record = TopicRecord(id: state, title: state)
            if state == "settled" { record.settledAt = "2026-10-11T00:00:00Z" }
            try TopicStore(paths: paths).write { try $0.create(record) }
            try assertThrowawayServer()
            _ = try change(service().handle(EnvironmentRequest(.forget(choices: [], worktrees: []), target: .topic(.id(state)))))
            XCTAssertNil(try paths.storedTopicRecord(state))
        }
    }

    func testCreateFromAPaneMakesAnEmptyTopicAndLeavesThePane() throws {
        let pane = try XCTUnwrap(PaneID(rawValue: try server.run(["display-message", "-p", "-t", "=main:", "#{pane_id}"])
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        let windows = try layout()
        let created = try change(service().handle(EnvironmentRequest(.create(title: "Fix reward"), target: .pane(pane), caller: .pane(pane))))
        let record = try XCTUnwrap(records().first)
        XCTAssertEqual(created.topicID, record.id)
        XCTAssertTrue(created.created)
        XCTAssertEqual(record.title, "Fix reward")
        XCTAssertEqual(record.sessions, [])
        XCTAssertEqual(created.shown, .emptyTopic(.topic(record.id)))
        XCTAssertEqual(try layout(), windows, "an Empty Topic starts and moves nothing in tmux")
    }

    func testCreateWithNoSessionPathAndNoTargetMakesATopicWithNoSession() throws {
        let sessions = try server.snapshot().windows.count
        let created = try change(service().handle(EnvironmentRequest(.create(title: "  Plan the week "))))
        let record = try XCTUnwrap(records().first)
        XCTAssertEqual(record.title, "Plan the week")
        XCTAssertEqual(created.shown, .emptyTopic(.topic(record.id)))
        XCTAssertEqual(try server.snapshot().windows.count, sessions)
    }

    /// The state that a run leaves when it ends after its record write: the Topic and a `started` row.
    func testCreateWithARequestGivesTheTopicTheRequestIDAndASecondRunFindsThatTopic() throws {
        let id = try XCTUnwrap(RequestID("3f2b8c1e-7a4d-4e9b-9c0a-5d6e7f8a9b0c"))
        let pending = PendingRequest(id: id, verb: "topic new", words: ["Fix login"], callerPane: nil, workingDirectory: "/")
        let requested = EnvironmentService(paths: paths, server: server, request: pending)
        let first = try change(requested.handle(EnvironmentRequest(.create(title: "Fix login"))))
        XCTAssertEqual(first.topicID, id.rawValue)
        XCTAssertEqual(try RequestLedger(paths: paths).lookup(pending), .resume, "the record write starts the Request")

        let second = try change(EnvironmentService(paths: paths, server: server, request: pending).handle(EnvironmentRequest(.create(title: "Fix login"))))
        XCTAssertEqual(second, first, "the second run gives the answer of the first")
        XCTAssertEqual(try records().map(\.slug), ["fix-login"], "no second Topic and no fix-login-2")

        _ = try change(service().handle(EnvironmentRequest(.create(title: "Fix login"))))
        XCTAssertEqual(try records().compactMap(\.slug).sorted(), ["fix-login", "fix-login-2"], "without a Request, each run makes a Topic")
    }

    func testAddSessionWithAChosenNameFindsTheSessionAndAddsNoSecondOne() throws {
        let id = try XCTUnwrap(change(service().handle(EnvironmentRequest(.create(title: "Ship")))).topicID)
        let add = EnvironmentRequest(.addSession(sessionPath: sessionPath.folder.path, workingCopy: .directory, chosenName: "api"), target: .topic(.id(id)))
        let first = try change(service().handle(add))
        XCTAssertEqual(first.sessionName, "api/ship")
        let entry = try XCTUnwrap(records().first?.sessions.first)

        let again = try change(service().handle(add))
        XCTAssertEqual(again.session, first.session, "the Session is found")
        XCTAssertEqual(again.sessionName, "api/ship")
        XCTAssertEqual(try records().first?.sessions, [entry], "the record gains no second entry")
        XCTAssertEqual(try server.snapshot().windows.filter { $0.topicID == id }.count, 1)

        // A run that ended after its record write and before tmux made the Session.
        try server.run(["kill-session", "-t", "=api/ship"])
        let remade = try change(service().handle(add))
        XCTAssertEqual(remade.sessionName, "api/ship")
        XCTAssertEqual(try records().first?.sessions, [entry])
        let window = try XCTUnwrap(server.snapshot().windows.first { $0.sessionName == "api/ship" })
        XCTAssertEqual(window.topicID, id)
        XCTAssertEqual(window.sessionRecordID, entry["id"]?.string, "the Session that tmux makes is the one that the record has")
    }

    func testAddSessionRefusesAChosenNameThatASessionOutsideTheTopicHas() throws {
        let id = try XCTUnwrap(change(service().handle(EnvironmentRequest(.create(title: "Ship")))).topicID)
        try server.run(["new-session", "-d", "-s", "api/ship", "-c", root.path])
        let refused = try failure(service().handle(EnvironmentRequest(
            .addSession(sessionPath: sessionPath.folder.path, workingCopy: .directory, chosenName: "api"), target: .topic(.id(id)))))
        XCTAssertEqual(refused.kind, .duplicateSession)
        XCTAssertEqual(refused.phase, .nothingChanged)
        XCTAssertEqual(try records().first?.sessions, [])
    }

    func testATagChangeDuringASettleOfTheSameTopicKeepsBothWrites() throws {
        let backend = Tag(name: "backend")!
        let id = try topicWithSession("Ship", at: sessionPath.folder.path, using: service())
        let choices = try service().settleChoices(for: .topic(.id(id))).get()
        let tagger = service()
        let tagged = Responses()
        // The Settle has read the records; the Tag change commits before the Settle plans from that read and writes.
        let settler = EnvironmentService(paths: paths, server: Interleaving(server: server) {
            tagged.append(tagger.handle(EnvironmentRequest(.tags(.add([backend])), target: .topic(.id(id)))))
        }, sessionPaths: [sessionPath, tools])
        _ = try change(settler.handle(EnvironmentRequest(.settle(choices: choices), target: .topic(.id(id)))))
        XCTAssertEqual(tagged.all.count, 1, "the Tag change ran inside the Settle")
        for response in tagged.all { _ = try change(response) }
        let record = try XCTUnwrap(records().first { $0.id == id })
        XCTAssertNotNil(record.settledAt, "the Settle's write landed")
        XCTAssertEqual(record.tags, [backend], "the Tag change's write landed")
    }

    func testTagsChangeOnlyTheTagsOfTheTargetsOpenTopicAndANewTopicGetsItsTags() throws {
        let backend = Tag(name: "backend")!, release = Tag(name: "release")!
        let id = try XCTUnwrap(change(service().handle(EnvironmentRequest(.create(title: "Fix", tags: [release])))).topicID)
        func current() throws -> TopicRecord { try XCTUnwrap(records().first { $0.id == id }) }
        XCTAssertEqual(try current().tags, [release])
        let before = try current()
        XCTAssertEqual(try change(service().handle(EnvironmentRequest(.tags(.add([backend])), target: .topic(.named("Fix"))))).topicID, id)
        XCTAssertEqual(try current().tags, [backend, release])
        _ = try change(service().handle(EnvironmentRequest(.tags(.remove([release])), target: .topic(.id(id)))))
        var expected = before
        expected.tags = [backend]
        XCTAssertEqual(try current(), expected, "a Tag change changes nothing else in the record")
        _ = try change(service().handle(EnvironmentRequest(.tags(.set([])), target: .topic(.id(id)))))
        XCTAssertEqual(try current().tags, [])

        let withSession = try topicWithSession("Live", at: sessionPath.folder.path, tags: [backend], using: service())
        XCTAssertEqual(try records().first { $0.id == withSession }?.tags, [backend], "Add a Session keeps the Tags of the Topic")

        let missing = try failure(service().handle(EnvironmentRequest(.tags(.add([backend])), target: .topic(.id("nope")))))
        XCTAssertEqual(missing.kind, .topicUnavailable)
        XCTAssertEqual(missing.phase, .nothingChanged)
        let noTarget = try failure(service().handle(EnvironmentRequest(.tags(.add([backend])))))
        XCTAssertEqual(noTarget.kind, .noTarget)
    }

    func testATopicNoteChangesOnlyTheNoteOfTheTargetsOpenTopicAndASettledTopicRefusesIt() throws {
        let id = try XCTUnwrap(change(service().handle(EnvironmentRequest(.create(title: "Fix")))).topicID)
        func current() throws -> TopicRecord { try XCTUnwrap(records().first { $0.id == id }) }
        let before = try current()
        XCTAssertEqual(try change(service().handle(EnvironmentRequest(.note("  Waiting on Ana's review\n"), target: .topic(.named("Fix"))))).topicID, id)
        var expected = before
        expected.note = "Waiting on Ana's review"
        XCTAssertEqual(try current(), expected, "a Note change changes nothing else in the record")

        _ = try change(service().handle(EnvironmentRequest(.settle(choices: []), target: .topic(.id(id)))))
        let settled = try failure(service().handle(EnvironmentRequest(.note("Later"), target: .topic(.id(id)))))
        XCTAssertEqual(settled.kind, .topicUnavailable)
        XCTAssertEqual(settled.phase, .nothingChanged)
        XCTAssertNil(try current().note)
        XCTAssertEqual(try failure(service().handle(EnvironmentRequest(.note("x")))).kind, .noTarget)
    }

    func testOnlyTheTagsTheConfigDefinesCanBeAddedAndATagItNoLongerDefinesCanStayOrGo() throws {
        let backend = Tag(name: "backend")!, release = Tag(name: "release")!, old = Tag(name: "old")!
        let id = try XCTUnwrap(change(service().handle(EnvironmentRequest(.create(title: "Fix", tags: [release])))).topicID)
        func current() throws -> Set<Tag> { try XCTUnwrap(records().first { $0.id == id }).tags }
        try TopicStore(paths: paths).write { try $0.changeTags(of: id, .add([old])) }

        let undefined = try failure(service().handle(EnvironmentRequest(.tags(.add([backend, Tag(name: "bazel")!])), target: .topic(.id(id)))))
        XCTAssertEqual(undefined.kind, .tagUndefined)
        XCTAssertEqual(undefined.phase, .nothingChanged)
        XCTAssertTrue(undefined.message.contains("#bazel") && undefined.message.contains("topics.tags"), undefined.message)
        XCTAssertEqual(try current(), [old, release], "a refused change writes nothing, also not its defined Tags")

        _ = try change(service().handle(EnvironmentRequest(.tags(.set([old, backend])), target: .topic(.id(id)))))
        XCTAssertEqual(try current(), [old, backend], "a Tag the Config no longer defines stays when the change keeps it")
        _ = try change(service().handle(EnvironmentRequest(.tags(.remove([old])), target: .topic(.id(id)))))
        XCTAssertEqual(try current(), [backend])
        XCTAssertEqual(try failure(service().handle(EnvironmentRequest(.tags(.add([old])), target: .topic(.id(id))))).kind, .tagUndefined,
                       "nothing adds a Tag the Config no longer defines again")

        let off = try failure(service(tags: []).handle(EnvironmentRequest(.create(title: "Untagged", tags: [backend]))))
        XCTAssertEqual(off.kind, .tagUndefined, "with Tags off, no Tag can be added")
        XCTAssertFalse(try records().contains { $0.title == "Untagged" }, "a refused New Topic writes no record")
    }

    func testForgetSettledCountsTheDaysFromTheTimeTheUserReviewed() throws {
        let calendar = Calendar.autoupdatingCurrent
        let now = Date()
        let asOf = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: now))
        try TopicStore(paths: paths).write { transaction in
            for (id, days) in [("fifteen", 15), ("sixteen", 16)] {
                var record = TopicRecord(id: id, title: id)
                record.settledAt = ISO8601DateFormatter().string(from: try XCTUnwrap(calendar.date(byAdding: .day, value: -days, to: now)))
                try transaction.create(record)
            }
        }
        let response = service().handle(EnvironmentRequest(.forgetSettled(olderThan: 14, asOf: asOf)))
        guard case .topics(let forgotten) = response else { return XCTFail("\(response)") }
        XCTAssertEqual(forgotten.map(\.id), ["sixteen"], "Settled 15 days before asOf: forgotten")
        XCTAssertEqual(try records().map(\.id), ["fifteen"], "Settled 15 days before now but 14 before asOf: kept")
    }

    func testAPathThroughASymlinkFindsTheSessionPathThatTheConfigNames() throws {
        // The Config names the SessionPaths through dev, a symlink to work, as ~/Dev can be; the CLI gives the real path.
        let dev = root.appendingPathComponent("dev")
        try FileManager.default.createSymbolicLink(atPath: dev.path, withDestinationPath: "work")
        let game = SessionPath(path: dev.appendingPathComponent("game").path, name: "game")
        let tools = SessionPath(path: dev.appendingPathComponent("tools").path, name: "tools")
        let service = EnvironmentService(paths: paths, server: server, sessionPaths: [game, tools])
        let real = { (sessionPath: SessionPath) in String(cString: realpath(sessionPath.folder.path, nil)) }
        let id = try topicWithSession("Ship", at: real(game), using: service)
        _ = try change(service.handle(EnvironmentRequest(.addSession(sessionPath: real(tools), workingCopy: .directory), target: .topic(.id(id)))))
        let record = try XCTUnwrap(records().first { $0.id == id })
        XCTAssertEqual(record.sessions.first?["directory"]?.string, game.folder.path, "the record keeps the path that the Config wrote")
        XCTAssertEqual(record.sessions.map { $0["directory"]?.string }, [game.folder.path, tools.folder.path])
    }

    func testAFailureSaysHowFarTheRequestGot() throws {
        let elsewhere = try XCTUnwrap(change(service().handle(EnvironmentRequest(.create(title: "Elsewhere")))).topicID)
        let unknown = try failure(service().handle(EnvironmentRequest(.addSession(sessionPath: "/nowhere", workingCopy: .directory),
                                                                      target: .topic(.id(elsewhere)))))
        XCTAssertEqual(unknown.kind, .sessionPathUnavailable)
        XCTAssertEqual(unknown.phase, .nothingChanged)
        XCTAssertEqual(try failure(service().handle(EnvironmentRequest(.rename(title: "Y")))).kind, .noTarget)
        _ = try change(service().handle(EnvironmentRequest(.create(title: "Same"))))
        _ = try change(service().handle(EnvironmentRequest(.create(title: "Same"))))
        XCTAssertEqual(try failure(service().handle(EnvironmentRequest(.rename(title: "Z"), target: .topic(.named("Same"))))).kind, .topicAmbiguous)
        XCTAssertEqual(try failure(service().handle(EnvironmentRequest(.reopen, target: .topic(.id("missing"))))).kind, .topicUnavailable)
        XCTAssertTrue(try records().allSatisfy { $0.title == "Same" || $0.id == elsewhere })
    }

    func testAFailureOfTheStateFolderNamesTheFolderAndAPlainReason() throws {
        try FileManager.default.createDirectory(at: paths.state, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: paths.state.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.state.path) }
        let denied = try failure(service().handle(EnvironmentRequest(.create(title: "X"))))
        XCTAssertEqual(denied.kind, .storeFailed)
        XCTAssertEqual(denied.message, "Muxify could not read or write its state in \(paths.stateDatabase.path). SQLite: unable to open database file.")
        XCTAssertEqual(denied.phase.summary, "No changes were made.")

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.state.path)
        let topic = try XCTUnwrap(change(service().handle(EnvironmentRequest(.create(title: "X")))).topicID)
        XCTAssertEqual(try failure(service().handle(EnvironmentRequest(.addSession(sessionPath: "/nowhere", workingCopy: .directory),
                                                                       target: .topic(.id(topic))))).message,
                       "No launch directory is available at /nowhere.")
        try FileManager.default.removeItem(at: paths.state)
        try Data().write(to: paths.state)
        let notAFolder = try failure(service().handle(EnvironmentRequest(.list)))
        let records = "Muxify could not read or write the Topic records in \(paths.state.path). "
        #if canImport(Darwin)
        XCTAssertEqual(notAFolder.message, records
                       + "The file “muxify” couldn’t be saved in the folder “state” because a file with the same name already exists.")
        #else
        // Foundation on Linux words the same refusal more briefly.
        XCTAssertEqual(notAFolder.message, records + "The operation could not be completed. A file with the same name already exists.")
        #endif
    }

    func testListGivesTheOpenTopicsWithTheirLabelsAndPinsAndASecondPinChangesNothing() throws {
        var fix = TopicRecord(id: "a", title: "Fix")
        fix.isPinned = true
        var done = TopicRecord(id: "d", title: "Done")
        done.settledAt = "2026-10-01T10:00:00Z"
        try paths.seedTopicRecords(fix, TopicRecord(id: "b", slug: "fix-login"), TopicRecord(id: "c", title: ""), done)
        let listed = EnvironmentResponse.topics([
            TopicSummary(id: "a", label: "Fix", pinned: true), TopicSummary(id: "b", label: "Untitled 1"), TopicSummary(id: "c", label: "Untitled 2"),
        ])
        XCTAssertEqual(service().handle(EnvironmentRequest(.list)), listed)
        let observer = TopicStore(paths: paths)
        let token = observer.changeToken()
        _ = try change(service().handle(EnvironmentRequest(.pin, target: .topic(.id("a")))))
        XCTAssertEqual(observer.changeToken(), token, "a second Pin of the same Topic changes nothing")
        XCTAssertEqual(service().handle(EnvironmentRequest(.list)), listed)
    }

    func testTheSettlePreviewOffersEachLiveSessionAndChangesNothing() throws {
        let id = try topicWithSession("Ship", at: sessionPath.folder.path, using: service())
        let before = try paths.storedTopicRows()
        let choices = try service().settleChoices(for: .topic(.id(id))).get()
        XCTAssertEqual(choices.map(\.name), ["game/ship"])
        XCTAssertEqual(try paths.storedTopicRows(), before)
    }

    func testSettleKillsOrKeepsEachSessionAsChosen() throws {
        let id = try twoSessionPathTopic("Ship")
        var choices = try service().settleChoices(for: .topic(.id(id))).get()
        XCTAssertEqual(choices.map(\.disposition), [.kill, .kill])
        let toolsIndex = try XCTUnwrap(choices.firstIndex { $0.name == "tools/ship" })
        choices[toolsIndex].disposition = .keep
        _ = try change(service().handle(EnvironmentRequest(.settle(choices: choices), target: .topic(.id(id)))))
        let record = try XCTUnwrap(records().first { $0.id == id })
        XCTAssertNotNil(record.settledAt)
        XCTAssertEqual(record.sessions.compactMap { $0["directory"]?.string }, [sessionPath.folder.path, tools.folder.path])
        let names = try server.snapshot().windows.map(\.sessionName)
        XCTAssertFalse(names.contains("game/ship"), "the killed Session is gone")
        XCTAssertEqual(try server.snapshot().windows.filter { $0.sessionName == "tools" }.map(\.topicID), [nil],
                       "the kept Session stays with no Topic")
        XCTAssertEqual(service().handle(EnvironmentRequest(.list)), .topics([]))
    }

    func testRenameChangesTheTitleAndRenamesEverySessionOfTheTopic() throws {
        let id = try twoSessionPathTopic("Ship")
        let before = Set(try server.snapshot().windows.filter { $0.topicID == id }.map(\.sessionID))
        _ = try change(service().handle(EnvironmentRequest(.rename(title: " Ship it "), target: .topic(.id(id)))))
        let record = try XCTUnwrap(records().first { $0.id == id })
        XCTAssertEqual(record.title, "Ship it")
        XCTAssertEqual(record.slug, "ship-it")
        XCTAssertEqual(try sessions(of: id), ["game/ship-it", "tools/ship-it"])
        XCTAssertEqual(Set(try server.snapshot().windows.filter { $0.topicID == id }.map(\.sessionID)), before, "the same Sessions, renamed")
    }

    func testReopenCreatesTheRememberedSessionsAndWindowsOfASettledTopic() throws {
        let id = try topicWithSession("Ship", at: sessionPath.folder.path, using: service())
        try server.run(["rename-window", "-t", "=game/ship:", "notes"])
        try server.run(["new-window", "-d", "-t", "=game/ship:", "-n", "logs", "-c", root.path])
        try waitForPath(sessionPath.folder.path, of: "=game/ship:notes")
        try waitForPath(root.path, of: "=game/ship:logs")
        _ = try change(service().handle(EnvironmentRequest(.settle(choices: []), target: .topic(.id(id)))))
        XCTAssertEqual(try sessions(of: id), [])
        let reopened = try change(service().handle(EnvironmentRequest(.reopen, target: .topic(.id(id)))))
        XCTAssertEqual(reopened.topicID, id)
        let record = try XCTUnwrap(records().first { $0.id == id })
        XCTAssertNil(record.settledAt)
        let windows = try server.snapshot().windows.filter { $0.topicID == id }.sorted { $0.index < $1.index }
        XCTAssertEqual(windows.map(\.sessionName), ["game/ship", "game/ship"])
        XCTAssertEqual(windows.map(\.name), ["notes", "logs"])
        // tmux reports /tmp as /private/tmp.
        XCTAssertEqual(windows.map { ($0.path as NSString).resolvingSymlinksInPath }, [sessionPath.folder.path, root.path])
        XCTAssertEqual(reopened.shown, WindowID(rawValue: windows[0].id).map { .window($0) })
    }

    func testAddSessionAnswersWithTheIdsOfTheSessionWindowAndPaneThatItMade() throws {
        let id = try XCTUnwrap(change(service().handle(EnvironmentRequest(.create(title: "Ids")))).topicID)
        let added = try change(service().handle(EnvironmentRequest(.addSession(sessionPath: sessionPath.folder.path, workingCopy: .directory),
                                                                   target: .topic(.id(id)))))
        let window = try XCTUnwrap(try server.snapshot().windows.first { $0.topicID == id })
        XCTAssertEqual(added.topicID, id)
        XCTAssertEqual(added.session?.rawValue, window.sessionID)
        XCTAssertEqual(added.sessionName, "game/ids")
        XCTAssertEqual(added.window?.rawValue, window.id)
        XCTAssertEqual(added.pane?.rawValue, window.activePaneID)
        let text = String(decoding: try JSONEncoder().encode(EnvironmentResponse.changed(TopicChange(topicID: id))), as: UTF8.self)
        XCTAssertFalse(text.contains("window"), "a change that made nothing in tmux names no ids: \(text)")
    }

    func testMarkReadChangesTheTopicUnreadOnlyForATopicAndEachAgentInItsScope() throws {
        let id = try topicWithSession("Read it", at: sessionPath.folder.path, using: service())
        let window = try XCTUnwrap(try server.snapshot().windows.first { $0.topicID == id })
        let main = try XCTUnwrap(try server.snapshot().windows.first { $0.sessionName == "main" })
        func agent(in window: TmuxWindow, status: String, unread: Bool) throws -> PaneID {
            // exec: Linux's sh, dash, would otherwise stay the Pane's command in front of sleep.
            let pane = try server.run(["split-window", "-d", "-P", "-F", "#{pane_id}", "-t", window.id, "exec sleep 600"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            try server.run(["set-option", "-p", "-t", pane, "@muxify_agent", "claude", ";", "set-option", "-p", "-t", pane, "@muxify_agent_status", status]
                           + (unread ? [";", "set-option", "-p", "-t", pane, "@muxify_agent_unread", "1"] : []))
            let deadline = Date().addingTimeInterval(5)
            while try server.snapshot().panes.first(where: { $0.id == pane })?.command != "sleep", Date() < deadline { usleep(20_000) }
            return try XCTUnwrap(PaneID(rawValue: pane))
        }
        let done = try agent(in: window, status: "done", unread: false)
        _ = try agent(in: window, status: "working", unread: false)
        let outside = try agent(in: main, status: "failed", unread: true)
        func unreadPanes() throws -> Set<String> { Set(try server.snapshot().panes.filter(\.unread).map(\.id)) }
        func topicUnread() throws -> Bool { try XCTUnwrap(records().first { $0.id == id }).isUnread }

        XCTAssertEqual(service().handle(EnvironmentRequest(.markRead(.unread, scope: .topic), target: .topic(.id(id)))),
                       .readChanged(TopicReadChange(topicIDs: [id], paneIDs: [done])), "a working Agent does not become Unread")
        XCTAssertTrue(try topicUnread())
        XCTAssertEqual(try unreadPanes(), [done.rawValue, outside.rawValue])

        XCTAssertEqual(service().handle(EnvironmentRequest(.markRead(.read, scope: .session), target: .pane(done))),
                       .readChanged(TopicReadChange(paneIDs: [done])), "a Session leaves the Topic Unread as it is")
        XCTAssertTrue(try topicUnread())
        XCTAssertEqual(service().handle(EnvironmentRequest(.markRead(.read, scope: .pane), target: .pane(done))),
                       .readChanged(TopicReadChange()), "nothing to change is a success")

        XCTAssertEqual(service().handle(EnvironmentRequest(.markAllRead)), .readChanged(TopicReadChange(topicIDs: [id], paneIDs: [outside])))
        XCTAssertFalse(try topicUnread())
        XCTAssertEqual(try unreadPanes(), [])

        try TopicStore(paths: paths).write { try $0.update(id) { $0.settledAt = "2026-10-01T00:00:00Z" } }
        XCTAssertEqual(service().handle(EnvironmentRequest(.markRead(.unread, scope: .topic), target: .topic(.id(id)))),
                       .readChanged(TopicReadChange(topicIDs: [id], paneIDs: [done])), "a Settled Topic named by ref shows its Unread mark in the Settled list")
        XCTAssertTrue(try topicUnread())
        XCTAssertEqual(service().handle(EnvironmentRequest(.markRead(.read, scope: .topic), target: .topic(.id(id)))),
                       .readChanged(TopicReadChange(topicIDs: [id], paneIDs: [done])))
        XCTAssertFalse(try topicUnread())
    }

    func testTopicMarkChangesOnlyTheTopicUnreadAndASecondCallChangesNothing() throws {
        let id = try topicWithSession("Mark only", at: sessionPath.folder.path, using: service())
        let window = try XCTUnwrap(try server.snapshot().windows.first { $0.topicID == id })
        let pane = try server.run(["split-window", "-d", "-P", "-F", "#{pane_id}", "-t", window.id, "exec sleep 600"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try server.run(["set-option", "-p", "-t", pane, "@muxify_agent", "claude", ";", "set-option", "-p", "-t", pane, "@muxify_agent_status", "done",
                        ";", "set-option", "-p", "-t", pane, "@muxify_agent_unread", "1"])
        try TopicStore(paths: paths).write { try $0.update(id) { $0.isUnread = true } }
        func unreadPanes() throws -> Set<String> { Set(try server.snapshot().panes.filter(\.unread).map(\.id)) }
        func topicUnread() throws -> Bool { try XCTUnwrap(records().first { $0.id == id }).isUnread }
        let read = EnvironmentRequest(.markRead(.read, scope: .topicMark), target: .topic(.id(id)))

        XCTAssertEqual(service().handle(read), .readChanged(TopicReadChange(topicIDs: [id])))
        XCTAssertFalse(try topicUnread())
        XCTAssertEqual(try unreadPanes(), [pane], "the Agent keeps its Unread")
        XCTAssertEqual(service().handle(read), .readChanged(TopicReadChange()), "a second call changes nothing and succeeds")

        XCTAssertEqual(service().handle(EnvironmentRequest(.markRead(.unread, scope: .topicMark), target: .topic(.id(id)))),
                       .readChanged(TopicReadChange(topicIDs: [id])))
        XCTAssertTrue(try topicUnread())
    }

    func testKillRunsOnlyWhileThePanesAreTheReviewedOnesAndTheLastSessionLeavesTheTopicEmpty() throws {
        let id = try topicWithSession("Stop it", at: sessionPath.folder.path, using: service())
        let window = try XCTUnwrap(try server.snapshot().windows.first { $0.topicID == id })
        let reviewed = Set(try server.snapshot().panes.filter { $0.windowID == window.id }.compactMap { PaneID(rawValue: $0.id) })
        let agent = try server.run(["split-window", "-d", "-P", "-F", "#{pane_id}", "-t", window.id, "exec sleep 600"]).trimmingCharacters(in: .whitespacesAndNewlines)
        try server.run(["set-option", "-p", "-t", agent, "@muxify_agent", "claude"])
        let session = try XCTUnwrap(SessionID(rawValue: window.sessionID))
        let changed = try failure(service().handle(EnvironmentRequest(.killSession, target: .session(session), expectedPaneIDs: reviewed)))
        XCTAssertEqual(changed.kind, .panesChanged)
        XCTAssertEqual(changed.phase, .nothingChanged)
        XCTAssertTrue(try server.snapshot().windows.contains { $0.sessionID == window.sessionID }, "a changed review killed nothing")

        let all = reviewed.union([PaneID(rawValue: agent)!])
        let killed = try change(service().handle(EnvironmentRequest(.killSession, target: .session(session), expectedPaneIDs: all)))
        XCTAssertEqual(killed.topicID, id)
        XCTAssertEqual(killed.stopped, [PaneID(rawValue: agent)!])
        XCTAssertFalse(try server.snapshot().windows.contains { $0.sessionID == window.sessionID })
        let record = try XCTUnwrap(records().first { $0.id == id })
        XCTAssertNil(record.settledAt, "the Topic stays open")
        XCTAssertEqual(record.sessions, [], "the user stopped its last Session, so the Topic is Empty")
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
}

/// The Worktrees that Add a Session makes, and what Settle, Forget, Remove and Kill and Reopen do with them.
final class TopicServiceWorktreeTests: TopicServiceTestCase {
    func testForgetRemovesAnUnmergedCleanWorktreeAndKeepsItsBranch() throws {
        let app = try repository()
        _ = try addNewWorktree(of: app, start: .head, title: "Forget clean")
        let id = try XCTUnwrap(records().first?.id)
        let path = paths.worktrees.appendingPathComponent("app/forget-clean").path
        try git(["commit", "-q", "--allow-empty", "-m", "unmerged"], in: path)
        let service = EnvironmentService(paths: paths, server: server, sessionPaths: [app])
        XCTAssertTrue(try service.settleChoices(for: .topic(.id(id))).get().allSatisfy { $0.worktree == nil })
        XCTAssertEqual(try service.forgetChoices(for: .topic(.id(id))).get().worktrees.filter(\.isClean).map(\.id), [path])
        try assertThrowawayServer()
        var killed = try service.forgetChoices(for: .topic(.id(id))).get().sessions
        for index in killed.indices { killed[index].disposition = .kill }
        _ = try change(service.handle(EnvironmentRequest(.forget(choices: killed, worktrees: [path]), target: .topic(.id(id)))))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertFalse(try git(["branch", "--list", "forget-clean"], in: app.folder.path).isEmpty)
    }

    func testForgetOfASettledTopicRemovesItsRememberedWorktree() throws {
        let app = try repository()
        _ = try addNewWorktree(of: app, start: .head, title: "Remembered")
        let id = try XCTUnwrap(records().first?.id)
        let path = paths.worktrees.appendingPathComponent("app/remembered").path
        let service = EnvironmentService(paths: paths, server: server, sessionPaths: [app])
        try assertThrowawayServer()
        var killed = try service.settleChoices(for: .topic(.id(id))).get()
        for index in killed.indices { killed[index].disposition = .kill }
        _ = try change(service.handle(EnvironmentRequest(.settle(choices: killed), target: .topic(.id(id)))))
        let choices = try service.forgetChoices(for: .topic(.id(id))).get()
        XCTAssertTrue(choices.sessions.isEmpty)
        XCTAssertEqual(choices.worktrees.map(\.id), [path])
        try assertThrowawayServer()
        _ = try change(service.handle(EnvironmentRequest(.forget(choices: [], worktrees: [path]), target: .topic(.id(id)))))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(try records().isEmpty)
    }

    func testForgetKeepsDirtyWorktreesAndWorktreesUsedByKeptSessions() throws {
        let app = try repository()
        for dirty in [false, true] {
            let title = dirty ? "Dirty" : "Kept"
            _ = try addNewWorktree(of: app, start: .head, title: title)
            let id = try XCTUnwrap(records().first { $0.title == title }?.id)
            let path = paths.worktrees.appendingPathComponent("app/" + title.lowercased()).path
            if dirty { try "draft".write(toFile: path + "/draft", atomically: true, encoding: .utf8) }
            let service = EnvironmentService(paths: paths, server: server, sessionPaths: [app])
            var choices = try service.forgetChoices(for: .topic(.id(id))).get()
            XCTAssertEqual(choices.worktrees.first?.isClean, !dirty)
            if !dirty { choices.sessions[0].disposition = .keep }
            try assertThrowawayServer()
            _ = try change(service.handle(EnvironmentRequest(.forget(choices: choices.sessions, worktrees: [path]), target: .topic(.id(id)))))
            XCTAssertTrue(FileManager.default.fileExists(atPath: path))
            XCTAssertFalse(try records().contains { $0.id == id })
        }
    }

    func testRemoveAndKillRemovesTheCleanWorktreeOnlyWhenTheRequestNamesIt() throws {
        let app = try repository()
        let service = EnvironmentService(paths: paths, server: server, sessionPaths: [sessionPath, app])
        for remove in [false, true] {
            let title = remove ? "Remove tree" : "Keep tree"
            let session = try addNewWorktree(of: app, start: .head, title: title)
            let id = try XCTUnwrap(records().first { $0.title == title }?.id)
            let worktree = try XCTUnwrap(session["worktree_path"]?.string)
            let live = try XCTUnwrap(try server.snapshot().windows.first { $0.topicID == id })
            try assertThrowawayServer()
            _ = try change(service.handle(EnvironmentRequest(.removeAndKill(worktrees: remove ? [worktree] : []),
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
    private func addNewWorktree(of app: SessionPath, start: WorktreeStart, title: String) throws -> JSONValue {
        let service = EnvironmentService(paths: paths, server: server, sessionPaths: [sessionPath, app])
        let id = try XCTUnwrap(change(service.handle(EnvironmentRequest(.create(title: title)))).topicID)
        _ = try change(service.handle(EnvironmentRequest(.addSession(sessionPath: app.folder.path, workingCopy: .newWorktree(from: app.folder.path, start: start)),
                                                   target: .topic(.id(id)))))
        return try XCTUnwrap(records().first { $0.id == id }?.sessions.first)
    }

    func testANewWorktreeStartsAtTheBaseHeadOrTheCommitThatARefNamesAndTheRecordKeepsThatCommit() throws {
        let app = try repository()
        let session = try addNewWorktree(of: app, start: .head, title: "Ship")
        let head = try git(["rev-parse", "HEAD"], in: app.folder.path)
        let worktree = paths.worktrees.appendingPathComponent("app/ship").path
        XCTAssertEqual(session["base"], .string(head))
        XCTAssertEqual(session["worktree_path"], .string(worktree))
        XCTAssertEqual(session["branch"], .string("ship"))
        XCTAssertEqual(session["worktree_created"], .bool(true))
        XCTAssertEqual(try git(["rev-parse", "HEAD"], in: worktree), head)
        XCTAssertEqual(try git(["symbolic-ref", "--short", "HEAD"], in: worktree), "ship")

        let hotfix = try addNewWorktree(of: app, start: .ref("v1"), title: "Hotfix")
        let tagged = try git(["rev-parse", "v1^{commit}"], in: app.folder.path)
        XCTAssertNotEqual(tagged, head)
        XCTAssertEqual(hotfix["base"], .string(tagged))
        XCTAssertEqual(try git(["rev-parse", "HEAD"], in: paths.worktrees.appendingPathComponent("app/hotfix").path), tagged)
    }

    func testANewWorktreeOnABranchChecksItOutAndSettleRemovesTheWorktreeAndKeepsTheBranch() throws {
        let app = try repository()
        try git(["branch", "feature/hover"], in: app.folder.path)
        let commit = try git(["rev-parse", "feature/hover"], in: app.folder.path)
        let session = try addNewWorktree(of: app, start: .branch("feature/hover"), title: "Hover")
        let worktree = paths.worktrees.appendingPathComponent("app/feature-hover").path
        XCTAssertEqual(session["worktree_path"], .string(worktree))
        XCTAssertEqual(session["branch"], .string("feature/hover"))
        XCTAssertEqual(session["worktree_created"], .bool(true), "Muxify made the Worktree, so Settle may remove it")
        XCTAssertEqual(session["base"], .string(commit))
        XCTAssertEqual(try git(["symbolic-ref", "--short", "HEAD"], in: worktree), "feature/hover")

        let service = EnvironmentService(paths: paths, server: server, sessionPaths: [sessionPath, app])
        let id = try XCTUnwrap(records().first { $0.title == "Hover" }?.id)
        var choices = try service.settleChoices(for: .topic(.id(id))).get()
        for index in choices.indices { choices[index].disposition = .kill; choices[index].removeWorktree = true }
        try git(["update-ref", "refs/heads/main", commit], in: app.folder.path)
        _ = try change(service.handle(EnvironmentRequest(.settle(choices: choices), target: .topic(.id(id)))))
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree), "Settle kept the merged Worktree that Muxify made")
        XCTAssertEqual(try git(["rev-parse", "feature/hover"], in: app.folder.path), commit, "the branch stays")
    }

    func testAStartThatNamesNoBranchACheckedOutBranchOrNoCommitFailsAndMakesNoWorktree() throws {
        let app = try repository()
        let service = EnvironmentService(paths: paths, server: server, sessionPaths: [sessionPath, app])
        let id = try XCTUnwrap(change(service.handle(EnvironmentRequest(.create(title: "Ship")))).topicID)
        let cases: [(start: WorktreeStart, kind: TopicFailure.Kind, message: String)] = [
            (.branch("nope"), .branchUnavailable, "No local branch nope is in the repository of \(app.folder.path)."),
            (.branch("main"), .branchCheckedOut, "checked out in the Worktree"),
            (.ref("nope"), .gitFailed, "No commit matches nope in \(app.folder.path)."),
        ]
        for (start, kind, message) in cases {
            let failed = try failure(service.handle(EnvironmentRequest(.addSession(sessionPath: app.folder.path,
                                                                                   workingCopy: .newWorktree(from: app.folder.path, start: start)),
                                                                      target: .topic(.id(id)))))
            XCTAssertEqual(failed.kind, kind, "\(start)")
            XCTAssertEqual(failed.phase, .nothingChanged, "\(start)")
            XCTAssertTrue(failed.message.contains(message), "\(start): \(failed.message)")
        }
        XCTAssertEqual(try records().first { $0.id == id }?.sessions, [])
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: paths.worktrees.appendingPathComponent("app").path)) ?? [], [])
        XCTAssertEqual(try service.worktreeStarts(from: app.folder.path).get().first { $0.branch == "main" }?.checkedOutAt.map(Folder.local),
                       app.folder, "the start step shows where main is checked out")
    }

    /// A Settled Topic whose new Worktree `app/ship` and branch `ship` are both gone, and whose SessionPath HEAD moved on.
    private func settledWithGoneWorktree(of app: SessionPath) throws -> (id: String, base: String) {
        let session = try addNewWorktree(of: app, start: .head, title: "Ship")
        let id = try XCTUnwrap(records().first?.id)
        let base = try XCTUnwrap(session["base"]?.string)
        let service = EnvironmentService(paths: paths, server: server, sessionPaths: [sessionPath, app])
        _ = try change(service.handle(EnvironmentRequest(.settle(choices: []), target: .topic(.id(id)))))
        try git(["worktree", "remove", "--force", paths.worktrees.appendingPathComponent("app/ship").path], in: app.folder.path)
        try git(["branch", "-D", "ship"], in: app.folder.path)
        try git(["commit", "-q", "--allow-empty", "-m", "third"], in: app.folder.path)
        XCTAssertNotEqual(try git(["rev-parse", "HEAD"], in: app.folder.path), base)
        return (id, base)
    }

    func testReopenStartsAGoneBranchAgainAtTheRecordedBase() throws {
        let app = try repository()
        let (id, base) = try settledWithGoneWorktree(of: app)
        let service = EnvironmentService(paths: paths, server: server, sessionPaths: [sessionPath, app])
        _ = try change(service.handle(EnvironmentRequest(.reopen, target: .topic(.id(id)))))
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
        let missing = String(repeating: "0", count: 40)
        try paths.withStateDatabase { try $0.execute("UPDATE topics SET sessions = replace(sessions, ?, ?)", base, missing) }
        let before = try records()
        let service = EnvironmentService(paths: paths, server: server, sessionPaths: [sessionPath, app])
        let worktree = paths.worktrees.appendingPathComponent("app/ship").path
        let failed = try failure(service.handle(EnvironmentRequest(.reopen, target: .topic(.id(id)))))
        XCTAssertEqual(failed, TopicFailure(kind: .gitFailed, phase: .nothingChanged, message: "The Worktree \(worktree) and its branch are gone, "
                       + "and the repository does not have their base commit \(missing). Muxify did not make the Worktree again."))
        XCTAssertEqual(try records(), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree))
        XCTAssertEqual(try git(["branch", "--list", "ship"], in: app.folder.path), "")
        XCTAssertEqual(try sessions(of: id), [])
    }

    func testSettleRefusesToRemoveAWorktreeWithUncommittedWorkAndChangesNothing() throws {
        let app = try repository()
        _ = try addNewWorktree(of: app, start: .head, title: "Ship")
        let id = try XCTUnwrap(records().first?.id)
        let worktree = paths.worktrees.appendingPathComponent("app/ship").path
        try "draft".write(toFile: worktree + "/notes.txt", atomically: true, encoding: .utf8)
        let service = EnvironmentService(paths: paths, server: server, sessionPaths: [sessionPath, app])
        var choices = try service.settleChoices(for: .topic(.id(id))).get()
        XCTAssertEqual(choices.map(\.worktree?.path), [worktree], "Settle offers to remove the merged Worktree")
        choices[0].removeWorktree = true
        choices[0].disposition = .kill
        let before = try records()
        let failed = try failure(service.handle(EnvironmentRequest(.settle(choices: choices), target: .topic(.id(id)))))
        XCTAssertEqual(failed, TopicFailure(kind: .gitFailed, phase: .nothingChanged,
                                            message: "The Worktree \(worktree) has uncommitted changes. Commit or remove them, or keep the Worktree."))
        XCTAssertEqual(try records(), before, "the Topic is not Settled")
        XCTAssertEqual(try sessions(of: id), ["app/ship"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree + "/notes.txt"))
    }
}

/// The cards of the Topics list: In Play, the Guests, the Bench, Locks and Pins.
final class TopicServiceCardTests: TopicServiceTestCase {
    func testMakeAGuestPutsANoTopicSessionAtTheEndOfTheGuestsAndBenchEndsIt() throws {
        try server.run(["new-session", "-d", "-s", "notes", "-c", sessionPath.folder.path])
        try regularTopic("First", using: service())
        let second = try topicWithSession("Second", at: sessionPath.folder.path, using: service())
        _ = try change(service().handle(EnvironmentRequest(.benchTopic, target: .topic(.id(second)))))
        let locked = try change(service().handle(EnvironmentRequest(.makeGuest, target: .sessionName("notes"))))
        XCTAssertNil(locked.topicID)
        XCTAssertEqual(try topicList(), ["First", "Second", "lock:notes"])
        _ = try change(service().handle(EnvironmentRequest(.create(title: "Third"))))
        _ = try change(service().handle(EnvironmentRequest(.makeGuest, target: .sessionName("notes"))))
        XCTAssertEqual(try topicList(), ["First", "Second", "lock:notes", "Third"], "a new Topic is the last Guest, and a Guest Session keeps its place")

        let inTopic = try failure(service().handle(EnvironmentRequest(.makeGuest, target: .sessionName("game/second"))))
        XCTAssertEqual(inTopic.kind, .cardNotBenched, "a Session in a Topic names the Topic's card, which is In Play")
        XCTAssertEqual(inTopic.phase, .nothingChanged)
        XCTAssertEqual(try failure(service().handle(EnvironmentRequest(.makeGuest, target: .sessionName("missing")))).kind, .sourceUnavailable)

        _ = try change(service().handle(EnvironmentRequest(.benchTopic, target: .sessionName("notes"))))
        XCTAssertEqual(try topicList(), ["First", "Second", "Third"])
        XCTAssertEqual(try server.run(["show-options", "-qv", "-t", "notes", SessionLock.option]), "")
    }

    func testALockedSessionThatGoesIntoATopicLosesItsLock() throws {
        try server.run(["new-session", "-d", "-s", "notes", "-c", sessionPath.folder.path])
        try server.run(["new-session", "-d", "-s", "chores", "-c", tools.folder.path])
        try regularTopic("First", using: service())
        try regularTopic("Second", using: service())
        _ = try change(service().handle(EnvironmentRequest(.makeGuest, target: .sessionName("notes"))))
        _ = try change(service().handle(EnvironmentRequest(.makeGuest, target: .sessionName("chores"))))
        XCTAssertEqual(try topicList(), ["First", "Second", "lock:notes", "lock:chores"])

        let notes = try XCTUnwrap(SessionID(rawValue: try server.snapshot().windows.first { $0.sessionName == "notes" }!.sessionID))
        let created = try change(service().handle(EnvironmentRequest(.move(to: .newTopic(title: "Notes work")), target: .session(notes))))
        XCTAssertTrue(created.created)
        XCTAssertEqual(try topicList(), ["First", "Second", "Notes work", "lock:chores"], "the new Topic takes the Lock's place")

        let chores = try XCTUnwrap(SessionID(rawValue: try server.snapshot().windows.first { $0.sessionName == "chores" }!.sessionID))
        _ = try change(service().handle(EnvironmentRequest(.move(to: .topic(.named("Second"))), target: .session(chores))))
        XCTAssertEqual(try topicList(), ["First", "Second", "Notes work"], "the Topic that the Session moves to keeps its place")
        XCTAssertTrue(try server.snapshot().windows.allSatisfy { $0.lockOrder == nil })
    }

    func testAReturningTopicGoesAfterAGuestSessionAndSavesNormalizedLockRanks() throws {
        let one = service(inPlay: 1)
        try regularTopic("First", using: one)
        let returning = try regularTopic("Returning", using: one)
        XCTAssertEqual(try topicList(), ["First", "Returning"])
        try server.run(["new-session", "-d", "-s", "notes", "-c", sessionPath.folder.path])
        try server.run(["set-option", "-t", "notes", SessionLock.option, String(Double.greatestFiniteMagnitude)])
        try TopicStore(paths: paths).write { try $0.update(returning) { $0.settledAt = "2026-10-01T00:00:00Z" } }
        _ = try change(one.handle(EnvironmentRequest(.reopen, target: .topic(.id(returning)))))
        XCTAssertEqual(try topicList(), ["First", "lock:notes", "Returning"])
        let lockOrder = try XCTUnwrap(Double(server.run(["show-options", "-qv", "-t", "notes", SessionLock.option]).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertLessThan(lockOrder, Double.greatestFiniteMagnitude, "Reopen must save normalized Lock ranks to tmux")
        try TopicStore(paths: paths).write { try $0.update(returning) { $0.settledAt = "2026-10-01T00:00:00Z" } }
        _ = try change(one.handle(EnvironmentRequest(.startFresh, target: .topic(.id(returning)))))
        XCTAssertEqual(try topicList(), ["First", "lock:notes", "Returning"])
    }

    func testANewTopicIsTheLastGuestAndAReturningTopicGoesToTheTopOfTheBench() throws {
        let inPlay = service(inPlay: 2)
        func settle(_ title: String) throws -> String {
            let id = try XCTUnwrap(records().first { $0.title == title }).id
            try TopicStore(paths: paths).write { try $0.update(id) { $0.settledAt = "2026-10-01T00:00:00Z" } }
            return id
        }
        for title in ["First", "Second", "Third", "Fourth"] { try regularTopic(title, using: inPlay) }
        XCTAssertEqual(try topicList(), ["First", "Second", "Fourth", "Third"])
        _ = try change(inPlay.handle(EnvironmentRequest(.reopen, target: .topic(.id(settle("Second"))))))
        XCTAssertEqual(try topicList(), ["First", "Fourth", "Second", "Third"], "Reopen")
        _ = try change(inPlay.handle(EnvironmentRequest(.startFresh, target: .topic(.id(settle("Third"))))))
        XCTAssertEqual(try topicList(), ["First", "Fourth", "Third", "Second"], "Start Fresh")

        _ = try change(inPlay.handle(EnvironmentRequest(.create(title: "Fifth"))))
        _ = try change(inPlay.handle(EnvironmentRequest(.create(title: "Sixth"))))
        XCTAssertEqual(try topicList(), ["First", "Fourth", "Fifth", "Sixth", "Third", "Second"], "a new Topic is the last Guest")
        XCTAssertEqual(try guests(), ["Fifth", "Sixth"])
    }

    /// A service with `topics.in_play` set to `count`.
    private func service(inPlay count: Int) -> EnvironmentService {
        var topics = Config.Topics()
        topics.inPlay = count
        return EnvironmentService(paths: paths, server: server, sessionPaths: [sessionPath], topics: topics)
    }

    /// The Session `name`'s tmux id.
    private func sessionID(_ name: String) throws -> SessionID {
        try XCTUnwrap(SessionID(rawValue: try server.snapshot().windows.first { $0.sessionName == name }!.sessionID))
    }

    /// The open Topics that have the Guest mark, by title.
    private func guests() throws -> Set<String> {
        Set(try records().filter { $0.isGuest && $0.settledAt == nil }.compactMap(\.title))
    }

    func testChooseInPlayFillsThePlacesInTheChosenOrderAndLeavesTheOthersOpen() throws {
        let inPlay = service(inPlay: 2)
        for title in ["A", "B", "C", "D", "Pinned"] { try regularTopic(title, using: inPlay) }
        _ = try change(inPlay.handle(EnvironmentRequest(.pin, target: .topic(.named("Pinned")))))
        try server.run(["new-session", "-d", "-s", "notes", "-c", sessionPath.folder.path])
        _ = try change(inPlay.handle(EnvironmentRequest(.makeGuest, target: .sessionName("notes"))))
        let notes = try sessionID("notes")
        XCTAssertEqual(try topicList(), ["Pinned", "A", "B", "lock:notes", "D", "C"],
                       "Bench puts each Topic after the places at the top of the Bench, and a Lock is a Guest at the end of In Play")

        _ = try change(inPlay.handle(EnvironmentRequest(.chooseInPlay([.topic(.named("C")), .topic(.named("A"))]))))
        XCTAssertEqual(try topicList(), ["Pinned", "C", "A", "lock:notes", "B", "D"], "the Guest stays a Guest")

        let refused: [(EnvironmentService, [TopicListRef], TopicFailure.Kind)] = [
            (inPlay, [.topic(.named("A")), .topic(.named("Pinned"))], .cardPinned),
            (inPlay, [.topic(.named("A")), .lock(notes)], .cardGuest),
            (inPlay, [.topic(.named("A")), .topic(.named("A"))], .unsupported),
            (inPlay, [.topic(.named("Missing"))], .topicUnavailable),
        ]
        for (service, cards, kind) in refused {
            let refusal = try failure(service.handle(EnvironmentRequest(.chooseInPlay(cards))))
            XCTAssertEqual(refusal.kind, kind, "\(cards)")
            XCTAssertEqual(refusal.phase, .nothingChanged)
        }
        XCTAssertEqual(try topicList(), ["Pinned", "C", "A", "lock:notes", "B", "D"])
    }

    func testReplaceFromBenchPutsTheBenchedCardInThePlaceAndGivesItTheMarkOfAGuest() throws {
        let inPlay = service(inPlay: 2)
        for title in ["A", "B", "C", "D", "Pinned"] { try regularTopic(title, using: inPlay) }
        _ = try change(inPlay.handle(EnvironmentRequest(.pin, target: .topic(.named("Pinned")))))
        try server.run(["new-session", "-d", "-s", "notes", "-c", sessionPath.folder.path])
        _ = try change(inPlay.handle(EnvironmentRequest(.makeGuest, target: .sessionName("notes"))))
        XCTAssertEqual(try topicList(), ["Pinned", "A", "B", "lock:notes", "D", "C"])

        let came = try change(inPlay.handle(EnvironmentRequest(.replaceFromBench(with: .topic(.named("C"))), target: .sessionName("notes"))))
        XCTAssertEqual(came.topicID, try records().first { $0.title == "C" }?.id)
        XCTAssertEqual(try topicList(), ["Pinned", "A", "B", "C", "D"], "the Lock of a Guest Session ends")
        XCTAssertEqual(try guests(), ["C"], "the card that comes In Play takes the Guest mark")
        XCTAssertTrue(try server.snapshot().windows.allSatisfy { $0.lockOrder == nil })

        let refused: [(EnvironmentService, EnvironmentTarget, TopicListRef, TopicFailure.Kind)] = [
            (inPlay, .topic(.named("D")), .topic(.named("B")), .cardNotInPlay),
            (inPlay, .topic(.named("Pinned")), .topic(.named("D")), .cardNotInPlay),
            (inPlay, .topic(.named("B")), .topic(.named("A")), .cardNotBenched),
        ]
        for (service, target, benched, kind) in refused {
            let refusal = try failure(service.handle(EnvironmentRequest(.replaceFromBench(with: benched), target: target)))
            XCTAssertEqual(refusal.kind, kind, "\(target) with \(benched)")
            XCTAssertEqual(refusal.phase, .nothingChanged)
        }
        XCTAssertEqual(try topicList(), ["Pinned", "A", "B", "C", "D"])
    }

    func testATradeExchangesThePlacesOfTwoCardsAndEachCardTakesTheMarkOfItsNewSection() throws {
        let inPlay = service(inPlay: 2)
        for title in ["A", "B", "C", "D", "Pinned"] { try regularTopic(title, using: inPlay) }
        _ = try change(inPlay.handle(EnvironmentRequest(.pin, target: .topic(.named("Pinned")))))
        try server.run(["new-session", "-d", "-s", "notes", "-c", sessionPath.folder.path])
        _ = try change(inPlay.handle(EnvironmentRequest(.makeGuest, target: .sessionName("notes"))))
        let notes = try sessionID("notes")
        XCTAssertEqual(try topicList(), ["Pinned", "A", "B", "lock:notes", "D", "C"])

        let traded = try change(inPlay.handle(EnvironmentRequest(.moveCard(.trade(.topic(.named("D")))), target: .sessionName("notes"))))
        XCTAssertEqual(traded.session, notes)
        XCTAssertEqual(try topicList(), ["Pinned", "A", "B", "D", "C"], "the Lock of a Guest Session ends")
        XCTAssertEqual(try guests(), ["D"])
        _ = try change(inPlay.handle(EnvironmentRequest(.makeGuest, target: .sessionName("notes"))))

        let refused: [(EnvironmentTarget, TopicListRef, TopicFailure.Kind)] = [
            (.topic(.named("Pinned")), .topic(.named("A")), .cardPinned),
            (.topic(.named("A")), .topic(.named("Pinned")), .cardPinned),
            (.topic(.named("A")), .topic(.named("Missing")), .topicUnavailable),
            (.topic(.named("A")), .lock(notes), .cardGuest),
        ]
        for (target, other, kind) in refused {
            let refusal = try failure(inPlay.handle(EnvironmentRequest(.moveCard(.trade(other)), target: target)))
            XCTAssertEqual(refusal.kind, kind, "\(target) with \(other)")
            XCTAssertEqual(refusal.phase, .nothingChanged)
        }
        XCTAssertEqual(try topicList(), ["Pinned", "A", "B", "D", "lock:notes", "C"])
    }

    func testMakeAGuestPutsABenchedTopicAtTheEndOfTheGuestsAndBenchTopicPutsItAtTheTopOfTheBench() throws {
        let inPlay = service(inPlay: 2)
        for title in ["A", "B", "C", "D"] { try regularTopic(title, using: inPlay) }
        XCTAssertEqual(try topicList(), ["A", "B", "D", "C"])

        let made = try change(inPlay.handle(EnvironmentRequest(.makeGuest, target: .topic(.named("C")))))
        XCTAssertEqual(made.topicID, try records().first { $0.title == "C" }?.id)
        XCTAssertEqual(try topicList(), ["A", "B", "C", "D"], "no other card goes to the Bench")
        XCTAssertEqual(try guests(), ["C"])
        let observer = TopicStore(paths: paths)
        let token = observer.changeToken()
        _ = try change(inPlay.handle(EnvironmentRequest(.makeGuest, target: .topic(.named("C")))))
        XCTAssertEqual(observer.changeToken(), token, "a Guest that is made a Guest again does not change")

        _ = try change(inPlay.handle(EnvironmentRequest(.benchTopic, target: .topic(.named("A")))))
        XCTAssertEqual(try topicList(), ["_", "B", "C", "A", "D"], "a Topic from a place leaves an Open Place and goes to the top of the Bench")
        _ = try change(inPlay.handle(EnvironmentRequest(.fillOpenPlace(place: 1), target: .topic(.named("D")))))
        XCTAssertEqual(try topicList(), ["D", "B", "C", "A"], "the Benched Topic fills the Open Place, and no other card moves")

        let refused: [(EnvironmentService, EnvironmentCommand, String, TopicFailure.Kind)] = [
            (inPlay, .makeGuest, "B", .cardNotBenched),
            (inPlay, .benchTopic, "A", .cardNotInPlay),
            (inPlay, .fillOpenPlace(place: 1), "A", .placeNotOpen),
        ]
        for (service, command, title, kind) in refused {
            let refusal = try failure(service.handle(EnvironmentRequest(command, target: .topic(.named(title)))))
            XCTAssertEqual(refusal.kind, kind, "\(command) \(title)")
            XCTAssertEqual(refusal.phase, .nothingChanged)
        }
    }

    private func move(_ direction: CardMove, _ title: String, using service: EnvironmentService) -> EnvironmentResponse {
        service.handle(EnvironmentRequest(.moveCard(direction), target: .topic(.named(title))))
    }

    func testMoveAppliesTheStepOfTheCardAndARefusedStepChangesNothing() throws {
        let inPlay = service(inPlay: 2)
        for title in ["A", "B", "C"] { try regularTopic(title, using: inPlay) }
        try server.run(["new-session", "-d", "-s", "notes", "-c", sessionPath.folder.path])
        _ = try change(inPlay.handle(EnvironmentRequest(.makeGuest, target: .sessionName("notes"))))
        XCTAssertEqual(try topicList(), ["A", "B", "lock:notes", "C"])

        let refused: [(CardMove, EnvironmentTarget, TopicFailure.Kind)] = [
            (.up, .topic(.named("A")), .cardAtEnd),
            (.down, .topic(.named("C")), .cardAtEnd),
            (.up, .sessionName("notes"), .cardGuest),
        ]
        for (direction, target, kind) in refused {
            let refusal = try failure(inPlay.handle(EnvironmentRequest(.moveCard(direction), target: target)))
            XCTAssertEqual(refusal.kind, kind, "\(direction) \(target)")
            XCTAssertEqual(refusal.phase, .nothingChanged)
        }
        XCTAssertEqual(try topicList(), ["A", "B", "lock:notes", "C"], "a refused step changes nothing")

        _ = try change(move(.down, "B", using: inPlay))
        XCTAssertEqual(try topicList(), ["A", "_", "B", "lock:notes", "C"], "Down from the last place makes the top Guest and leaves an Open Place")
        XCTAssertEqual(try guests(), ["B"])
        _ = try change(move(.up, "B", using: inPlay))
        XCTAssertEqual(try topicList(), ["A", "B", "lock:notes", "C"], "Up from the top Guest fills the Open Place")
        XCTAssertEqual(try guests(), [])
    }

    func testMoveUpOnAnUnlockedSessionLocksItAsTheLastGuestAndDownRefuses() throws {
        let wide = service(inPlay: 3)
        for title in ["A", "B", "C"] { try regularTopic(title, using: wide) }
        try server.run(["new-session", "-d", "-s", "notes", "-c", sessionPath.folder.path])
        let notes = EnvironmentRequest(.moveCard(.down), target: .sessionName("notes"))
        let down = try failure(wide.handle(notes))
        XCTAssertEqual(down.kind, .cardHidden)
        XCTAssertTrue(down.message.contains("Make it a Guest first: muxify topic make-guest --session"), down.message)

        XCTAssertFalse(try server.snapshot().windows.contains { $0.sessionName == "notes" && $0.lockOrder != nil })
        _ = try change(wide.handle(EnvironmentRequest(.moveSession(to: .up), target: .sessionName("notes"))))
        XCTAssertEqual(try topicList(), ["A", "B", "C", "lock:notes"], "Up on an unlocked Session is Make a Guest")
        XCTAssertTrue(try server.snapshot().windows.contains { $0.sessionName == "notes" && $0.lockOrder != nil })
    }

    func testTheSidebarDragPutsAnInPlayCardNextToAnOpenPlace() throws {
        let inPlay = service(inPlay: 3)
        for title in ["A", "B", "C", "D"] { try regularTopic(title, using: inPlay) }
        _ = try change(inPlay.handle(EnvironmentRequest(.benchTopic, target: .topic(.named("B")))))
        XCTAssertEqual(try topicList(), ["A", "_", "C", "B", "D"])
        let open = try XCTUnwrap(TopicStore(paths: paths).read().openPlaces.first).id

        _ = try change(inPlay.handle(EnvironmentRequest(.moveCard(.after(.openPlace(open))), target: .topic(.named("A")))))
        XCTAssertEqual(try topicList(), ["_", "A", "C", "B", "D"], "A goes down past the Open Place, and the Bench does not change")
    }

    func testPinOfACardInAPlaceLeavesAnOpenPlaceAndUnpinPutsItAtTheTopOfTheBench() throws {
        let inPlay = service(inPlay: 2)
        for title in ["A", "B", "C", "D"] { try regularTopic(title, using: inPlay) }
        _ = try change(inPlay.handle(EnvironmentRequest(.makeGuest, target: .topic(.named("C")))))
        XCTAssertEqual(try topicList(), ["A", "B", "C", "D"])

        _ = try change(inPlay.handle(EnvironmentRequest(.pin, target: .topic(.named("A")))))
        XCTAssertEqual(try topicList(), ["A", "_", "B", "C", "D"], "D does not move up")
        _ = try change(inPlay.handle(EnvironmentRequest(.unpin, target: .topic(.named("A")))))
        XCTAssertEqual(try topicList(), ["_", "B", "C", "A", "D"], "with in_play, Unpin puts the Topic at the top of the Bench")
    }

    func testTheUpgradeGatherPutsTheLocksAtTheEndOfInPlayAndASecondGatherWritesNothing() throws {
        for title in ["A", "B", "C"] { try regularTopic(title, using: service()) }
        try server.run(["new-session", "-d", "-s", "notes", "-c", sessionPath.folder.path])
        _ = try change(service().handle(EnvironmentRequest(.makeGuest, target: .sessionName("notes"))))
        _ = try change(service().handle(EnvironmentRequest(.moveCard(.before(.topic(.named("A")))), target: .sessionName("notes"))))
        XCTAssertEqual(try topicList(), ["lock:notes", "A", "B", "C"])

        XCTAssertNil(service(inPlay: 2).gatherGuests())
        XCTAssertEqual(try topicList(), ["A", "B", "lock:notes", "C"])
        let observer = TopicStore(paths: paths)
        let token = observer.changeToken()
        XCTAssertNil(service(inPlay: 2).gatherGuests())
        XCTAssertEqual(observer.changeToken(), token, "a second gather writes nothing")
    }
}

/// Sessions, Windows and Panes moved into, out of and among Topics.
final class TopicServiceSessionTests: TopicServiceTestCase {
    func testMoveTakesAWholeSessionIntoTheTopicThatARefNames() throws {
        try server.run(["new-session", "-d", "-s", "loose", "-c", sessionPath.folder.path])
        let topic = try XCTUnwrap(change(service().handle(EnvironmentRequest(.create(title: "Release")))).topicID)
        let loose = try XCTUnwrap(try server.snapshot().windows.first { $0.sessionName == "loose" })
        let moved = try change(service().handle(EnvironmentRequest(.move(to: .topic(.named("Release"))),
                                                             target: .session(SessionID(rawValue: loose.sessionID)!))))
        XCTAssertEqual(moved.shown, .window(WindowID(rawValue: loose.id)!))
        let window = try XCTUnwrap(try server.snapshot().windows.first { $0.id == loose.id })
        XCTAssertEqual(window.topicID, topic)
        XCTAssertEqual(window.sessionName, "loose/release")
        let again = try change(service().handle(EnvironmentRequest(.move(to: .topic(.id(topic))), target: .session(SessionID(rawValue: loose.sessionID)!))))
        XCTAssertNil(again.topicID, "a second move changes nothing")
    }

    func testMovingASessionKeepsTheTopicsSessionsInThatOrderAndSortingByCreationLetsThemGo() throws {
        let id = try twoSessionPathTopic("Order")
        let live = try server.snapshot().windows.filter { $0.topicID == id }
        let game = try XCTUnwrap(live.first { $0.sessionName == "game/order" }), tools = try XCTUnwrap(live.first { $0.sessionName == "tools/order" })
        let paths = { try XCTUnwrap(self.records().first { $0.id == id }).sessions.compactMap { $0["directory"]?.string }.map(Folder.local) }
        _ = try change(service().handle(EnvironmentRequest(.moveSession(to: .before(SessionID(rawValue: game.sessionID)!)),
                                                     target: .session(SessionID(rawValue: tools.sessionID)!))))
        XCTAssertEqual(try paths(), [tools.sessionPath, game.sessionPath].map(Folder.local))
        XCTAssertEqual(try records().first { $0.id == id }?.hasManualSessionOrder, true)

        _ = try change(service().handle(EnvironmentRequest(.sortSessions, target: .topic(.id(id)))))
        XCTAssertEqual(try records().first { $0.id == id }?.hasManualSessionOrder, false)
        let missing = try failure(service().handle(EnvironmentRequest(.moveSession(to: .after(SessionID(rawValue: "$999")!)),
                                                                target: .session(SessionID(rawValue: tools.sessionID)!))))
        XCTAssertEqual(missing.kind, .sourceUnavailable)
        XCTAssertEqual(missing.phase, .nothingChanged)
    }

    func testSessionMoveUpAndDownStepsAmongTheTopicsSessionsAndMovesALockedSessionsCard() throws {
        let id = try twoSessionPathTopic("Steps")
        _ = try change(service().handle(EnvironmentRequest(.benchTopic, target: .topic(.id(id)))))
        let live = try server.snapshot().windows.filter { $0.topicID == id }
        let game = try XCTUnwrap(live.first { $0.sessionName == "game/steps" }), tools = try XCTUnwrap(live.first { $0.sessionName == "tools/steps" })
        let paths = { try XCTUnwrap(self.records().first { $0.id == id }).sessions.compactMap { $0["directory"]?.string }.map(Folder.local) }
        func step(_ placement: TopicSessionPlacement, _ target: EnvironmentTarget) -> EnvironmentResponse {
            service().handle(EnvironmentRequest(.moveSession(to: placement), target: target))
        }
        XCTAssertEqual(try paths(), [game.sessionPath, tools.sessionPath].map(Folder.local))

        _ = try change(step(.up, .sessionName("tools/steps")))
        XCTAssertEqual(try paths(), [tools.sessionPath, game.sessionPath].map(Folder.local))
        XCTAssertEqual(try records().first { $0.id == id }?.hasManualSessionOrder, true)
        for (placement, name) in [(TopicSessionPlacement.up, "tools/steps"), (.down, "game/steps")] {
            let atEnd = try failure(step(placement, .sessionName(name)))
            XCTAssertEqual(atEnd.kind, .sessionAtEnd, name)
            XCTAssertEqual(atEnd.phase, .nothingChanged)
            XCTAssertTrue(atEnd.message.hasPrefix("The Session \(name) is the \(placement == .up ? "first" : "last") Session of the Topic Steps."), atEnd.message)
        }
        XCTAssertEqual(try paths(), [tools.sessionPath, game.sessionPath].map(Folder.local), "a failed step changes nothing")

        try server.run(["new-session", "-d", "-s", "notes", "-c", sessionPath.folder.path])
        _ = try change(service().handle(EnvironmentRequest(.makeGuest, target: .sessionName("notes"))))
        try server.run(["new-session", "-d", "-s", "chores", "-c", sessionPath.folder.path])
        _ = try change(service().handle(EnvironmentRequest(.makeGuest, target: .sessionName("chores"))))
        XCTAssertEqual(try topicList(), ["Steps", "lock:notes", "lock:chores"])
        let chores = try XCTUnwrap(try server.snapshot().windows.first { $0.sessionName == "chores" }?.sessionID)
        XCTAssertEqual(try change(step(.up, .sessionName("chores"))).session, SessionID(rawValue: chores))
        XCTAssertEqual(try topicList(), ["Steps", "lock:chores", "lock:notes"], "a Guest Session's card steps among the Guests")
        XCTAssertEqual(try failure(step(.up, .sessionName("chores"))).kind, .cardGuest, "a Guest Session takes no In Play place")
    }

    func testNewTopicFromPaneMovesThePanesWindowIntoANewUntitledTopic() throws {
        try server.run(["new-session", "-d", "-s", "loose", "-c", sessionPath.folder.path])
        let windowID = try server.run(["new-window", "-d", "-P", "-F", "#{window_id}", "-t", "=loose:", "-c", sessionPath.folder.path])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let paneID = try server.run(["display-message", "-p", "-t", windowID, "#{pane_id}"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let moved = try change(service().handle(EnvironmentRequest(.move(to: .newTopic(title: "")), target: .pane(try XCTUnwrap(PaneID(rawValue: paneID))))))
        let record = try XCTUnwrap(records().first)
        XCTAssertEqual(moved.topicID, record.id)
        XCTAssertTrue(moved.created)
        XCTAssertNil(record.title)
        XCTAssertEqual(record.sessions.first?["directory"]?.string.map(Folder.local), sessionPath.folder)
        XCTAssertEqual(moved.shown, WindowID(rawValue: windowID).map { .window($0) })
        let topicWindows = try server.snapshot().windows.filter { $0.topicID == record.id }
        XCTAssertEqual(topicWindows.map(\.id), [windowID], "the new Session holds only the moved Window")
        XCTAssertEqual(topicWindows.first?.sessionName, "loose/" + (record.slug ?? ""))
        XCTAssertEqual(try server.snapshot().windows.filter { $0.sessionName == "loose" }.count, 1, "the other Window stays")
    }

    func testMovePaneToExistingOrNewTopicKeepsItsProcessAndOtherPanes() throws {
        for existing in [false, true] {
            for split in [false, true] {
                let suffix = "\(existing)-\(split)"
                try server.run(["new-session", "-d", "-s", "source-" + suffix, "-c", sessionPath.folder.path])
                let source = try XCTUnwrap(try server.snapshot().windows.first { $0.sessionName == "source-" + suffix })
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
                    expectedTopic = try topicWithSession(suffix, at: sessionPath.folder.path, using: service())
                    previousWindow = try server.snapshot().windows.first { $0.topicID == expectedTopic }?.id
                    destination = .topic(.id(expectedTopic!))
                } else {
                    destination = .newTopic(title: suffix)
                }
                try assertThrowawayServer()
                let moved = try change(service().handle(EnvironmentRequest(.move(to: destination), target: .pane(try XCTUnwrap(PaneID(rawValue: pane))))))
                let result = try server.snapshot()
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

    func testMoveToANewTopicAcceptsATitleAndKeepsThePane() throws {
        let pane = try server.run(["display-message", "-p", "-t", "=main:", "#{pane_id}"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try assertThrowawayServer()
        let moved = try change(service().handle(EnvironmentRequest(.move(to: .newTopic(title: " Named work ")),
                                                                 target: .pane(try XCTUnwrap(PaneID(rawValue: pane))))))
        XCTAssertEqual(try records().first { $0.id == moved.topicID }?.title, "Named work")
        XCTAssertTrue(try server.snapshot().panes.contains { $0.id == pane })
    }

    func testMovePaneToNewWindowStaysInItsSessionAndSetsTheTitle() throws {
        let source = try XCTUnwrap(try server.snapshot().windows.first { $0.sessionName == "main" })
        let pane = try server.run(["split-window", "-d", "-P", "-F", "#{pane_id}", "-t", source.id])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let target = EnvironmentTarget.pane(try XCTUnwrap(PaneID(rawValue: pane)))
        let moved = try change(service().handle(EnvironmentRequest(.move(to: .newWindow(title: " Notes ")), target: target)))
        let result = try server.snapshot()
        let movedPane = try XCTUnwrap(result.panes.first { $0.id == pane })
        let window = try XCTUnwrap(result.windows.first { $0.id == movedPane.windowID })
        XCTAssertEqual(window.sessionID, source.sessionID)
        XCTAssertEqual(window.name, "Notes")
        XCTAssertNotEqual(window.id, source.id)
        XCTAssertEqual(result.windows.first { $0.id == source.id }?.paneCount, 1)
        XCTAssertEqual(moved.shown, .window(try XCTUnwrap(WindowID(rawValue: window.id))))
        XCTAssertTrue(try records().isEmpty)
        let again = try change(service().handle(EnvironmentRequest(.move(to: .newWindow(title: "Renamed")), target: target)))
        XCTAssertEqual(again.shown, moved.shown)
        XCTAssertEqual(try server.snapshot().windows.count, result.windows.count)
        XCTAssertEqual(try server.snapshot().windows.first { $0.id == window.id }?.name, "Renamed")
    }

    func testRemoveWindowFromTopicKeepsItsPanesAndSiblingWindowInTheTopic() throws {
        for existing in [false, true] {
            let id = try topicWithSession("Remove-\(existing)", at: sessionPath.folder.path, using: service())
            let source = try XCTUnwrap(try server.snapshot().windows.first { $0.topicID == id })
            let sibling = try server.run(["new-window", "-d", "-P", "-F", "#{window_id}", "-t", source.sessionID + ":", "-c", sessionPath.folder.path])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let pane = try server.run(["split-window", "-d", "-P", "-F", "#{pane_id}", "-t", source.id])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let before = try server.snapshot()
            let destination = before.windows.first { $0.topicID == nil && $0.sessionName == sessionPath.name }
            XCTAssertEqual(destination != nil, existing)
            let record = try XCTUnwrap(records().first { $0.id == id })
            try assertThrowawayServer()
            let target = EnvironmentTarget.window(try XCTUnwrap(WindowID(rawValue: source.id)))
            let to: TopicDestination = destination.map { .session(SessionID(rawValue: $0.sessionID)!) } ?? .newSession(topic: nil)
            let removed = try change(service().handle(EnvironmentRequest(.move(to: to), target: target)))
            let result = try server.snapshot()
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

    func testRemovingTheOnlySessionLeavesTheTopicEmptyAndTheSessionLive() throws {
        let id = try topicWithSession("Only", at: sessionPath.folder.path, using: service())
        let session = try XCTUnwrap(try server.snapshot().windows.first { $0.topicID == id })
        try assertThrowawayServer()
        _ = try change(service().handle(EnvironmentRequest(.removeFromTopic, target: .session(try XCTUnwrap(SessionID(rawValue: session.sessionID))))))
        try assertEmpty(id)
        XCTAssertEqual(try records().first { $0.id == id }?.title, "Only")
        XCTAssertTrue(try server.snapshot().windows.contains { $0.sessionID == session.sessionID && $0.topicID == nil })
    }

    func testRemovingTheLastWindowLeavesTheTopicEmpty() throws {
        let id = try topicWithSession("Last window", at: sessionPath.folder.path, using: service())
        let window = try XCTUnwrap(try server.snapshot().windows.first { $0.topicID == id })
        try assertThrowawayServer()
        _ = try change(service().handle(EnvironmentRequest(.move(to: .newSession(topic: nil)), target: .window(try XCTUnwrap(WindowID(rawValue: window.id))))))
        try assertEmpty(id)
        XCTAssertNil(try server.snapshot().windows.first { $0.id == window.id }?.topicID)
    }

    func testMovingTheOnlySessionLeavesTheSourceEmptyAndTheDestinationRemembersIt() throws {
        let source = try topicWithSession("From", at: sessionPath.folder.path, using: service())
        let destination = try XCTUnwrap(change(service().handle(EnvironmentRequest(.create(title: "To")))).topicID)
        let session = try XCTUnwrap(try server.snapshot().windows.first { $0.topicID == source })
        try assertThrowawayServer()
        _ = try change(service().handle(EnvironmentRequest(.move(to: .topic(.id(destination))),
                                                     target: .session(try XCTUnwrap(SessionID(rawValue: session.sessionID))))))
        try assertEmpty(source)
        XCTAssertEqual(try records().first { $0.id == destination }?.sessions.compactMap { $0["directory"]?.string }, [sessionPath.folder.path])
        XCTAssertEqual(try server.snapshot().windows.first { $0.sessionID == session.sessionID }?.topicID, destination)
    }

    func testRemovingOneOfTwoSessionsForgetsItInTheSameEdit() throws {
        let id = try topicWithSession("Two", at: sessionPath.folder.path, using: service())
        _ = try change(service().handle(EnvironmentRequest(.addSession(sessionPath: tools.folder.path, workingCopy: .directory), target: .topic(.id(id)))))
        let session = try XCTUnwrap(try server.snapshot().windows.first { $0.topicID == id && $0.sessionName.hasPrefix(tools.name + "/") })
        try assertThrowawayServer()
        _ = try change(service().handle(EnvironmentRequest(.removeFromTopic, target: .session(try XCTUnwrap(SessionID(rawValue: session.sessionID))))))
        XCTAssertEqual(try records().first { $0.id == id }?.sessions.compactMap { $0["directory"]?.string }, [sessionPath.folder.path])
    }

    func testRemoveAndKillStopsTheOnlySessionAndShowsTheEmptyTopic() throws {
        let id = try topicWithSession("Stop", at: sessionPath.folder.path, using: service())
        let session = try XCTUnwrap(try server.snapshot().windows.first { $0.topicID == id })
        try assertThrowawayServer()
        let removed = try change(service().handle(EnvironmentRequest(.removeAndKill(worktrees: []),
                                                               target: .session(try XCTUnwrap(SessionID(rawValue: session.sessionID))))))
        try assertEmpty(id)
        XCTAssertFalse(try server.snapshot().windows.contains { $0.sessionID == session.sessionID })
        XCTAssertEqual(removed.shown, .emptyTopic(.topic(id)))
    }

    func testRemoveAndKillOfOneOfTwoSessionsShowsTheOtherSession() throws {
        let id = try topicWithSession("Stop one", at: sessionPath.folder.path, using: service())
        _ = try change(service().handle(EnvironmentRequest(.addSession(sessionPath: tools.folder.path, workingCopy: .directory), target: .topic(.id(id)))))
        let windows = try server.snapshot().windows.filter { $0.topicID == id }
        let killed = try XCTUnwrap(windows.first { $0.sessionName.hasPrefix(tools.name + "/") })
        let other = try XCTUnwrap(windows.first { $0.sessionID != killed.sessionID })
        try assertThrowawayServer()
        let removed = try change(service().handle(EnvironmentRequest(.removeAndKill(worktrees: []),
                                                               target: .session(try XCTUnwrap(SessionID(rawValue: killed.sessionID))))))
        XCTAssertFalse(try server.snapshot().windows.contains { $0.sessionID == killed.sessionID })
        XCTAssertEqual(try records().first { $0.id == id }?.sessions.compactMap { $0["directory"]?.string }, [sessionPath.folder.path])
        XCTAssertEqual(removed.shown, .window(try XCTUnwrap(WindowID(rawValue: other.id))))
    }

    func testNewWindowGoesToTheTargetsSessionAndAnswersWithItsIds() throws {
        let id = try topicWithSession("Windows", at: sessionPath.folder.path, using: service())
        let before = try XCTUnwrap(try server.snapshot().windows.first { $0.topicID == id })
        let made = try change(service().handle(EnvironmentRequest(.newWindow(command: ["sh", "-c", "echo made > made.txt; sleep 600"]),
                                                                  target: .topic(.id(id)))))
        let window = try XCTUnwrap(try server.snapshot().windows.first { $0.id == made.window?.rawValue })
        XCTAssertEqual(window.sessionID, before.sessionID, "the Window is in the Topic's only Session")
        XCTAssertEqual(made.session?.rawValue, before.sessionID)
        XCTAssertNil(made.topicID, "a new Window writes no Topic record")
        let file = (sessionPath.folder.path as NSString).appendingPathComponent("made.txt")
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: file), Date() < deadline { usleep(50_000) }
        XCTAssertEqual(try String(contentsOfFile: file, encoding: .utf8), "made\n", "the command runs in the folder of the Session's Window")

        let beside = try change(service().handle(EnvironmentRequest(.newWindow(command: nil), target: .window(WindowID(rawValue: window.id)!))))
        XCTAssertEqual(beside.session?.rawValue, before.sessionID)
    }

    func testNewWindowInATopicWithNoneOrSeveralLiveSessionsFailsAndChangesNothing() throws {
        let empty = try XCTUnwrap(change(service().handle(EnvironmentRequest(.create(title: "Nothing yet")))).topicID)
        let windows = try server.snapshot().windows.count
        let none = try failure(service().handle(EnvironmentRequest(.newWindow(command: nil), target: .topic(.id(empty)))))
        XCTAssertEqual(none.kind, .topicEmpty)
        XCTAssertEqual(none.message, "The Topic Nothing yet has no Session. Add one first: muxify topic add-session <dir> --topic \(empty).")
        let two = try topicWithSession("Two places", at: sessionPath.folder.path, using: service())
        _ = try change(service().handle(EnvironmentRequest(.addSession(sessionPath: tools.folder.path, workingCopy: .directory), target: .topic(.id(two)))))
        let several = try failure(service().handle(EnvironmentRequest(.newWindow(command: nil), target: .topic(.id(two)))))
        XCTAssertEqual(several.kind, .chooseSession)
        XCTAssertTrue(several.message.contains("game/two-places ($") && several.message.contains("tools/two-places ($"), several.message)
        XCTAssertEqual(several.phase, .nothingChanged)
        XCTAssertEqual(try server.snapshot().windows.count, windows + 2, "only the two Sessions of the second Topic were made")
    }

    func testNewSessionStartsANoTopicSessionNamedForItsSessionPathWithAFreeName() throws {
        let first = try change(service().handle(EnvironmentRequest(.newSession(sessionPath: sessionPath.folder.path, name: nil))))
        let second = try change(service().handle(EnvironmentRequest(.newSession(sessionPath: sessionPath.folder.path, name: nil))))
        let named = try change(service().handle(EnvironmentRequest(.newSession(sessionPath: tools.folder.path, name: "debug"))))
        XCTAssertEqual([first.sessionName, second.sessionName, named.sessionName], ["game", "game+2", "debug"])
        XCTAssertNil(first.topicID)
        let window = try XCTUnwrap(try server.snapshot().windows.first { $0.sessionID == named.session?.rawValue })
        XCTAssertEqual(window.id, named.window?.rawValue)
        XCTAssertNil(window.topicID)
        XCTAssertEqual(window.sessionPath, tools.folder.path)
        let invalid = try failure(service().handle(EnvironmentRequest(.newSession(sessionPath: tools.folder.path, name: "a.b"))))
        XCTAssertEqual(invalid.kind, .sessionNameInvalid)
        XCTAssertEqual(invalid.phase, .nothingChanged)
        XCTAssertEqual(try failure(service().handle(EnvironmentRequest(.newSession(sessionPath: "/nowhere", name: nil)))).kind, .sessionPathUnavailable)
    }

    func testRenameSessionKeepsTheTopicSlugAndAFreeNameAndRenameWindowRenamesIt() throws {
        let id = try topicWithSession("Slugged", at: sessionPath.folder.path, using: service())
        let window = try XCTUnwrap(try server.snapshot().windows.first { $0.topicID == id })
        let session = try XCTUnwrap(SessionID(rawValue: window.sessionID))
        try server.run(["new-session", "-d", "-s", "taken/slugged", "-c", root.path])
        let renamed = try change(service().handle(EnvironmentRequest(.renameSession(name: "taken"), target: .session(session))))
        XCTAssertEqual(renamed.sessionName, "taken+2/slugged")
        XCTAssertEqual(renamed.session, session)
        XCTAssertEqual(try server.snapshot().windows.first { $0.sessionID == window.sessionID }?.sessionName, "taken+2/slugged")
        let invalid = try failure(service().handle(EnvironmentRequest(.renameSession(name: "a:b"), target: .session(session))))
        XCTAssertEqual(invalid.kind, .sessionNameInvalid)

        let windowID = try XCTUnwrap(WindowID(rawValue: window.id))
        let logs = try change(service().handle(EnvironmentRequest(.renameWindow(name: "logs"), target: .window(windowID))))
        XCTAssertEqual(logs.window, windowID)
        XCTAssertEqual(try server.snapshot().windows.first { $0.id == window.id }?.name, "logs")
    }

    func testZoomPaneZoomsThePaneAndASecondZoomEndsIt() throws {
        try server.run(["new-session", "-d", "-s", "zoom", "-c", sessionPath.folder.path, ";", "split-window", "-d", "-t", "zoom:"])
        let second = try server.run(["list-panes", "-t", "zoom:", "-F", "#{pane_id}"]).split(separator: "\n").map(String.init)[1]
        func state() throws -> String {
            try server.run(["display-message", "-p", "-t", "zoom:", "#{window_id} #{window_zoomed_flag} #{pane_id}"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let window = try state().split(separator: " ")[0]
        func zoom() throws -> TopicChange {
            try change(service().handle(EnvironmentRequest(.zoomPane, target: .pane(PaneID(rawValue: second)!))))
        }

        XCTAssertEqual(try zoom().window?.rawValue, String(window))
        XCTAssertEqual(try state(), "\(window) 1 \(second)", "the target Pane fills its Window")
        _ = try zoom()
        XCTAssertEqual(try state(), "\(window) 0 \(second)", "a second Zoom ends it")
    }

    func testMoveWindowPutsAWindowBeforeOrAfterAnotherWindowOfItsSessionAndKeepsTheCurrentWindow() throws {
        func ids(_ session: String) throws -> [String] {
            try server.run(["list-windows", "-t", session, "-F", "#{window_id}"]).split(separator: "\n").map(String.init)
        }
        try server.run(["new-session", "-d", "-s", "order", "-c", sessionPath.folder.path])
        try server.run(["new-window", "-d", "-t", "order:", ";", "new-window", "-d", "-t", "order:"])
        try server.run(["new-session", "-d", "-s", "other", "-c", sessionPath.folder.path])
        let original = try ids("order"), other = try ids("other")[0]
        let (a, b, c) = (original[0], original[1], original[2])
        let current = try server.run(["display-message", "-p", "-t", "order:", "#{window_id}"]).trimmingCharacters(in: .whitespacesAndNewlines)
        func move(_ window: String, _ placement: WindowPlacement) -> EnvironmentResponse {
            service().handle(EnvironmentRequest(.moveWindow(to: placement), target: .window(WindowID(rawValue: window)!)))
        }

        XCTAssertEqual(try change(move(c, .before(WindowID(rawValue: a)!))).window, WindowID(rawValue: c))
        XCTAssertEqual(try ids("order"), [c, a, b])
        _ = try change(move(c, .after(WindowID(rawValue: b)!)))
        XCTAssertEqual(try ids("order"), [a, b, c])
        _ = try change(move(a, .after(WindowID(rawValue: a)!)))
        XCTAssertEqual(try ids("order"), [a, b, c], "a Window next to itself stays")

        let elsewhere = try failure(move(a, .before(WindowID(rawValue: other)!)))
        XCTAssertEqual(elsewhere.kind, .windowNotInSession)
        XCTAssertEqual(elsewhere.phase, .nothingChanged)
        XCTAssertTrue(elsewhere.message.hasPrefix("The Window \(other) is not in the Session of the Window \(a)."), elsewhere.message)
        XCTAssertEqual(try failure(move(a, .before(WindowID(rawValue: "@999")!))).kind, .windowNotInSession)
        XCTAssertEqual(try ids("order"), [a, b, c], "a failed move changes nothing")
        XCTAssertEqual(try ids("other"), [other])
        XCTAssertEqual(try server.run(["display-message", "-p", "-t", "order:", "#{window_id}"]).trimmingCharacters(in: .whitespacesAndNewlines), current,
                       "the Session keeps its current Window")
    }
}

/// The test's tmux server, which runs `during` once, when a request first reads tmux: after it read the records, before
/// it plans and writes.
private final class Interleaving: TmuxRunning, @unchecked Sendable {
    private let server: TmuxServer
    private let lock = NSLock()
    private var during: (() -> Void)?

    init(server: TmuxServer, during: @escaping () -> Void) {
        self.server = server
        self.during = during
    }

    func run(_ arguments: [String]) throws -> String { try server.run(arguments) }

    func snapshot() throws -> TmuxSnapshot {
        lock.lock()
        let once = during
        during = nil
        lock.unlock()
        once?()
        return try server.snapshot()
    }
}

private final class Responses: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [EnvironmentResponse] = []
    var all: [EnvironmentResponse] { lock.lock(); defer { lock.unlock() }; return values }
    func append(_ response: EnvironmentResponse) { lock.lock(); values.append(response); lock.unlock() }
}
