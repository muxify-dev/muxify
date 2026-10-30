import XCTest
@testable import MuxifyCore

/// New Worktree and Remove Worktree in the palette's view (ADR 0062).
@MainActor
final class PaletteWorktreeTests: XCTestCase {
    private func store() -> WorkspaceStore {
        WorkspaceStore(configStore: ConfigStore(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("muxify-palette-worktree-\(UUID().uuidString).yaml").path))
    }

    private func summary(sessions: [String] = [], state: MuxifyWorktrees.State = .clean) -> MuxifyWorktreeSummary {
        MuxifyWorktreeSummary(record: MuxifyWorktreeRecord(id: "w1", environment: nil, repository: "/work/game", name: "fix",
                                                           path: "/trees/game/fix", branch: "fix", base: "abc"),
                              state: state, sessions: sessions, topic: nil)
    }

    func testEachCommandMirrorsItsWorktreeVerb() {
        XCTAssertEqual(PaletteCommand.newWorktree.mirror, .verb(.worktreeCreate))
        XCTAssertEqual(PaletteCommand.removeWorktree.mirror, .verb(.worktreeRemove))
    }

    func testARowOfTheListOpensTheConfirmStepOfItsWorktree() {
        let store = store()
        let draft = RemoveWorktreeDraft()
        draft.rows = .ready([summary()])
        store.palette.begin(.removeWorktree(draft))
        let rows = store.palette.flowResults(.removeWorktree(draft)).rows
        XCTAssertEqual(rows.map(\.kind), [.muxifyWorktree])
        XCTAssertEqual(rows.first?.pick.payload?.ref, .choice(.muxifyWorktree("w1")))
        store.palette.accept(.muxifyWorktree("w1"))
        guard case .confirm(let confirmation)? = store.palette.flow, case .removeWorktree(let worktree) = confirmation.target else {
            return XCTFail("\(String(describing: store.palette.flow))")
        }
        XCTAssertEqual(worktree.id, "w1")
    }

    func testRemovingAWorktreeThatASessionUsesNeedsCommandReturnAndForceIsARowThatToggles() {
        XCTAssertFalse(PaletteConfirmation(.removeWorktree(summary())).requiresCommandReturn, "↩ removes an unused Worktree")
        XCTAssertTrue(PaletteConfirmation(.removeWorktree(summary(sessions: ["game/fix"]))).requiresCommandReturn,
                      "⌘↩ stops the Sessions that use it")
        let store = store()
        let confirmation = PaletteConfirmation(.removeWorktree(summary(sessions: ["game/fix"], state: .dirty)))
        store.palette.begin(.confirm(confirmation))
        let rows = store.palette.flowResults(.confirm(confirmation)).rows
        XCTAssertEqual(rows.map(\.id), ["remove-folder", "session-game/fix", "force"])
        XCTAssertEqual(rows.last?.trailing, "Off")
        store.palette.accept(.force)
        XCTAssertTrue(confirmation.force)
        XCTAssertEqual(store.palette.flowResults(.confirm(confirmation)).rows.last?.trailing, "On")
    }

    func testTheNameStepGoesOnToTheStartStepOfANewWorktree() {
        let store = store()
        let game = SessionPath(path: "/work/game", name: "game", layout: .plainRepository([Worktree(path: "/work/game", branch: "main")]))
        let choice = SessionChoice(sessionPath: game, worktree: game.layout.worktrees[0])
        store.palette.begin(.text(.worktreeName(choice)))
        XCTAssertFalse(store.palette.canAccept, "a Worktree needs a name")
        store.palette.query = " fix "
        store.palette.accept(.accept)
        guard case .worktreeStart(let draft)? = store.palette.flow, case .newWorktree(let name) = draft.purpose else {
            return XCTFail("\(String(describing: store.palette.flow))")
        }
        XCTAssertEqual(name, "fix")
        XCTAssertEqual(store.palette.breadcrumb, "New Worktree › game › fix from")
    }

    func testStartsListEachLocalBranchWithTheWorktreeThatHasItCheckedOut() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let work = Folder.local(root.path).real + "/work"
        func git(_ arguments: [String]) throws {
            _ = try Shell.run("/usr/bin/git", ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgSign=false"]
                              + arguments, directory: root.path)
        }
        try git(["init", "-q", "-b", "main", work])
        try git(["-C", work, "commit", "-q", "--allow-empty", "-m", "init"])
        try git(["-C", work, "branch", "feature"])
        let starts = try WorktreeStartChoice.read(from: work, scripts: LocalScripts())
        XCTAssertEqual(Set(starts.map(\.branch)), ["main", "feature"])
        XCTAssertEqual(starts.first { $0.branch == "main" }?.checkedOutAt, work)
        XCTAssertNil(starts.first { $0.branch == "feature" }?.checkedOutAt)
    }
}
