import AppKit
import SwiftUI
import XCTest
@testable import MuxifyCore

final class GitViewConfigTests: XCTestCase {
    private let root = "/cfg/muxify/config.yaml"

    private func load(_ text: String) throws -> Config {
        try Config.load(path: root, fontFamilies: { [] }) { $0 == self.root ? text : nil }.get()
    }

    private func trigger(_ string: String) -> KeyTrigger {
        try! KeyTrigger(string)
    }

    func testDefaultsAreAnEightyPercentPopupOnCommandG() throws {
        let config = try load("")
        XCTAssertEqual(config.gitView, GitViewConfig(display: .popup, width: 0.8, height: 0.8))
        XCTAssertEqual(config.keybinds.action(for: trigger("cmd+g")), .toggleGitView)
        XCTAssertEqual(config.problems, [])
    }

    func testDisplayAndSizeAcceptPercentagesOrBareNumbers() throws {
        let config = try load("""
        git_view:
          display: fullscreen
          width: 90%
          height: 65
        """)
        XCTAssertEqual(config.gitView, GitViewConfig(display: .fullscreen, width: 0.9, height: 0.65))
        XCTAssertEqual(config.problems, [])
    }

    func testInvalidValuesKeepTheirDefaultsAndAreProblems() throws {
        let config = try load("""
        git_view:
          display: sideways
          width: 5%
          height: 120%
          theme: dark
        """)
        XCTAssertEqual(config.gitView, GitViewConfig())
        XCTAssertEqual(config.problems.map(\.line), [2, 3, 4, 5])
        XCTAssertEqual(config.problems.first?.message, "git_view.display: expected popup or fullscreen")
        XCTAssertEqual(config.problems.last?.message, "unknown key \"git_view.theme\"")
    }

    func testTheKeybindingCanBeRemappedOrDisabled() throws {
        let remapped = try load("keybindings:\n  toggle_git_view: [ctrl+g, cmd+shift+g]")
        XCTAssertEqual(remapped.keybinds.firstTrigger(for: .toggleGitView), trigger("ctrl+g"))
        XCTAssertEqual(remapped.keybinds.action(for: trigger("cmd+shift+g")), .toggleGitView)
        XCTAssertNil(remapped.keybinds.action(for: trigger("cmd+g")))
        let disabled = try load("keybindings:\n  toggle_git_view: []")
        XCTAssertNil(disabled.keybinds.firstTrigger(for: .toggleGitView))
    }

    func testTheGitViewTheTemplateShowsIsTheDefault() throws {
        let shown = Config.template.split(separator: "\n").filter { line in
            line.hasPrefix("# git_view:") || line.hasPrefix("#   display:") || line.hasPrefix("#   width:")
                || line.hasPrefix("#   height:")
        }.map { $0.dropFirst(2) }
        XCTAssertEqual(shown.count, 4)
        let config = try load(shown.joined(separator: "\n"))
        XCTAssertEqual(config.gitView, GitViewConfig())
        XCTAssertEqual(config.problems, [])
    }
}

final class GitRepositoryParsingTests: XCTestCase {
    func testStatusReadsTheUpstreamAndRenames() {
        let output = ["## main...origin/main [ahead 2, behind 1]", "M  staged.swift", " M unstaged.swift",
                      "R  new.swift", "old.swift", "?? notes.txt", ""].joined(separator: "\0")
        let status = GitRepository.parseStatus(output)
        XCTAssertEqual(status.upstream, "origin/main")
        XCTAssertEqual(status.ahead, 2)
        XCTAssertEqual(status.behind, 1)
        XCTAssertEqual(status.changes, [
            GitChange(index: "M", worktree: " ", path: "staged.swift"),
            GitChange(index: " ", worktree: "M", path: "unstaged.swift"),
            GitChange(index: "R", worktree: " ", path: "new.swift", originalPath: "old.swift"),
            GitChange(index: "?", worktree: "?", path: "notes.txt"),
        ])
        XCTAssertTrue(status.changes[3].isUntracked)
        XCTAssertEqual(status.changes[3].groups, [.untracked])
    }

    func testStatusWithoutCommitsOrUpstream() {
        let status = GitRepository.parseStatus("## No commits yet on main\0")
        XCTAssertNil(status.upstream)
        XCTAssertEqual(status.changes, [])
    }

    func testCommitsAreColoredByWhereTheyAre() {
        let line = { (sha: String, refs: String, parents: String) in
            [sha, "Yauhen Karatkou", "1700000000", refs, parents, "Subject"].joined(separator: "\0")
        }
        let output = [line("aaaaaaaa1", "HEAD -> refs/heads/feature", "p1"),
                      line("bbbbbbbb2", "tag: refs/tags/v1, refs/remotes/origin/feature, refs/remotes/origin/HEAD", "p1 p2"),
                      line("cccccccc3", "", "p1")].joined(separator: "\n")
        let commits = GitRepository.parseCommits(output, unpushed: ["aaaaaaaa1"], unmerged: ["aaaaaaaa1", "bbbbbbbb2"])
        XCTAssertEqual(commits.map(\.status), [.unpushed, .pushed, .merged])
        XCTAssertEqual(commits[0].refs, ["feature"])
        XCTAssertEqual(commits[1].tags, ["v1"])
        XCTAssertEqual(commits[1].remotes, ["origin/feature"])
        XCTAssertEqual(commits[1].parents, ["p1", "p2"])
        XCTAssertTrue(commits[1].isMerge)
        XCTAssertEqual(commits[0].initials, "YK")
        XCTAssertEqual(commits[0].shortSHA, "aaaaaaaa")
        // Without an upstream, everything not in the main branch is unpushed.
        let local = GitRepository.parseCommits(output, unpushed: nil, unmerged: ["aaaaaaaa1"])
        XCTAssertEqual(local.map(\.status), [.unpushed, .merged, .merged])
    }

    func testAChangeHasLazygitsLettersAndBothSidesLineCounts() {
        let changes = [GitChange(index: "M", worktree: "M", path: "a.swift"), GitChange(index: "R", worktree: " ", path: "new.swift", originalPath: "old.swift"),
                       GitChange(index: "U", worktree: "U", path: "both.swift"), GitChange(index: "?", worktree: "?", path: "c.txt"),
                       GitChange(index: " ", worktree: "M", path: "img.png")]
        let counted = GitRepository.counted(changes, staged: ["a.swift": (1, 1), "new.swift": (0, 0)],
                                            unstaged: ["a.swift": (2, 0), "both.swift": (5, 3), "img.png": (nil, nil)], untracked: ["c.txt": 7])
        XCTAssertEqual(counted.map { "\($0.status) \($0.path) +\($0.additions ?? -1) -\($0.deletions ?? -1)" }, [
            "MM a.swift +3 -1", "R  new.swift +0 -0", "UU both.swift +5 -3", "?? c.txt +7 -0", " M img.png +-1 --1",
        ])
        XCTAssertEqual(counted.map(\.groups), [[.unstaged, .staged], [.staged], [.unstaged], [.untracked], [.unstaged]])
        XCTAssertEqual(counted.map(\.isStaged), [false, true, false, false, false])
        XCTAssertTrue(counted[2].isConflict)
        XCTAssertEqual(counted[1].originalPath, "old.swift")
        XCTAssertEqual(counted[0].id, "a.swift")
    }

    func testAChangesOutputIsSplitByGroup() {
        let parts = GitRepository.parseParts("\n\u{1E}unstaged\ndiff --git a/a b/a\n\n\u{1E}staged\n\n\u{1E}bogus\nx")
        XCTAssertEqual(parts.map(\.group), [.unstaged, .staged])
        XCTAssertEqual(parts[0].patch, "diff --git a/a b/a\n")
        XCTAssertEqual(parts[1].patch, "")
    }

    func testNumstatReadsRenamesAndBinaries() {
        let counts = GitRepository.parseNumstat("1\t2\ta.swift\0-\t-\timg.png\03\t0\t\0old.swift\0new.swift\0")
        XCTAssertEqual(counts["a.swift"]?.0, 1)
        XCTAssertEqual(counts["a.swift"]?.1, 2)
        XCTAssertNotNil(counts["img.png"])
        XCTAssertNil(counts["img.png"]?.0)
        XCTAssertEqual(counts["new.swift"]?.0, 3)
        XCTAssertNil(counts["old.swift"])
        XCTAssertEqual(GitRepository.parseLineCounts("      25 Sources/A.swift\n       3 b c.txt\n      28 total\n"),
                       ["Sources/A.swift": 25, "b c.txt": 3])
    }

    func testBranchesAreComparedWithHEAD() {
        let divergence = GitRepository.parseDivergence("master 2 14\nfeature 0\t3\n")
        XCTAssertEqual(divergence["master"]?.0, 2)
        XCTAssertEqual(divergence["feature"]?.1, 3)
        XCTAssertEqual(GitRepository.parseComparison("origin/master 1\t0\n"), GitComparison(base: "origin/master", ahead: 1, behind: 0))
        XCTAssertNil(GitRepository.parseComparison(""))
    }

    func testAgesUseLazygitUnits() {
        let now = Date(timeIntervalSince1970: 100_000_000)
        let seconds: [Double] = [5, 180, 7_200, 432_000, 1_209_600, 10_368_000, 94_608_000]
        let ages = seconds.map { GitRepository.age(of: now.addingTimeInterval(-$0), now: now) }
        XCTAssertEqual(ages, ["5s", "3m", "2h", "5d", "2w", "4M", "3y"])
    }
}

final class GitPatchTests: XCTestCase {
    private let diff = """
    diff --git a/Sources/Keys.swift b/Sources/Keys.swift
    index 54c5023..f121f3f 100644
    --- a/Sources/Keys.swift
    +++ b/Sources/Keys.swift
    @@ -16,4 +16,5 @@ enum ConfigAction: String {
         case toggleSidebar = "toggle_sidebar"
    -    case toggleBrowser = "browser"
    +    case toggleBrowser = "toggle_browser"
    +    case toggleGitView = "toggle_git_view"
         case focusTerminal = "focus_terminal"
    @@ -40 +41 @@
    -old
    +new
    \\ No newline at end of file
    diff --git a/docs/old name.md b/docs/new name.md
    similarity index 90%
    rename from docs/old name.md
    rename to docs/new name.md
    diff --git a/icon.png b/icon.png
    new file mode 100644
    Binary files /dev/null and b/icon.png differ
    """

    func testFilesHunksAndLineNumbers() throws {
        let patch = GitPatch.parse(diff)
        XCTAssertEqual(patch.files.map(\.path), ["Sources/Keys.swift", "docs/new name.md", "icon.png"])
        let file = patch.files[0]
        XCTAssertEqual(file.change, .modified)
        XCTAssertEqual(file.additions, 3)
        XCTAssertEqual(file.deletions, 2)
        XCTAssertEqual(file.hunks.map(\.header), ["@@ -16,4 +16,5 @@", "@@ -40 +41 @@"])
        XCTAssertEqual(file.hunks[0].context, "enum ConfigAction: String {")
        let lines = file.hunks[0].lines
        XCTAssertEqual(lines.map(\.kind), [.context, .removed, .added, .added, .context])
        XCTAssertEqual(lines.map(\.old), [16, 17, nil, nil, 18])
        XCTAssertEqual(lines.map(\.new), [16, nil, 17, 18, 19])
        XCTAssertEqual(lines[2].text, "    case toggleBrowser = \"toggle_browser\"")
        XCTAssertEqual(file.hunks[1].lines.map(\.kind), [.removed, .added, .note])
        XCTAssertEqual(patch.files[1].change, .renamed)
        XCTAssertEqual(patch.files[1].oldPath, "docs/old name.md")
        XCTAssertTrue(patch.files[2].isBinary)
        XCTAssertEqual(patch.files[2].change, .added)
        XCTAssertEqual(patch.additions, 3)
    }

    func testTabsAreShownAsSpacesAndCopiedAsTabs() {
        let line = GitDiffLine(kind: .added, old: nil, new: 1, text: "\tlet a\t= 1")
        XCTAssertEqual(line.shown, "    let a   = 1")
        XCTAssertEqual(line.text(in: 4..<9), "let a")
        XCTAssertEqual(line.text(in: 0..<10), "\tlet a\t")
        XCTAssertEqual(GitDiffLine(kind: .context, old: 1, new: 1, text: "plain").text(in: 1..<3), "la")
    }

    func testSplitPairsRemovedLinesWithTheAddedOnesAfterThem() {
        let hunk = GitPatch.parse(diff).files[0].hunks[0]
        let pairs = hunk.pairs.map { ($0.old?.text.trimmingCharacters(in: .whitespaces), $0.new?.text.trimmingCharacters(in: .whitespaces)) }
        XCTAssertEqual(pairs.map(\.0), ["case toggleSidebar = \"toggle_sidebar\"", "case toggleBrowser = \"browser\"", nil,
                                        "case focusTerminal = \"focus_terminal\""])
        XCTAssertEqual(pairs.map(\.1), ["case toggleSidebar = \"toggle_sidebar\"", "case toggleBrowser = \"toggle_browser\"",
                                        "case toggleGitView = \"toggle_git_view\"", "case focusTerminal = \"focus_terminal\""])
    }

    func testCombinedDiffsUseTheLastColumnForNewLines() {
        let patch = GitPatch.parse("diff --cc a.swift\nindex 1,2..3\n@@@ -1,2 -1,2 +1,3 @@@\n  a\n+ b\n -c\n")
        XCTAssertEqual(patch.files.first?.hunks.first?.lines.map(\.kind), [.context, .added, .removed])
        XCTAssertEqual(patch.files.first?.hunks.first?.lines.map(\.new), [1, 2, nil])
    }

    @MainActor
    func testDiffRowsForAChangeAndForACommit() {
        let patch = GitPatch.parse(diff)
        let change = GitChange(index: " ", worktree: "M", path: "Sources/Keys.swift")
        let single = GitView.Content(id: "a", header: .change(change), output: diff, patch: GitPatch(files: [patch.files[0]]), theme: nil)
        let kinds = GitView.diffRows(for: single, layout: .unified).map { String(describing: $0.kind).prefix(5) }
        XCTAssertEqual(kinds, ["hunk(", "line(", "line(", "line(", "line(", "line(", "hunk(", "line(", "line(", "line(", "whole", "endOf"])
        XCTAssertEqual(GitView.diffRows(for: single, layout: .split).count, 2 + 4 + 2 + 2)
        XCTAssertEqual(GitView.diffRows(for: single, layout: .unified, wholeFile: true).count, 11)
        let commit = GitCommit(sha: "abc", author: "A", date: Date(), tags: [], subject: "S")
        let multiple = GitView.Content(id: "b", header: .commit(commit, nil), output: diff, patch: patch, theme: nil)
        let rows = GitView.diffRows(for: multiple, layout: .unified)
        XCTAssertEqual(String(describing: rows[0].kind), "card")
        XCTAssertEqual(rows.filter { if case .file = $0.kind { true } else { false } }.count, 3)
        XCTAssertEqual(rows.map(\.id), Array(rows.indices))
        // Not "No newline at end of file".
        XCTAssertEqual(rows.filter(\.isLine).count, 7)
        XCTAssertEqual(rows.filter(\.isChange).count, 5)
    }

    @MainActor
    func testDiffFilesShowOneFileOrAFolderOfTheCommit() {
        let commit = GitCommit(sha: "abc", author: "A", date: Date(), tags: [], subject: "S")
        let content = GitView.Content(id: "b", header: .commit(commit, nil), output: diff, patch: GitPatch.parse(diff), theme: nil)
        let file = GitView.diffRows(for: content, layout: .unified, scope: .file("Sources/Keys.swift"))
        XCTAssertEqual(file.map { String(describing: $0.kind).prefix(5) }.first, "hunk(")
        XCTAssertEqual(String(describing: file.last!.kind), "endOfFile")
        XCTAssertFalse(file.contains { if case .wholeFile = $0.kind { true } else { false } })
        let folder = GitView.diffRows(for: content, layout: .unified, scope: .folder("docs"))
        XCTAssertEqual(folder.map { String(describing: $0.kind) }, ["file(1)"])
    }

    @MainActor
    func testAChangeWithStagedAndUnstagedLinesShowsBothParts() {
        let one = GitPatch.parse("diff --git a/a.swift b/a.swift\n@@ -1 +1 @@\n-a\n+b\n")
        let patch = GitPatch.joined([(.unstaged, one), (.staged, one)])
        XCTAssertEqual(patch.files.map(\.id), [0, 1])
        XCTAssertEqual(patch.files.map(\.group), [.unstaged, .staged])
        let change = GitChange(index: "M", worktree: "M", path: "a.swift")
        let content = GitView.Content(id: "a", header: .change(change), output: "", patch: patch, theme: nil)
        let kinds = GitView.diffRows(for: content, layout: .unified).map { String(describing: $0.kind).prefix(5) }
        XCTAssertEqual(kinds, ["part(", "hunk(", "line(", "line(", "part(", "hunk(", "line(", "line(", "whole", "endOf"])
    }
}

final class GitTreeAndGraphTests: XCTestCase {
    func testTheTreeListsFoldersFirstAndJoinsSingleFolders() {
        let paths = ["README.md", "Sources/Muxify/Git/GitView.swift", "Sources/Muxify/Git/GitTree.swift", "Sources/Muxify/UI/Panel.swift", "docs/a.md"]
        let nodes = GitTree.nodes(paths)
        XCTAssertEqual(nodes.map { "\(String(repeating: " ", count: $0.depth))\($0.name)" }, [
            "Sources/Muxify", " Git", "  GitTree.swift", "  GitView.swift", " UI", "  Panel.swift", "docs", " a.md", "README.md",
        ])
        XCTAssertEqual(nodes[0].path, "Sources/Muxify")
        XCTAssertNil(nodes[0].file)
        XCTAssertEqual(nodes[2].file, 2)
        let folded = GitTree.nodes(paths, collapsed: ["Sources/Muxify/Git"])
        XCTAssertEqual(folded.map(\.name), ["Sources/Muxify", "Git", "UI", "Panel.swift", "docs", "a.md", "README.md"])
    }

    private func commit(_ sha: String, _ parents: [String]) -> GitCommit {
        GitCommit(sha: sha, author: "A", date: Date(), tags: [], parents: parents, subject: sha)
    }

    func testTheGraphForksAndMergesLanes() {
        // M merges B into A; both come from C.
        let rows = GitGraphRow.layout([commit("M", ["A", "B"]), commit("A", ["C"]), commit("B", ["C"]), commit("C", [])])
        typealias Edge = GitGraphRow.Edge
        XCTAssertEqual(rows[0], GitGraphRow(lane: 0, color: 0, edges: [Edge(kind: .out, lane: 0, color: 0), Edge(kind: .out, lane: 1, color: 1)]))
        XCTAssertEqual(rows[1], GitGraphRow(lane: 0, color: 0, edges: [Edge(kind: .into, lane: 0, color: 0), Edge(kind: .through, lane: 1, color: 1),
                                                                         Edge(kind: .out, lane: 0, color: 0)]))
        // B joins A's lane where they meet at C.
        XCTAssertEqual(rows[2], GitGraphRow(lane: 1, color: 1, edges: [Edge(kind: .through, lane: 0, color: 0), Edge(kind: .into, lane: 1, color: 1),
                                                                         Edge(kind: .out, lane: 0, color: 0)]))
        XCTAssertEqual(rows[3], GitGraphRow(lane: 0, color: 0, edges: [Edge(kind: .into, lane: 0, color: 0)]))
        XCTAssertEqual(rows.map(\.width), [2, 2, 2, 1])
    }

    func testABranchTipStartsANewLane() {
        let rows = GitGraphRow.layout([commit("X", ["Y"]), commit("Z", ["Y"]), commit("Y", [])])
        XCTAssertEqual(rows[1].lane, 1)
        XCTAssertEqual(rows[1].color, 1)
        // Z curves into X's lane right away, as `git log --graph` draws `|/`.
        XCTAssertEqual(rows[1].edges, [GitGraphRow.Edge(kind: .through, lane: 0, color: 0), GitGraphRow.Edge(kind: .out, lane: 0, color: 0)])
        XCTAssertEqual(rows[2].edges.map(\.lane), [0])
    }

    func testTheLeftLaneGoesOnWhereTwoLanesMeet() {
        // B was merged into M; A, on the left, and B both come from C.
        let rows = GitGraphRow.layout([commit("M", ["A", "B"]), commit("B", ["C"]), commit("A", ["C"]), commit("C", [])])
        XCTAssertEqual(rows.map(\.lane), [0, 1, 0, 0])
        XCTAssertEqual(rows[3].edges.map(\.kind), [.into, .into])
        XCTAssertEqual(rows[3].edges.map(\.lane), [0, 1])
    }

    func testPanelsGetWhatTheyNeedAndShareTheRest() {
        // Two stashes need 80; after their minimum, Changes (focused) and History share the rest 2:1.
        let heights = GitView.panelHeights(wants: [500, nil, 80], weights: [2, 1, 1], minimum: 86, total: 680)
        XCTAssertEqual(heights.map { Int($0.rounded()) }, [371, 229, 80])
        XCTAssertEqual(GitView.panelHeights(wants: [100, nil], weights: [1, 2], minimum: 86, total: 600).map { Int($0.rounded()) }, [100, 500])
    }
}

final class GitHighlighterTests: XCTestCase {
    private let colors = GitColors(nil)

    func testSwiftTokens() {
        var state = SyntaxState()
        let line = Array("    let name = \"Muxify\" // greet".utf16)
        let tokens = SyntaxLanguage.swift.tokens(in: line, state: &state).map(\.token)
        XCTAssertEqual(tokens, [.keyword, .string, .comment])
    }

    func testBlockCommentsCarryOverLines() {
        var state = SyntaxState()
        _ = SyntaxLanguage.swift.tokens(in: Array("/* open".utf16), state: &state)
        let tokens = SyntaxLanguage.swift.tokens(in: Array("still */ return".utf16), state: &state)
        XCTAssertEqual(tokens.map(\.token), [.comment, .keyword])
        XCTAssertEqual(state, SyntaxState())
    }

    func testYAMLKeys() {
        var state = SyntaxState()
        let tokens = SyntaxLanguage.yaml.tokens(in: Array("  font-size: 12 # points".utf16), state: &state)
        XCTAssertEqual(tokens.map(\.token), [.key, .number, .comment])
    }

    func testPatchLinesGetTheThemesColors() throws {
        var patch = GitPatch.parse("diff --git a/a.swift b/a.swift\n--- a/a.swift\n+++ b/a.swift\n@@ -1 +1 @@ struct App\n-let old = 1\n+let new = \"two\"\n")
        GitHighlighter(colors: colors, fontSize: 12).highlight(&patch)
        let hunk = try XCTUnwrap(patch.files.first?.hunks.first)
        let added = try XCTUnwrap(hunk.lines[1].styled)
        XCTAssertEqual(added[try XCTUnwrap(added.range(of: "let"))].foregroundColor, Color(nsColor: colors.magenta))
        XCTAssertEqual(added[try XCTUnwrap(added.range(of: "\"two\""))].foregroundColor, Color(nsColor: colors.green))
        let context = try XCTUnwrap(hunk.styledContext)
        XCTAssertEqual(context[try XCTUnwrap(context.range(of: "App"))].foregroundColor, Color(nsColor: colors.yellow))
    }

    func testVeryLongPatchesAreCut() {
        let lines = (0..<(GitPatch.lineLimit + 5)).map { "+line \($0)" }.joined(separator: "\n")
        let patch = GitPatch.parse("diff --git a/a b/a\n@@ -0,0 +1,20005 @@\n" + lines)
        XCTAssertEqual(patch.omittedLines, 5)
        XCTAssertEqual(patch.additions, GitPatch.lineLimit)
    }
}

/// Runs the Git View's scripts against real repositories, with a private
/// HOME so the user's git config can't change the output.
final class GitScriptTests: XCTestCase {
    private var directory: TestDirectory!
    private var environment: [String: String] = [:]

    override func setUpWithError() throws {
        directory = try TestDirectory()
        environment = [
            "HOME": directory.url.path, "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_AUTHOR_NAME": "Yauhen Karatkou", "GIT_AUTHOR_EMAIL": "y@example.com",
            "GIT_COMMITTER_NAME": "Yauhen Karatkou", "GIT_COMMITTER_EMAIL": "y@example.com",
        ]
        try run("""
        cd "$1"
        git init -q -b master repo && cd repo
        printf 'let a = 1\\n' > a.swift
        git add a.swift && git commit -q -m First -m 'The body.'
        git tag v1
        git checkout -q -b feature
        printf 'let b = 2\\n' > b.swift
        git add b.swift && git commit -q -m 'Add b'
        git checkout -q master
        printf 'stashed\\n' >> a.swift && git stash push -q -m wip
        printf 'let a = 2\\n' > a.swift && git add a.swift && printf '// more\\n' >> a.swift
        printf 'hello\\nworld\\n' > c.txt
        git worktree add -q -b other ../linked
        """, directory.url.path)
    }

    @discardableResult
    private func run(_ script: String, _ arguments: String...) throws -> String {
        try CommandRunner().run(CommandInvocation(executable: "/bin/sh", arguments: ["-c", script, "muxify"] + arguments),
                                environment: environment)
    }

    private var repository: String { directory.url.appendingPathComponent("repo").path }

    func testTheSnapshotListsEverySection() throws {
        let snapshot = try GitRepository.parseSnapshot(run(GitRepository.snapshotScript, repository)).get()
        XCTAssertEqual(snapshot.repositoryName, "repo")
        XCTAssertNil(snapshot.worktreeName)
        XCTAssertEqual(snapshot.head, "master")
        XCTAssertEqual(snapshot.mainBranch, "master")
        XCTAssertEqual(snapshot.changes.map { "\($0.status) \($0.path) +\($0.additions ?? -1) -\($0.deletions ?? -1)" },
                       ["MM a.swift +2 -1", "?? c.txt +2 -0"])
        XCTAssertNil(snapshot.comparison)
        XCTAssertEqual(snapshot.branches.first?.name, "master")
        XCTAssertEqual(snapshot.branches.first?.isHead, true)
        XCTAssertEqual(Set(snapshot.branches.map(\.name)), ["master", "feature", "other"])
        let feature = try XCTUnwrap(snapshot.branches.first { $0.name == "feature" })
        XCTAssertEqual(feature.ahead, 1)
        XCTAssertEqual(feature.behind, 0)
        XCTAssertNotNil(snapshot.branches.first { $0.name == "other" }?.worktreePath)
        XCTAssertEqual(snapshot.commits.map(\.subject), ["First"])
        XCTAssertEqual(snapshot.commits.first?.tags, ["v1"])
        XCTAssertEqual(snapshot.commits.first?.refs, ["master", "other"])
        XCTAssertEqual(snapshot.graph, [GitGraphRow(lane: 0, color: 0)])
        XCTAssertEqual(snapshot.stashes.map(\.message), ["On master: wip"])
        XCTAssertEqual(snapshot.stashes.first?.ref, "stash@{0}")
    }

    func testALinkedWorktreeIsNamedAfterItsFolderAndComparedWithMain() throws {
        let linked = directory.url.appendingPathComponent("linked").path
        let snapshot = try GitRepository.parseSnapshot(run(GitRepository.snapshotScript, linked)).get()
        XCTAssertEqual(snapshot.repositoryName, "repo")
        XCTAssertEqual(snapshot.worktreeName, "linked")
        XCTAssertEqual(snapshot.head, "other")
        XCTAssertEqual(snapshot.comparison, GitComparison(base: "master", ahead: 0, behind: 0))
    }

    func testAFolderOutsideARepositoryIsNotAnError() throws {
        let result = GitRepository.parseSnapshot(try run(GitRepository.snapshotScript, directory.url.path))
        XCTAssertEqual(result, .failure(GitViewError(message: "Not a git repository: \(directory.url.path)")))
    }

    private func change(_ path: String, _ groups: String) throws -> GitPatch {
        let parts = GitRepository.parseParts(try run(GitRepository.changeScript, repository, path, "", "3", groups))
        return GitPatch.joined(parts.map { ($0.group, GitPatch.parse($0.patch)) })
    }

    func testAChangesUnstagedAndStagedDiffs() throws {
        let patch = try change("a.swift", "unstaged staged")
        XCTAssertEqual(patch.files.map(\.group), [.unstaged, .staged])
        XCTAssertEqual(patch.files[0].hunks.first?.lines.filter { $0.kind == .added }.map(\.text), ["// more"])
        XCTAssertEqual(patch.files[1].hunks.first?.lines.map(\.text), ["let a = 1", "let a = 2"])
        let untracked = try change("c.txt", "untracked")
        XCTAssertEqual(untracked.files.first?.change, .added)
        XCTAssertEqual(untracked.files.first?.additions, 2)
    }

    func testAFoldersChangesIncludeEachUntrackedFile() throws {
        try run("cd \"$1\" && mkdir -p sub/deep && printf 'd\\n' > sub/d.txt && printf 'e\\n' > sub/deep/e.txt", repository)
        let patch = try change("sub", "unstaged untracked")
        XCTAssertEqual(patch.files.map(\.path), ["sub/d.txt", "sub/deep/e.txt"])
        XCTAssertEqual(patch.files.map(\.group), [.untracked, .untracked])
        XCTAssertEqual(try change("nothing", "untracked").files, [])
    }

    func testABranchIsComparedWithTheCurrentOne() throws {
        let detail = GitRepository.parseBranchDetail(try run(GitRepository.branchScript, repository, "HEAD", "feature"))
        XCTAssertEqual(detail.commits.map(\.subject), ["Add b"])
        XCTAssertEqual(GitPatch.parse(detail.patch).files.map(\.path), ["b.swift"])
    }

    func testACommitHasItsMessageAndParents() throws {
        let root = GitRepository.parseCommitDetail(try run(GitRepository.commitScript, repository, "v1"))
        XCTAssertEqual(root.detail?.title, "First")
        XCTAssertEqual(root.detail?.body, "The body.")
        XCTAssertEqual(root.detail?.parents, [])
        XCTAssertEqual(GitPatch.parse(root.patch).files.first?.hunks.first?.lines.map(\.text), ["let a = 1"])
        let child = GitRepository.parseCommitDetail(try run(GitRepository.commitScript, repository, "feature"))
        XCTAssertEqual(child.detail?.parents.count, 1)
        XCTAssertEqual(child.detail?.author, "Yauhen Karatkou")
    }

    func testAStashIsShownWithGit() throws {
        let stash = try run(GitRepository.gitScript, repository, "stash", "show", "--patch", "--no-color", "stash@{0}")
        XCTAssertEqual(GitPatch.parse(stash).files.first?.hunks.first?.lines.last?.text, "stashed")
    }
}

@MainActor
final class GitViewKeysTests: XCTestCase {
    private func command(_ characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags = []) throws -> GitView.Command? {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                                   windowNumber: 0, context: nil, characters: characters,
                                                   charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
        return KeyTrigger(event).flatMap { GitView.commands[$0] }
    }

    func testLazygitKeys() throws {
        XCTAssertEqual(try command("j", keyCode: 0x26), .down)
        XCTAssertEqual(try command("J", keyCode: 0x26, flags: .shift), .scroll(lines: 3))
        XCTAssertEqual(try command("<", keyCode: 0x2B, flags: .shift), .top)
        XCTAssertEqual(try command("1", keyCode: 0x12), .status)
        XCTAssertEqual(try command("3", keyCode: 0x14), .panel(.branches))
        XCTAssertEqual(try command("4", keyCode: 0x15), .panel(.history))
        XCTAssertEqual(try command("\u{4}", keyCode: 0x02, flags: .control), .halfPage(1))
        XCTAssertEqual(try command("\t", keyCode: 0x30), .nextPanel)
        XCTAssertEqual(try command("\u{19}", keyCode: 0x30, flags: .shift), .previousPanel)
        XCTAssertEqual(try command("v", keyCode: 0x09), .range)
        XCTAssertEqual(try command("c", keyCode: 0x08, flags: .command), .copy)
        XCTAssertEqual(try command("-", keyCode: 0x1B), .collapseAll)
        XCTAssertEqual(try command("\u{1B}", keyCode: 0x35), .back)
        XCTAssertEqual(try command("\u{F701}", keyCode: 0x7D, flags: .option), .nextHunk)
        XCTAssertEqual(try command("]", keyCode: 0x1E), .nextFile)
        XCTAssertEqual(try command("/", keyCode: 0x2C), .filter)
        // ⌘G goes on to toggle_git_view, ⌘B to the Browser.
        XCTAssertNil(try command("g", keyCode: 0x05, flags: .command))
        XCTAssertNil(try command("b", keyCode: 0x0B, flags: .command))
    }
}
