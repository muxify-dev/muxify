import XCTest
@testable import MuxifyCore
import MuxifyTestSupport

final class PaneCommandLinesTests: XCTestCase {
    private func snapshot(_ command: String, topic: String? = "topic") -> TmuxSnapshot {
        let window = TmuxWindow.fixture(sessionName: "game", name: "dev", command: command, topicID: topic)
        let pane = TmuxPane(id: "%1", windowID: "@1", command: command, agent: "", agentStatus: "", unread: false, tty: "/dev/pts/4")
        return TmuxSnapshot(windows: [window], clients: [], panes: [pane], serverRunning: true)
    }

    func testPsRunsOnlyWhenATopicPaneStartsAnotherProgram() {
        var reads = 0
        let ps = { () -> String? in
            reads += 1
            return "  41   41 pts/4    make watch\n  42   41 pts/4    sh -c build\n  43   43 pts/5    vim notes\n"
        }
        let first = PaneCommandLines().updating(for: snapshot("make"), ps: ps)
        XCTAssertEqual(first[snapshot("make").panes[0]], "make watch")
        let same = first.updating(for: snapshot("make"), ps: ps)
        XCTAssertEqual(same[snapshot("make").panes[0]], "make watch")
        XCTAssertEqual(reads, 1, "the same program is not read again")

        XCTAssertNil(same[snapshot("vim").panes[0]], "a line read for another program is stale")
        _ = same.updating(for: snapshot("vim"), ps: ps)
        XCTAssertEqual(reads, 2)

        _ = PaneCommandLines().updating(for: snapshot("zsh"), ps: ps)
        _ = PaneCommandLines().updating(for: snapshot("make", topic: nil), ps: ps)
        XCTAssertEqual(reads, 2, "a shell, or a Pane outside every Topic, needs no ps")
    }
}
