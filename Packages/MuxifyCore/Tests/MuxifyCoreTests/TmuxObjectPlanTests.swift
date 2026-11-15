import XCTest
@testable import MuxifyCore
import MuxifyTestSupport

final class TmuxObjectPlanTests: XCTestCase {
    private func window(_ id: String, session: String, name: String, topic: String?, active: Bool = true, created: Int = 0) -> TmuxWindow {
        .fixture(id: id, sessionID: session, sessionName: name, name: "w", path: "/work/" + name, isActive: active, topicID: topic,
                 sessionCreated: created)
    }

    func testANewWindowGoesToTheTopicsOnlyLiveSessionAndNeverChoosesOrMakesOne() {
        var topic = TopicRecord(id: "t", title: "Fix")
        let one = [window("@1", session: "$1", name: "gs/fix", topic: "t"), window("@2", session: "$2", name: "other", topic: nil)]
        XCTAssertEqual(TmuxObjectPlan.place(in: topic, windows: one, order: .oldestFirst), .session(one[0]))
        let two = one + [window("@3", session: "$3", name: "muxify/fix", topic: "t", created: 5)]
        XCTAssertEqual(TmuxObjectPlan.place(in: topic, windows: two, order: .oldestFirst), .chooseSession(["gs/fix ($1)", "muxify/fix ($3)"]))
        XCTAssertEqual(TmuxObjectPlan.place(in: topic, windows: one.filter { $0.topicID == nil }, order: .oldestFirst), .emptyTopic(dormant: false))
        topic.sessions = [.object(["id": .string("s1"), "name": .string("gs/fix")])]
        XCTAssertEqual(TmuxObjectPlan.place(in: topic, windows: [], order: .oldestFirst), .emptyTopic(dormant: true))
    }

    func testACommandGoesToTmuxAsOneShellLineWithEachWordQuotedWhereTheShellWouldSplitIt() {
        XCTAssertEqual(TmuxObjectPlan.shellCommand(["claude", "Read /tmp/x.md"]), "claude 'Read /tmp/x.md'")
        XCTAssertEqual(TmuxObjectPlan.shellCommand(["echo", "it's", "$HOME", ""]), #"echo 'it'\''s' '$HOME' ''"#)
        XCTAssertEqual(TmuxObjectPlan.shellCommand(["make", "-j8", "a=b/c.d"]), "make -j8 a=b/c.d")
    }
}
