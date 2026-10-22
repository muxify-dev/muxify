import XCTest
@testable import MuxifyCore

final class NewTopicTests: XCTestCase {
    private let sessionPath = SessionPath(path: "/work/game", name: "game")

    func testSlugifyUsesWordsAndHandlesEmptyAndLongWords() {
        XCTAssertEqual(TopicNaming.slugify("Fix reward drop bug in GS!"), "fix-reward-drop-bug-in-gs")
        XCTAssertEqual(TopicNaming.slugify("  Café___LINKS / Fix  "), "cafe-links-fix")
        XCTAssertEqual(TopicNaming.slugify("This title has far too many words for a Session"), "this-title-has-far-too-many")
        XCTAssertEqual(TopicNaming.slugify(String(repeating: "A", count: 40)), String(repeating: "a", count: 28))
        XCTAssertEqual(TopicNaming.slugify("🚀 !!"), "topic")
    }

    func testUntitledUsesSmallestFreeNumberAndNamedSlugsAvoidOpenTopicsAndSessions() {
        let records = [TopicRecord(id: "one", slug: "untitled-1"), TopicRecord(id: "three", slug: "untitled-3")]
        XCTAssertEqual(TopicNaming.slug(title: "  ", records: records), "untitled-2")
        XCTAssertEqual(TopicNaming.slug(title: "", records: records), "untitled-2")
        var settled = TopicRecord(id: "settled", slug: "fix-links")
        settled.settledAt = "2026-10-06T00:00:00Z"
        XCTAssertEqual(TopicNaming.slug(title: "Fix links", records: [settled]), "fix-links-2")
        let open = TopicRecord(id: "open", slug: "fix-links")
        XCTAssertEqual(TopicNaming.slug(title: "Fix links", records: [open]), "fix-links-2")
    }

    func testSessionPathOrderUsesScoreThenLastVisitThenConfigOrderAndTypingWins() {
        let sessionPaths = ["alpha", "bravo", "charlie", "delta"].map { SessionPath(path: "/" + $0, name: $0) }
        func window(_ directory: String) -> TmuxWindow {
            TmuxWindow(id: "@1", sessionID: "$1", sessionName: "s", index: 0, name: "shell", paneTitle: "", path: directory + "/src",
                       command: "zsh", isActive: true, paneCount: 1, hasBell: false, sessionActivity: 0, agent: "",
                       storedBrowser: StoredBrowser(), openRequests: [], topicID: nil, sessionPath: directory)
        }
        var visits = VisitLog()
        _ = visits.record(window("/bravo"), group: .noTopic, sessionPaths: sessionPaths, folders: .local, at: Date(timeIntervalSince1970: 10))
        _ = visits.record(window("/charlie"), group: .noTopic, sessionPaths: sessionPaths, folders: .local, at: Date(timeIntervalSince1970: 20))
        func order(_ query: String, visits: VisitLog = visits) -> [String] {
            SessionPathRows.list(SessionPathRows.build(sessionPaths: sessionPaths, windows: [window("/delta")], records: [], titles: [:]),
                             query: query, visits: visits).rows.map(\.title.text)
        }
        XCTAssertEqual(order(""), ["charlie", "bravo", "alpha", "delta"], "last visit, then Config order; a live Session does not rank")
        XCTAssertEqual(order("", visits: VisitLog()), ["alpha", "bravo", "charlie", "delta"])
        XCTAssertEqual(order("alp"), ["alpha"])
        XCTAssertTrue(order("unmatched").isEmpty)
        XCTAssertEqual(order("brv").first, "bravo")
        let byDirectory = SessionPathRows.list(SessionPathRows.build(sessionPaths: [sessionPath], windows: [], records: [], titles: [:]),
                                           query: "work", visits: VisitLog())
        XCTAssertEqual(byDirectory.rows.compactMap { $0.pick.payload?.sessionPath }, [sessionPath], "the directory matches too")
        XCTAssertEqual(byDirectory.rows.first?.detail, Highlighted(text: "/work/game", marks: [1, 2, 3, 4]))
        XCTAssertEqual(SessionPath.containing(.local("/alpha/subdir"), in: sessionPaths), sessionPaths[0])
        XCTAssertNil(SessionPath.containing(.local("/alphabet"), in: sessionPaths))
    }

    func testNewTopicPlanWritesRecordAndExactCommands() {
        var previous = TopicRecord(id: "previous", title: "Earlier")
        previous.order = -4
        let plan = TopicPlan(title: "Fix links", sessionPath: sessionPath, records: [previous],
                             sessionNames: [], id: "new", now: Date(timeIntervalSince1970: 0), clientTTY: "/dev/ttys001")
        XCTAssertEqual(plan.sessionName, "game/fix-links")
        XCTAssertEqual(plan.record.title, "Fix links")
        XCTAssertEqual(plan.record.sessions.first?["directory"], .string("/work/game"))
        XCTAssertNil(plan.record.order)
        XCTAssertEqual(plan.record.createdAt, "1970-01-01T00:00:00Z")
        let savedID = plan.record.sessions.first?["id"]?.string ?? ""
        XCTAssertFalse(savedID.isEmpty)
        XCTAssertEqual(plan.commands, [
            .tmux(["new-session", "-d", "-s", "game/fix-links", "-c", "/work/game"]),
            .tmux(["set-option", "-t", "=game/fix-links:", "@muxify_topic", "new"]),
            .tmux(["set-option", "-t", "=game/fix-links:", "@muxify_session_id", savedID]),
            .tmux(["switch-client", "-c", "/dev/ttys001", "-t", "=game/fix-links:"]),
        ])
    }

    func testKeysAreTypedAsTheTerminalClientOrAsNoClient() {
        XCTAssertEqual(Tmux.sendKeysArguments(target: "=game/fix-links:", keys: ["printf 'hello world'"], literal: true, client: "/dev/ttys001"),
                       ["send-keys", "-c", "/dev/ttys001", "-l", "-t", "=game/fix-links:", "--", "printf 'hello world'"])
        XCTAssertEqual(Tmux.sendKeysArguments(target: "=game/fix-links:", keys: ["Enter"], literal: false, client: nil),
                       ["send-keys", "-c", "", "-t", "=game/fix-links:", "Enter"])
    }

    func testUntitledPlanOpensTheSessionAsUntitled() {
        let plan = TopicPlan(title: " \n ", sessionPath: sessionPath, records: [], sessionNames: [], id: "untitled")
        XCTAssertNil(plan.record.title)
        XCTAssertEqual(Array(plan.commands.prefix(2)), [
            ["new-session", "-d", "-s", "game/untitled-1", "-c", "/work/game"],
            ["set-option", "-t", "=game/untitled-1:", "@muxify_topic", "untitled"],
        ].map(TopicPlan.Command.tmux))
    }

    func testNewTopicHasNoSessionUntilOneIsAdded() throws {
        var previous = TopicRecord(id: "previous", slug: "fix-links")
        previous.order = 2
        let slug = TopicNaming.slug(title: "Fix links", records: [previous])
        let topic = TopicRecord(newTopic: "new", title: "Fix links", slug: slug, now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(topic.slug, "fix-links-2", "an open Topic already uses the slug")
        XCTAssertEqual(topic.title, "Fix links")
        XCTAssertEqual(topic.sessions, [])
        XCTAssertNil(topic.order)
        XCTAssertEqual(topic.createdAt, "1970-01-01T00:00:00Z")

        let added = try TopicSessionPlan(topic: topic, sessionPath: sessionPath, workingCopy: .directory, windows: [], sessionPaths: [sessionPath]).edit
        XCTAssertEqual(added.record?.sessions.first?["directory"], .string("/work/game"))
        XCTAssertEqual(added.commands.first, .tmux(["new-session", "-d", "-s", "game/fix-links-2", "-c", "/work/game"]))
        XCTAssertEqual(added.selection, .sessionName("game/fix-links-2"))
    }

    func testAnEmptyTopicTheUserLooksAtIsTheActiveTopicUntilItHasAWindow() {
        var config = Config()
        config.sessionPaths = [sessionPath]
        let topic = TopicRecord(newTopic: "empty", title: "Plan", slug: "plan", now: Date())
        func window(topic: String?) -> TmuxWindow {
            TmuxWindow(id: "@1", sessionID: "$1", sessionName: "game", index: 0, name: "shell", paneTitle: "", path: "/work/game",
                       command: "zsh", isActive: true, paneCount: 1, hasBell: false, sessionActivity: 0, agent: "",
                       storedBrowser: StoredBrowser(), openRequests: [], topicID: topic, sessionPath: "/work/game")
        }
        var selection = TopicSelection()
        selection.windowID = "@1"
        selection.emptyTopicID = "empty"
        let shown = TopicsModel(records: [topic], windows: [window(topic: nil)], config: config, selection: selection)
        XCTAssertEqual(shown.activeTopic, .topic("empty"))
        XCTAssertEqual(shown.emptyTopic?.title, "Plan")
        let started = TopicsModel(records: [topic], windows: [window(topic: "empty")], config: config, selection: selection)
        XCTAssertNil(started.emptyTopic, "a Topic with a Window is no longer empty")
        XCTAssertEqual(started.activeTopic, .topic("empty"))
        var snoozed = topic
        snoozed.snoozedUntil = "never"
        let shownSnoozed = TopicsModel(records: [snoozed], windows: [window(topic: nil)], config: config, selection: selection)
        XCTAssertEqual(shownSnoozed.emptyTopic?.title, "Plan", "a Snoozed empty Topic the user goes to stays shown")
        XCTAssertEqual(shownSnoozed.activeTopic, .topic("empty"))
        var settled = topic
        settled.settledAt = "2026-10-01T00:00:00Z"
        let shownSettled = TopicsModel(records: [settled], windows: [window(topic: nil)], config: config, selection: selection)
        XCTAssertEqual(shownSettled.emptyTopic?.title, "Plan", "a Settled Topic the user goes to shows its Reopen choice")
        XCTAssertEqual(shownSettled.activeTopic, .topic("empty"))
        let gone = TopicsModel(records: [], windows: [window(topic: nil)], config: config, selection: selection)
        XCTAssertNil(gone.emptyTopic)
        XCTAssertEqual(gone.activeTopic, .noTopic)
    }

    func testReopeningATopicWithNoSessionShowsItAndOnlyASettledOneMoves() throws {
        let open = TopicRecord(newTopic: "empty", title: "Plan", slug: "plan", now: Date())
        let shown = try TopicReopenPlan(topic: open, records: [open], windows: [], sessionPaths: [sessionPath], existingDirectories: []).edit
        XCTAssertEqual(shown.commands, [])
        XCTAssertEqual(shown.selection, .emptyTopic("empty"))
        XCTAssertNil(shown.record)
        XCTAssertNil(shown.completion, "an open Topic keeps its place in the list")

        var settled = open
        settled.settledAt = "2026-10-01T00:00:00Z"
        var first = TopicRecord(id: "first", slug: "other")
        first.order = 0
        let reopened = try TopicReopenPlan(topic: settled, records: [first, settled], windows: [], sessionPaths: [sessionPath],
                                           existingDirectories: []).edit
        XCTAssertEqual(reopened.selection, .emptyTopic("empty"))
        guard case .save(let record)? = reopened.completion else {
            return XCTFail("Reopen must save the Topic")
        }
        XCTAssertNil(record.settledAt)
        XCTAssertNil(record.order)
    }

    func testTopicsUseConfiguredSessionPathLabel() {
        let window = TmuxWindow(id: "@1", sessionID: "$1", sessionName: "renamed", index: 0,
                                name: "shell", paneTitle: "", path: "/elsewhere", command: "zsh",
                                isActive: true, paneCount: 1, hasBell: false, sessionActivity: 0, agent: "",
                                storedBrowser: StoredBrowser(), openRequests: [], topicID: "topic", sessionPath: "/work/game")
        var config = Config()
        config.sessionPaths = [SessionPath(path: "/work/game", name: "work/game")]
        let model = TopicsModel(records: [TopicRecord(id: "topic", title: "Fix")],
                                windows: [window], config: config, selection: TopicSelection())
        XCTAssertEqual(model.rows.first?.sessions.first?.baseName, "renamed")
    }
}
