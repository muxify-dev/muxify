import XCTest
@testable import MuxifyCore
import MuxifyTestSupport

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

    func testKeysAreTypedAsTheTerminalClientOrAsNoClient() {
        XCTAssertEqual(Tmux.sendKeysArguments(target: "=game/fix-links:", keys: ["printf 'hello world'"], literal: true, client: "/dev/ttys001"),
                       ["send-keys", "-c", "/dev/ttys001", "-l", "-t", "=game/fix-links:", "--", "printf 'hello world'"])
        XCTAssertEqual(Tmux.sendKeysArguments(target: "=game/fix-links:", keys: ["Enter"], literal: false, client: nil),
                       ["send-keys", "-c", "", "-t", "=game/fix-links:", "Enter"])
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
        XCTAssertEqual(added.commands.first, .tmuxMaking(["new-session", "-d", "-s", "game/fix-links-2", "-c", "/work/game"]))
        XCTAssertEqual(added.selection, .sessionName("game/fix-links-2"))
    }

    func testTheActiveTopicComesFromTheLocation() {
        var config = Config()
        config.sessionPaths = [sessionPath]
        let topic = TopicRecord(newTopic: "empty", title: "Plan", slug: "plan", now: Date())
        func window(topic: String?) -> TmuxWindow {
            .fixture(sessionName: "game", path: "/work/game", topicID: topic, sessionPath: "/work/game")
        }
        var selection = TopicSelection()
        selection.windowID = "@1"
        let page = Location.emptyTopic(.topic("empty"))
        let shown = TopicsModel(records: [topic], windows: [window(topic: nil)], config: config, selection: selection, location: page)
        XCTAssertEqual(shown.activeTopic, .topic("empty"))
        XCTAssertEqual(shown.emptyTopic?.title, "Plan")
        let waiting = TopicsModel(records: [topic], windows: [window(topic: "empty")], config: config,
                                  selection: selection, location: page)
        XCTAssertEqual(waiting.activeTopic, .topic("empty"), "the Location keeps the Active Topic when a Window appears")
        XCTAssertNotNil(waiting.emptyTopic, "only a Location change leaves the page")
        let started = TopicsModel(records: [topic], windows: [window(topic: "empty")], config: config, selection: selection,
                        location: .window(WindowID(rawValue: "@1")!))
        XCTAssertNil(started.emptyTopic, "a Topic with a Window is no longer empty")
        XCTAssertEqual(started.activeTopic, .topic("empty"))
        var settled = topic
        settled.settledAt = "2026-10-01T00:00:00Z"
        let shownSettled = TopicsModel(records: [settled], windows: [window(topic: nil)], config: config, selection: selection, location: page)
        XCTAssertEqual(shownSettled.emptyTopic?.title, "Plan", "a Settled Topic the user goes to shows its Reopen choice")
        XCTAssertEqual(shownSettled.activeTopic, .topic("empty"))
        let gone = TopicsModel(records: [], windows: [window(topic: nil)], config: config, selection: selection,
                        location: .window(WindowID(rawValue: "@1")!))
        XCTAssertNil(gone.emptyTopic)
        XCTAssertEqual(gone.activeTopic, .noTopic)
    }
}
