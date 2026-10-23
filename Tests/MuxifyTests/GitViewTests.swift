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

    func testTheEditorCommandNamesTheFileAndMayNameTheLine() throws {
        let config = try load("git_view:\n  editor: hx {file}:{line}")
        XCTAssertEqual(config.gitView.editor, "hx {file}:{line}")
        XCTAssertEqual(config.problems, [])
        XCTAssertNil(try load("").gitView.editor)
        let invalid = try load("git_view:\n  editor: nvim +{line}\n  display: popup")
        XCTAssertNil(invalid.gitView.editor)
        XCTAssertEqual(invalid.problems.map(\.line), [2])
        XCTAssertEqual(invalid.problems.first?.message, "git_view.editor: expected a command with {file}, and {line} if it takes one")
        XCTAssertNotNil(try load("git_view:\n  editor: \"\"").problems.first)
    }

    func testTheEditorCommandQuotesTheFileAndFillsTheLine() {
        let custom = GitViewConfig(editor: "nvim +{line} {file} # {line}")
        XCTAssertEqual(custom.editorCommand(file: "/r/a b.swift", line: 12), "nvim +12 '/r/a b.swift' # 12")
        // A file name is data: neither its quotes nor a placeholder in it is read again.
        XCTAssertEqual(custom.editorCommand(file: "/r/it's {line}", line: 3), "nvim +3 '/r/it'\"'\"'s {line}' # 3")
        XCTAssertEqual(GitViewConfig(editor: "hx {file}:{line} {other}").editorCommand(file: "/r/a", line: 0), "hx '/r/a':1 {other}")
        XCTAssertEqual(GitViewConfig().editorCommand(file: "/r/a b", line: 7), "${VISUAL:-${EDITOR:-vi}} +7 '/r/a b'")
        XCTAssertEqual(GitViewConfig(editor: "code -g {file}:{line}").editorShellCommand(file: "/r/a", line: 2),
                       "sh -c 'code -g '\"'\"'/r/a'\"'\"':2'")
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

    func testARemovedLineOpensAtTheNewLineBesideIt() throws {
        let file = try XCTUnwrap(GitPatch.parse(diff).files.first)
        // context 16, removed, added 17, added 18, context 19
        XCTAssertEqual(file.hunks[0].newLine(at: 0), 16)
        XCTAssertEqual(file.hunks[0].newLine(at: 1), 17)
        XCTAssertEqual(file.hunks[0].newLine(at: 3), 18)
        XCTAssertEqual(file.firstChangedLine, 17)
        // A run of removed lines at the end of a hunk takes the last line before it.
        let tail = try XCTUnwrap(GitPatch.parse("diff --git a/t b/t\n--- a/t\n+++ b/t\n@@ -5,3 +5,1 @@\n keep\n-gone\n-gone too\n").files.first)
        XCTAssertEqual(tail.hunks[0].newLine(at: 2), 5)
        XCTAssertEqual(tail.firstChangedLine, 5)
        // All removed: the hunk's start.
        let removed = try XCTUnwrap(GitPatch.parse("diff --git a/t b/t\n--- a/t\n+++ b/t\n@@ -1,2 +0,0 @@\n-a\n-b\n").files.first)
        XCTAssertEqual(removed.firstChangedLine, 1)
        XCTAssertEqual(GitPatch.parse(diff).files[2].firstChangedLine, 1)
    }

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

    func testAPatchOfPickedLinesLeavesTheRestAsTheyAre() throws {
        let file = try XCTUnwrap(GitPatch.parse("""
        diff --git a/f b/f
        --- a/f
        +++ b/f
        @@ -1,4 +1,4 @@
         a
        -b
        +B
         c
        -d
        +D
        @@ -10,3 +10,4 @@
         j
        +x
         k
         l
        """).files.first)
        let header = "diff --git a/f b/f\n--- a/f\n+++ b/f\n"
        // Forward: a removed line not picked stays, an added one isn't added.
        XCTAssertEqual(file.patch(picking: [0: [1, 2]], reversed: false), header + "@@ -1,4 +1,4 @@\n a\n-b\n+B\n c\n d\n")
        // Reversed: an added line not picked stays, a removed one isn't put back.
        XCTAssertEqual(file.patch(picking: [0: [2]], reversed: true), header + "@@ -1,3 +1,4 @@\n a\n+B\n c\n D\n")
        // A later hunk's other side moves with the ones before it.
        XCTAssertEqual(file.patch(picking: [0: [5], 1: [1]], reversed: false),
                       header + "@@ -1,4 +1,5 @@\n a\n b\n c\n d\n+D\n@@ -10,3 +11,4 @@\n j\n+x\n k\n l\n")
        XCTAssertNil(file.patch(picking: [0: [0, 3]], reversed: false))
        XCTAssertEqual(file.changedLines(picking: [0: [0, 1, 2], 1: [1]]), 3)
        // Some lines of a new file.
        let new = try XCTUnwrap(GitPatch.parse("diff --git a/n b/n\nnew file mode 100644\n--- /dev/null\n+++ b/n\n@@ -0,0 +1,2 @@\n+hello\n+world\n").files.first)
        XCTAssertEqual(new.patch(picking: [0: [0]], reversed: false), "diff --git a/n b/n\n--- a/n\n+++ b/n\n@@ -0,0 +1,1 @@\n+hello\n")
        XCTAssertEqual(new.patch(picking: [0: [0]], reversed: true), "diff --git a/n b/n\n--- a/n\n+++ b/n\n@@ -1,1 +1,2 @@\n+hello\n world\n")
    }

    @MainActor
    func testPickedLinesAreStagedWholeOnlyWhenAllOfAFileIs() throws {
        var patch = GitPatch.joined([
            (.unstaged, GitPatch.parse("diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1,2 +1,2 @@\n-a\n+A\n b\n")),
            (.staged, GitPatch.parse("diff --git a/g b/g\n--- a/g\n+++ b/g\n@@ -1,2 +1,3 @@\n a\n+x\n+y\n")),
        ])
        var renamed = GitChange(index: "R", worktree: " ", path: "g")
        renamed.originalPath = "old-g"
        let changes = [GitChange(index: " ", worktree: "M", path: "f"), renamed]
        let all = GitView.lineWrite(picking: [0: [0: [0, 1]], 1: [0: [1]]], of: patch, in: [.unstaged], reversed: false, changes: changes)
        XCTAssertEqual(all.paths, ["f"])
        XCTAssertEqual(all.patch, "")
        XCTAssertEqual(all.lines, 2)
        let some = GitView.lineWrite(picking: [0: [0: [0, 1]], 1: [0: [1]]], of: patch, in: [.staged], reversed: true, changes: changes)
        XCTAssertEqual(some.paths, [])
        XCTAssertEqual(some.patch, "diff --git a/g b/g\n--- a/g\n+++ b/g\n@@ -1,2 +1,3 @@\n a\n+x\n y\n")
        let renaming = GitView.lineWrite(picking: [1: [0: [1, 2]]], of: patch, in: [.staged], reversed: true, changes: changes)
        XCTAssertEqual(renaming.paths, ["g", "old-g"])
        // A diff cut short isn't all of the file, and a conflict's lines are staged whole.
        patch.omittedLines = 1
        XCTAssertEqual(GitView.lineWrite(picking: [0: [0: [0, 1]]], of: patch, in: [.unstaged], reversed: false, changes: changes).paths, [])
        let conflicted = GitView.lineWrite(picking: [0: [0: [0, 1]]], of: patch, in: [.unstaged], reversed: false,
                                           changes: [GitChange(index: "U", worktree: "U", path: "f")])
        XCTAssertTrue(conflicted.isEmpty)
        XCTAssertTrue(conflicted.hasConflicts)
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

final class GitWordDiffTests: XCTestCase {
    private func hunk(_ body: String) throws -> GitHunk {
        try XCTUnwrap(GitPatch.parse("diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1,9 +1,9 @@\n" + body).files.first?.hunks.first)
    }

    func testTokensAreWordsSpacesAndSingleCharacters() {
        let tokens = GitWordDiff.tokens("foo_bar1  (x)->é")
        XCTAssertEqual(tokens.map(\.text), ["foo_bar1", "  ", "(", "x", ")", "-", ">", "é"])
        XCTAssertEqual(tokens.map(\.kind), [.word, .space, .other, .word, .other, .other, .other, .word])
        XCTAssertEqual(tokens.map(\.columns), [0..<8, 8..<10, 10..<11, 11..<12, 12..<13, 13..<14, 14..<15, 15..<16])
    }

    func testAOneWordChangeMarksOnlyThatWordOnBothLines() throws {
        let hunk = try hunk(" one\n-the quick brown fox\n+the quick red fox\n two\n")
        XCTAssertEqual(hunk.lines.map(\.marks), [[], [10..<15], [10..<13], []])
        // Split shows the same lines side by side.
        let pair = try XCTUnwrap(hunk.pairs.first { $0.old?.kind == .removed })
        XCTAssertEqual(pair.old?.marks, [10..<15])
        XCTAssertEqual(pair.new?.marks, [10..<13])
    }

    func testLinesPairInOrderAndLeftoversGetNoMarks() throws {
        let hunk = try hunk("-let a = 1\n-let b = 2\n-let c = 3\n+let a = 10\n+let b = 20\n context\n+let d = 4\n")
        XCTAssertEqual(hunk.lines.map(\.marks), [[8..<9], [8..<9], [], [8..<10], [8..<10], [], []])
    }

    func testAnAddedRunBeforeARemovedOneIsNotABlock() throws {
        let hunk = try hunk("+let a = 1\n-let a = 2\n")
        XCTAssertEqual(hunk.lines.map(\.marks), [[], []])
    }

    func testPairsSharingLessThanHalfTheirCodeGetNoMarks() throws {
        // Half their code in common tokens, whitespace aside, is enough.
        XCTAssertNotNil(GitWordDiff.marks(old: "aa bb", new: "aa cc"))
        XCTAssertNil(GitWordDiff.marks(old: "aa bbb", new: "aa ccc"))
        // A changed value keeps its marks; a line that only keeps its keyword is a rewrite.
        XCTAssertEqual(GitWordDiff.marks(old: "    timeout: 30,", new: "    timeout: 45,")?.new, [13..<15])
        XCTAssertNil(GitWordDiff.marks(old: "let a = 1", new: "let total = count"))
        // Shared indentation doesn't make two lines alike.
        XCTAssertNil(GitWordDiff.marks(old: "        return nil", new: "        throw error"))
        let hunk = try hunk("-let a = 1\n+let total = count\n")
        XCTAssertEqual(hunk.lines.map(\.marks), [[], []])
    }

    func testMarksAreJoinedAcrossASpaceBetweenChangedWords() {
        XCTAssertEqual(GitWordDiff.marks(old: "the old brown fox jumps", new: "the old red cat jumps")?.old, [8..<17])
        XCTAssertEqual(GitWordDiff.marks(old: "f(a, b)", new: "f(a, c)")?.new, [5..<6])
    }

    func testMarksAreInShownColumnsWithTabsExpanded() throws {
        let hunk = try hunk("-\tname\t= old\n+\tname\t= new\n")
        // `    name    = old`: the tab after `name` reaches column 12.
        XCTAssertEqual(hunk.lines.map(\.marks), [[14..<17], [14..<17]])
        XCTAssertEqual(hunk.lines[1].text(in: 14..<17), "new")
        // A tab after a longer word reaches further.
        let mixed = try XCTUnwrap(GitWordDiff.marks(old: "id\tfirst_name = value + old", new: "ident\tfirst_name = value + new"))
        XCTAssertEqual(mixed.old, [0..<2, 25..<28])
        XCTAssertEqual(mixed.new, [0..<5, 29..<32])
    }

    func testVeryLongLinesAndVeryLargeBlocksGetNoMarks() throws {
        let long = String(repeating: "a ", count: GitWordDiff.lineLimit / 2 - 1)
        XCTAssertNotNil(GitWordDiff.marks(old: long + "bb", new: long + "cc"))
        XCTAssertNil(GitWordDiff.marks(old: long + "bbb", new: long + "ccc"))
        func block(_ size: Int) throws -> GitHunk {
            try hunk((0..<size).map { "-line \($0) old\n" }.joined() + (0..<size).map { "+line \($0) new\n" }.joined())
        }
        XCTAssertTrue(try block(GitWordDiff.blockLimit).lines.allSatisfy { !$0.marks.isEmpty })
        XCTAssertTrue(try block(GitWordDiff.blockLimit + 1).lines.allSatisfy(\.marks.isEmpty))
    }

    func testMarksColorTheChangedWordsUnderTheSyntaxColors() throws {
        let colors = GitColors(nil)
        var patch = GitPatch.parse("diff --git a/a.swift b/a.swift\n--- a/a.swift\n+++ b/a.swift\n@@ -1 +1 @@\n-\tlet name = \"old\"\n+\tlet name = \"new\"\n")
        GitHighlighter(colors: colors, fontSize: 12).highlight(&patch)
        let lines = try XCTUnwrap(patch.files.first?.hunks.first?.lines)
        let removed = try XCTUnwrap(lines[0].styled)
        let added = try XCTUnwrap(lines[1].styled)
        XCTAssertEqual(added[try XCTUnwrap(added.range(of: "new"))].backgroundColor, Color(nsColor: colors.addedWord))
        XCTAssertEqual(added[try XCTUnwrap(added.range(of: "new"))].foregroundColor, Color(nsColor: colors.green))
        XCTAssertEqual(removed[try XCTUnwrap(removed.range(of: "old"))].backgroundColor, Color(nsColor: colors.removedWord))
        XCTAssertNil(added[try XCTUnwrap(added.range(of: "let name"))].backgroundColor)
        XCTAssertNil(added[try XCTUnwrap(added.range(of: "\""))].backgroundColor)
        // A wrap is a slice of `styled` by column, so the mark stays on its characters.
        let characters = added.characters
        let wrap = AttributedString(added[characters.index(characters.startIndex, offsetBy: 16)..<characters.endIndex])
        XCTAssertEqual(String(wrap.characters), "new\"")
        XCTAssertEqual(wrap.runs.map { String(wrap[$0.range].characters) }.first, "new")
        XCTAssertEqual(wrap[try XCTUnwrap(wrap.range(of: "new"))].backgroundColor, Color(nsColor: colors.addedWord))
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
        try run(script, arguments)
    }

    @discardableResult
    private func run(_ script: String, _ arguments: [String]) throws -> String {
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

    func testABranchHasItsOwnHistory() throws {
        let log = GitRepository.parseLog(try run(GitRepository.logScript, repository, "feature"))
        XCTAssertEqual(log.commits.map(\.subject), ["Add b", "First"])
        XCTAssertEqual(log.commits.first?.refs, ["feature"])
        // No upstream: what isn't in master yet is unpushed.
        XCTAssertEqual(log.commits.map(\.status), [.unpushed, .merged])
        XCTAssertEqual(log.graph.count, 2)
        let snapshot = try GitRepository.parseSnapshot(run(GitRepository.snapshotScript, repository)).get()
        XCTAssertEqual(snapshot.branches.first { $0.name == "feature" }?.sha, log.commits.first?.sha)
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

    @MainActor
    func testAComparisonIsTheDiffFromTheBaseWithRenamesFound() throws {
        try run("""
        cd "$1" && git worktree add -q -b moved ../moved feature && cd ../moved
        git mv a.swift renamed.swift && printf 'let c = 3\\n' > c.swift && git add c.swift
        # A minute after feature, so moved sorts above it, as it does when the clock ticks between commits.
        GIT_COMMITTER_DATE="$(($(git log -1 --format=%ct feature) + 60)) +0000" git commit -q -m Move
        """, repository)
        let gitView = GitView(windowID: "@1")
        gitView.apply(try GitRepository.parseSnapshot(run(GitRepository.snapshotScript, repository)).get())
        gitView.perform(.tab(.branches))
        select("feature", in: gitView)
        gitView.perform(.mark)
        select("moved", in: gitView)
        let request = try XCTUnwrap(gitView.request())
        XCTAssertEqual(request.script, GitRepository.gitScript)
        let patch = GitPatch.parse(try run(request.script, request.arguments))
        XCTAssertEqual(patch.files.map(\.path), ["c.swift", "renamed.swift"])
        XCTAssertEqual(patch.files.map(\.change), [.added, .renamed])
        XCTAssertEqual(patch.additions, 1)
    }

    /// Branches sort newest commit first, so a row can be above or below the
    /// selection. This walks the whole list once and fails when no row has the name.
    @MainActor
    private func select(_ name: String, in gitView: GitView) {
        gitView.perform(.top)
        var seen: Set<String> = []
        while let selected = gitView.selectedItem?.name, selected != name, seen.insert(selected).inserted {
            gitView.perform(.down)
        }
        XCTAssertEqual(gitView.selectedItem?.name, name, "no row named \(name) in \(seen.sorted())")
    }

    private func status() throws -> [String] {
        try run("cd \"$1\" && git status --porcelain --untracked-files=all", repository).split(separator: "\n").map(String.init)
    }

    func testSpaceStagesAndUnstages() throws {
        try run(GitRepository.stageScript, repository, "c.txt", "a.swift")
        XCTAssertEqual(try status(), ["M  a.swift", "A  c.txt"])
        try run(GitRepository.unstageScript, repository, ".")
        XCTAssertEqual(try status(), [" M a.swift", "?? c.txt"])
        // A deleted file in a folder is staged with it.
        try run("cd \"$1\" && mkdir sub && printf 'x\\n' > sub/x && git add sub && git commit -qm x && rm sub/x", repository)
        try run(GitRepository.stageScript, repository, "sub")
        XCTAssertEqual(try status(), [" M a.swift", "D  sub/x", "?? c.txt"])
    }

    func testCommitTakesWhatsStaged() throws {
        let hash = try run(GitRepository.makeCommitScript, repository, "Stage a\n\nThe body.")
        XCTAssertEqual(try run("cd \"$1\" && git log -1 --format='%h %s|%b'", repository).trimmingCharacters(in: .whitespacesAndNewlines),
                       "\(hash.trimmingCharacters(in: .whitespacesAndNewlines)) Stage a|The body.")
        XCTAssertEqual(try status(), [" M a.swift", "?? c.txt"])
        // Nothing staged: git refuses, and nothing is staged for it.
        XCTAssertThrowsError(try run(GitRepository.makeCommitScript, repository, "Again"))
        XCTAssertEqual(try status(), [" M a.swift", "?? c.txt"])
    }

    func testAmendTakesWhatsStagedAndKeepsTheMessage() throws {
        try run(GitRepository.makeCommitScript, repository, "Stage a\n\nThe body.")
        let before = try run("cd \"$1\" && git rev-list --count HEAD", repository)
        try run("cd \"$1\" && git add c.txt", repository)
        try run(GitRepository.amendScript, repository)
        XCTAssertEqual(try run("cd \"$1\" && git rev-list --count HEAD", repository), before)
        XCTAssertEqual(try run("cd \"$1\" && git log -1 --format='%s|%b'", repository).trimmingCharacters(in: .whitespacesAndNewlines), "Stage a|The body.")
        XCTAssertTrue(try run("cd \"$1\" && git show --name-only --format= HEAD", repository).contains("c.txt"))
        // A failing hook's words come back.
        try run("cd \"$1\" && printf '#!/bin/sh\\necho no amend today >&2\\nexit 1\\n' > .git/hooks/pre-commit && chmod +x .git/hooks/pre-commit && printf 'z\\n' > z.txt && git add z.txt", repository)
        XCTAssertThrowsError(try run(GitRepository.amendScript, repository)) { XCTAssertTrue(self.stderr(of: $0).contains("no amend today")) }
    }

    func testDiscardTakesEverythingOrOnlyWhatsUnstaged() throws {
        // a.swift is staged and changed again: only the change goes.
        try run(GitRepository.discardUnstagedScript, repository, "a.swift")
        XCTAssertEqual(try status(), ["M  a.swift", "?? c.txt"])
        // Everything: back to the last commit, and the untracked file deleted.
        try run(GitRepository.discardScript, repository, "a.swift", "c.txt")
        XCTAssertEqual(try status(), [])
        XCTAssertEqual(try run("cat \"$1/a.swift\"", repository), "let a = 1\n")
        // A rename goes back to its old path, and a new file is deleted.
        try run("cd \"$1\" && git mv a.swift moved.swift && printf 'n\\n' > n.txt && git add n.txt", repository)
        try run(GitRepository.discardScript, repository, "moved.swift", "a.swift")
        try run(GitRepository.discardScript, repository, "n.txt")
        XCTAssertEqual(try status(), [])
        // Paths are literal: app/[id] isn't a pattern that takes app/i too.
        try run("""
        cd "$1" && mkdir -p 'app/[id]' app/i && printf 'r\\n' > 'app/[id]/p' && printf 'i\\n' > app/i/p
        git add app && git commit -qm app && printf 'x\\n' >> 'app/[id]/p' && printf 'x\\n' >> app/i/p
        """, repository)
        try run(GitRepository.discardScript, repository, "app/[id]/p")
        XCTAssertEqual(try status(), [" M app/i/p"])
    }

    /// A clean master with a staged new file, an unstaged change and an untracked file.
    private func prepareStash() throws {
        try run("""
        cd "$1" && git reset -q --hard && git stash clear && rm -f c.txt
        printf 'staged\\n' > s.txt && git add s.txt && printf 'let a = 3\\n' > a.swift && printf 'u\\n' > u.txt
        """, repository)
        XCTAssertEqual(try status(), [" M a.swift", "A  s.txt", "?? u.txt"])
    }

    private func git(_ arguments: String) throws -> String {
        try run("cd \"$1\" && git \(arguments)", repository)
    }

    func testStashTakesAllChangesAndLeavesUntrackedFilesAsGitDoes() throws {
        try prepareStash()
        try run(GitRepository.stashScript, repository, "all", "my note")
        XCTAssertEqual(try status(), ["?? u.txt"])
        XCTAssertEqual(try git("stash list --format=%gs"), "On master: my note\n")
        XCTAssertEqual(try git("show stash@{0}:a.swift"), "let a = 3\n")
        XCTAssertEqual(try git("show stash@{0}:s.txt"), "staged\n")
        // No message: git's own.
        try run("cd \"$1\" && printf 'let a = 4\\n' > a.swift", repository)
        try run(GitRepository.stashScript, repository, "all", "")
        XCTAssertTrue(try git("stash list --format=%gs").hasPrefix("WIP on master: "))
    }

    func testStashCanIncludeUntrackedFiles() throws {
        try prepareStash()
        try run(GitRepository.stashScript, repository, "untracked", "everything")
        XCTAssertEqual(try status(), [])
        XCTAssertEqual(try git("show stash@{0}^3:u.txt"), "u\n")
    }

    func testStashCanTakeOnlyWhatIsStagedOrOnlyWhatIsNot() throws {
        try prepareStash()
        try run(GitRepository.stashScript, repository, "staged", "s")
        XCTAssertEqual(try status(), [" M a.swift", "?? u.txt"])
        XCTAssertEqual(try git("diff --name-only stash@{0}^ stash@{0}"), "s.txt\n")
        // Only what isn't staged: what's staged stays staged, and no commit is left behind.
        try prepareStash()
        let commits = try git("rev-list --count HEAD")
        try run(GitRepository.stashScript, repository, "unstaged", "u")
        XCTAssertEqual(try status(), ["A  s.txt", "?? u.txt"])
        XCTAssertEqual(try git("diff --name-only stash@{0}^ stash@{0}"), "a.swift\n")
        XCTAssertEqual(try git("show stash@{0}:a.swift"), "let a = 3\n")
        XCTAssertEqual(try git("rev-list --count HEAD"), commits)
        XCTAssertEqual(try git("stash list --format=%gs"), "On master: u\n")
        // With nothing staged, it is a plain stash.
        try run("cd \"$1\" && git reset -q --hard && printf 'let a = 5\\n' > a.swift", repository)
        try run(GitRepository.stashScript, repository, "unstaged", "")
        XCTAssertEqual(try status(), ["?? u.txt"])
    }

    // MARK: Continuing, skipping and aborting

    /// A repository where `side` and `master` both changed f.txt, so merging, rebasing, cherry-picking and reverting
    /// conflict; `master` has a second commit that a revert of the first conflicts with.
    private func conflictedRepository() throws -> String {
        let path = directory.url.appendingPathComponent("ops").path
        try run("""
        cd "$1"
        git init -q -b master ops && cd ops
        printf 'base\\n' > f.txt && git add f.txt && git commit -q -m Base
        git checkout -q -b side
        printf 'side\\n' > f.txt && git commit -q -am 'Side one'
        printf 'side\\nmore\\n' > f.txt && git commit -q -am 'Side two'
        git checkout -q master
        printf 'master\\n' > f.txt && git commit -q -am 'Master one'
        printf 'master\\ntwo\\n' > f.txt && git commit -q -am 'Master two'
        """, directory.url.path)
        return path
    }

    private func git(_ arguments: String, in path: String) throws -> String {
        try run("cd \"$1\" && git \(arguments)", path)
    }

    private func resolve(_ path: String, _ text: String = "resolved") throws {
        try run("cd \"$1\" && printf '\(text)\\n' > f.txt && git add f.txt", path)
    }

    private func step(_ command: String, _ verb: String, in path: String) throws {
        try run(GitRepository.operationScript, path, command, verb)
    }

    /// Whether git is in the middle of something, by the state it keeps.
    private func inProgress(_ path: String) throws -> Bool {
        try run("cd \"$1\" && ls \"$(git rev-parse --git-dir)\"", path).split(separator: "\n").contains {
            ["MERGE_HEAD", "rebase-merge", "rebase-apply", "CHERRY_PICK_HEAD", "REVERT_HEAD"].contains(String($0))
        }
    }

    func testContinueConcludesAMergeWithGitsMessageAndRefusesWhileConflictsRemain() throws {
        let path = try conflictedRepository()
        _ = try? git("merge side", in: path)
        XCTAssertThrowsError(try step("merge", "continue", in: path)) {
            XCTAssertTrue(self.stderr(of: $0).contains("Conflicts remain"), self.stderr(of: $0))
        }
        XCTAssertTrue(try inProgress(path))
        try resolve(path)
        try step("merge", "continue", in: path)
        XCTAssertFalse(try inProgress(path))
        XCTAssertEqual(try git("log -1 --format=%s", in: path), "Merge branch 'side'\n")
        XCTAssertEqual(try git("rev-list --parents -1 HEAD", in: path).split(separator: " ").count, 3)
    }

    func testAbortGoesBackToBeforeTheMergeAndAMergeCannotBeSkipped() throws {
        let path = try conflictedRepository()
        let before = try git("rev-parse HEAD", in: path)
        _ = try? git("merge side", in: path)
        XCTAssertFalse(GitOperation.merge(["x"]).canSkip)
        try step("merge", "abort", in: path)
        XCTAssertFalse(try inProgress(path))
        XCTAssertEqual(try git("rev-parse HEAD", in: path), before)
        XCTAssertEqual(try git("status --porcelain", in: path), "")
    }

    func testContinueGoesOnWithARebaseAndLeavesNewConflictsInChanges() throws {
        let path = try conflictedRepository()
        _ = try? git("checkout -q side && git rebase master", in: path)
        XCTAssertTrue(try inProgress(path))
        try resolve(path, "r1")
        // The second commit conflicts too: the continue says so and the rebase goes on.
        XCTAssertThrowsError(try step("rebase", "continue", in: path)) {
            XCTAssertTrue(self.stderr(of: $0).contains("Conflicts remain"), self.stderr(of: $0))
        }
        XCTAssertEqual(try git("status --porcelain", in: path), "UU f.txt\n")
        try resolve(path, "r2")
        try step("rebase", "continue", in: path)
        XCTAssertFalse(try inProgress(path))
        XCTAssertEqual(try git("log --format=%s", in: path), "Side two\nSide one\nMaster two\nMaster one\nBase\n")
        XCTAssertEqual(try git("symbolic-ref --short HEAD", in: path), "side\n")
    }

    func testSkipLeavesOutTheStepAndAbortRestoresTheBranchOfARebase() throws {
        let path = try conflictedRepository()
        let original = try git("rev-parse side", in: path)
        _ = try? git("checkout -q side && git rebase master", in: path)
        try step("rebase", "abort", in: path)
        XCTAssertEqual(try git("rev-parse HEAD", in: path), original)
        XCTAssertEqual(try git("symbolic-ref --short HEAD", in: path), "side\n")
        _ = try? git("rebase master", in: path)
        // Skipping the first commit; the second applies on its own, or conflicts again.
        _ = try? step("rebase", "skip", in: path)
        _ = try? git("checkout --theirs f.txt && git add f.txt", in: path)
        _ = try? step("rebase", "continue", in: path)
        XCTAssertFalse(try inProgress(path))
        XCTAssertFalse(try git("log --format=%s", in: path).contains("Side one"))
    }

    /// master (Base, Master one) and side (Base, Side one, Side two) touching other files, so they merge cleanly; `ahead`
    /// is a branch of one commit that master can fast-forward to.
    private func mergeableRepository() throws -> String {
        let path = directory.url.appendingPathComponent("merges").path
        try run("""
        cd "$1"
        git init -q -b master merges && cd merges
        printf 'base\\n' > f.txt && git add f.txt && git commit -q -m Base
        git checkout -q -b ahead
        printf 'a\\n' > a.txt && git add a.txt && git commit -q -m 'Ahead one'
        git checkout -q -b side master
        printf 's\\n' > s.txt && git add s.txt && git commit -q -m 'Side one'
        printf 's2\\n' > s.txt && git commit -q -am 'Side two'
        git checkout -q master
        """, directory.url.path)
        return path
    }

    private func merge(_ kind: String, _ branch: String, in path: String) throws {
        try run(GitRepository.mergeScript, path, branch, kind, "master")
    }

    func testAFastForwardMergeMovesTheBranchWhenItCanAndMakesAMergeCommitWhenItCannot() throws {
        let path = try mergeableRepository()
        try merge("ff", "ahead", in: path)
        XCTAssertEqual(try git("rev-parse HEAD", in: path), try git("rev-parse ahead", in: path))
        XCTAssertEqual(try git("rev-list --parents -1 HEAD", in: path).split(separator: " ").count, 2)
        // Master has moved on from side: git makes a merge commit, with its own message and no editor.
        try merge("ff", "side", in: path)
        XCTAssertEqual(try git("rev-list --parents -1 HEAD", in: path).split(separator: " ").count, 3)
        XCTAssertEqual(try git("log -1 --format=%s", in: path), "Merge branch 'side'\n")
    }

    func testAMergeWithMergeCommitIsNeverAFastForward() throws {
        let path = try mergeableRepository()
        let before = try git("rev-parse HEAD", in: path)
        try merge("no-ff", "ahead", in: path)
        XCTAssertEqual(try git("rev-list --parents -1 HEAD", in: path).split(separator: " ").count, 3)
        XCTAssertEqual(try git("rev-parse HEAD^1", in: path), before)
        XCTAssertEqual(try git("log -1 --format=%s", in: path), "Merge branch 'ahead'\n")
    }

    func testASquashMergeCommitsOneCommitWithGitsMessageAndCanLeaveItStaged() throws {
        let path = try mergeableRepository()
        let before = try git("rev-parse HEAD", in: path)
        try merge("squash", "side", in: path)
        XCTAssertEqual(try git("rev-parse HEAD^", in: path), before)
        XCTAssertEqual(try git("rev-list --parents -1 HEAD", in: path).split(separator: " ").count, 2, "a squash has one parent")
        XCTAssertTrue(try git("log -1 --format=%B", in: path).hasPrefix("Squashed commit of the following:"))
        XCTAssertTrue(try git("log -1 --format=%B", in: path).contains("Side two"))
        XCTAssertEqual(try git("status --porcelain", in: path), "")
        try run("cd \"$1\" && git reset -q --hard \(before)", path)
        try merge("squash-leave", "side", in: path)
        XCTAssertEqual(try git("rev-parse HEAD", in: path), before)
        XCTAssertEqual(try git("status --porcelain", in: path), "A  s.txt\n")
        XCTAssertFalse(try inProgress(path))
    }

    func testAMergeThatConflictsStaysInProgressAndIsToldApartFromOtherFailures() throws {
        let path = try conflictedRepository()
        XCTAssertThrowsError(try merge("no-ff", "side", in: path)) {
            XCTAssertTrue(self.stderr(of: $0).contains("Merging 'side' into 'master' conflicted"), self.stderr(of: $0))
        }
        XCTAssertTrue(try inProgress(path))
        XCTAssertEqual(try git("status --porcelain", in: path), "UU f.txt\n")
        // c concludes it once the conflict is resolved and staged, and git's message is kept.
        try resolve(path)
        try run(GitRepository.makeCommitScript, path, "Merge branch 'side'")
        XCTAssertFalse(try inProgress(path))
        // m aborts it.
        try run("cd \"$1\" && git reset -q --hard HEAD^", path)
        XCTAssertThrowsError(try merge("ff", "side", in: path))
        XCTAssertTrue(try inProgress(path))
        try step("merge", "abort", in: path)
        XCTAssertFalse(try inProgress(path))
        // Any other failure prints what git said.
        XCTAssertThrowsError(try merge("ff", "nowhere", in: path)) {
            XCTAssertTrue(self.stderr(of: $0).contains("nowhere"), self.stderr(of: $0))
        }
    }

    func testASquashMergeThatConflictsLeavesTheConflictsInChanges() throws {
        let path = try conflictedRepository()
        XCTAssertThrowsError(try merge("squash", "side", in: path)) {
            XCTAssertTrue(self.stderr(of: $0).contains("Squashing 'side' into 'master' conflicted"), self.stderr(of: $0))
        }
        XCTAssertEqual(try git("status --porcelain", in: path), "UU f.txt\n")
        XCTAssertEqual(try git("rev-parse HEAD", in: path), try git("rev-parse master", in: path))
    }

    func testAnUncommittedChangeThatTheMergeWouldOverwriteStopsItWithGitsWords() throws {
        let path = try mergeableRepository()
        try run("cd \"$1\" && git checkout -q side && printf 'x\\n' > a.txt && git add a.txt && git commit -q -m 'Side a' && git checkout -q master && printf 'mine\\n' > a.txt", path)
        XCTAssertThrowsError(try merge("ff", "side", in: path)) {
            XCTAssertTrue(self.stderr(of: $0).contains("a.txt"), self.stderr(of: $0))
        }
        XCTAssertEqual(try git("status --porcelain", in: path), "?? a.txt\n")
    }

    private func rebase(onto branch: String, in path: String) throws {
        try run(GitRepository.rebaseScript, path, branch, "side")
    }

    func testASimpleRebaseReplaysTheCommitsOnTopOfTheBranchWithNoEditor() throws {
        let path = try mergeableRepository()
        try run("cd \"$1\" && git checkout -q side", path)
        try rebase(onto: "ahead", in: path)
        XCTAssertEqual(try git("rev-parse --abbrev-ref HEAD", in: path), "side\n")
        XCTAssertEqual(try git("rev-parse ahead", in: path), try git("merge-base ahead side", in: path))
        XCTAssertEqual(try git("log --format=%s ahead..side", in: path), "Side two\nSide one\n")
        XCTAssertFalse(try inProgress(path))
    }

    func testARebaseThatConflictsStaysInProgressAndIsToldApartFromOtherFailures() throws {
        let path = try conflictedRepository()
        try run("cd \"$1\" && git checkout -q side", path)
        XCTAssertThrowsError(try run(GitRepository.rebaseScript, path, "master", "side")) {
            XCTAssertTrue(self.stderr(of: $0).contains("Rebasing 'side' onto 'master' conflicted"), self.stderr(of: $0))
        }
        XCTAssertTrue(try inProgress(path))
        XCTAssertEqual(try git("status --porcelain", in: path), "UU f.txt\n")
        // m continues it once the conflict is resolved and staged; the next commit conflicts too.
        try resolve(path)
        XCTAssertThrowsError(try step("rebase", "continue", in: path))
        try resolve(path, "again")
        try step("rebase", "continue", in: path)
        XCTAssertFalse(try inProgress(path))
        // m aborts it, and skips it.
        try run("cd \"$1\" && git reset -q --hard ORIG_HEAD", path)
        XCTAssertThrowsError(try run(GitRepository.rebaseScript, path, "master", "side"))
        try step("rebase", "abort", in: path)
        XCTAssertFalse(try inProgress(path))
        XCTAssertEqual(try git("log --format=%s master..side", in: path), "Side two\nSide one\n")
        // Any other failure prints what git said.
        XCTAssertThrowsError(try run(GitRepository.rebaseScript, path, "nowhere", "side")) {
            XCTAssertTrue(self.stderr(of: $0).contains("nowhere"), self.stderr(of: $0))
        }
    }

    func testAnUncommittedChangeStopsTheRebaseWithGitsWords() throws {
        let path = try mergeableRepository()
        try run("cd \"$1\" && git checkout -q side && printf 'dirty\\n' > s.txt", path)
        XCTAssertThrowsError(try rebase(onto: "ahead", in: path)) {
            XCTAssertTrue(self.stderr(of: $0).contains("unstaged changes"), self.stderr(of: $0))
        }
        XCTAssertFalse(try inProgress(path))
    }

    func testCherryPickAndRevertContinueSkipAndAbort() throws {
        let path = try conflictedRepository()
        let before = try git("rev-parse HEAD", in: path)
        _ = try? git("cherry-pick side", in: path)
        XCTAssertTrue(try inProgress(path))
        try resolve(path)
        try step("cherry-pick", "continue", in: path)
        XCTAssertFalse(try inProgress(path))
        XCTAssertEqual(try git("log -1 --format=%s", in: path), "Side two\n")
        _ = try git("reset -q --hard \(before)", in: path)
        _ = try? git("cherry-pick side", in: path)
        try step("cherry-pick", "skip", in: path)
        XCTAssertFalse(try inProgress(path))
        XCTAssertEqual(try git("rev-parse HEAD", in: path), before)
        _ = try? git("cherry-pick side", in: path)
        try step("cherry-pick", "abort", in: path)
        XCTAssertFalse(try inProgress(path))
        XCTAssertEqual(try git("status --porcelain", in: path), "")
        // A revert of the first commit conflicts with the second.
        _ = try? git("revert HEAD~1", in: path)
        XCTAssertTrue(try inProgress(path))
        try resolve(path)
        try step("revert", "continue", in: path)
        XCTAssertFalse(try inProgress(path))
        XCTAssertTrue(try git("log -1 --format=%s", in: path).hasPrefix("Revert \"Master one\""))
        _ = try? git("revert HEAD~2", in: path)
        try step("revert", "skip", in: path)
        XCTAssertFalse(try inProgress(path))
        _ = try? git("revert HEAD~2", in: path)
        try step("revert", "abort", in: path)
        XCTAssertFalse(try inProgress(path))
    }

    func testGitAmContinuesSkipsAndAborts() throws {
        let path = try conflictedRepository()
        let before = try git("rev-parse HEAD", in: path)
        try run("cd \"$1\" && git format-patch -1 side --stdout > ../side.patch", path)
        let patch = directory.url.appendingPathComponent("side.patch").path
        _ = try? git("am -3 \(patch)", in: path)
        XCTAssertTrue(try inProgress(path))
        try resolve(path)
        try step("am", "continue", in: path)
        XCTAssertFalse(try inProgress(path))
        XCTAssertEqual(try git("log -1 --format=%s", in: path), "Side two\n")
        _ = try git("reset -q --hard \(before)", in: path)
        _ = try? git("am -3 \(patch)", in: path)
        try step("am", "skip", in: path)
        XCTAssertFalse(try inProgress(path))
        XCTAssertEqual(try git("rev-parse HEAD", in: path), before)
        _ = try? git("am -3 \(patch)", in: path)
        try step("am", "abort", in: path)
        XCTAssertFalse(try inProgress(path))
        XCTAssertEqual(try git("rev-parse HEAD", in: path), before)
    }

    /// What a failed script said.
    private func stderr(of error: Error) -> String {
        if case TmuxError.failed(_, let stderr) = error { return stderr }
        return String(describing: error)
    }

    private func stashSha(_ ref: String = "stash@{0}") throws -> String {
        try git("rev-parse \(ref)").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testAStashIsAppliedAndStaysInTheList() throws {
        try prepareStash()
        try run(GitRepository.stashScript, repository, "all", "w")
        XCTAssertEqual(try status(), ["?? u.txt"])
        try run(GitRepository.stashEntryScript, repository, "apply", "stash@{0}", try stashSha())
        XCTAssertEqual(try status(), [" M a.swift", "A  s.txt", "?? u.txt"])
        XCTAssertEqual(try git("stash list --format=%gs"), "On master: w\n")
    }

    func testAStashIsPoppedAndDropped() throws {
        try prepareStash()
        try run(GitRepository.stashScript, repository, "all", "w")
        try run(GitRepository.stashEntryScript, repository, "pop", "stash@{0}", try stashSha())
        XCTAssertEqual(try git("show :s.txt"), "staged\n", "the stash's new file is staged again, as git does")
        XCTAssertEqual(try git("stash list"), "")
        try run(GitRepository.stashScript, repository, "all", "second")
        try run(GitRepository.stashEntryScript, repository, "drop", "stash@{0}", try stashSha())
        XCTAssertEqual(try git("stash list"), "")
        XCTAssertEqual(try status(), ["?? u.txt"], "dropping leaves the working tree as it is")
    }

    func testAStashEntryRefusesWhenTheListMovedUnderIt() throws {
        try prepareStash()
        try run(GitRepository.stashScript, repository, "all", "w")
        let sha = try stashSha()
        try run("cd \"$1\" && printf 'again\\n' >> a.swift && git stash push -q -m newer", repository)
        // stash@{0} is now the newer one: nothing changes.
        XCTAssertThrowsError(try run(GitRepository.stashEntryScript, repository, "drop", "stash@{0}", sha))
        XCTAssertEqual(try git("stash list --format=%gs"), "On master: newer\nOn master: w\n")
    }

    func testAConflictingPopKeepsTheStashAndLeavesTheConflictedFiles() throws {
        try prepareStash()
        try run(GitRepository.stashScript, repository, "all", "w")
        try run("cd \"$1\" && printf 'let a = 4\\n' > a.swift && git commit -q -am other", repository)
        XCTAssertThrowsError(try run(GitRepository.stashEntryScript, repository, "pop", "stash@{0}", try stashSha())) { error in
            XCTAssertTrue(stderr(of: error).contains("conflicted"), stderr(of: error))
        }
        XCTAssertTrue(try status().contains("UU a.swift"))
        XCTAssertEqual(try git("stash list --format=%gs"), "On master: w\n")
    }

    func testAnApplyThatGitRefusesSaysWhatGitSaid() throws {
        try prepareStash()
        try run(GitRepository.stashScript, repository, "all", "w")
        try run("cd \"$1\" && printf 'let a = 5\\n' > a.swift", repository)
        XCTAssertThrowsError(try run(GitRepository.stashEntryScript, repository, "apply", "stash@{0}", try stashSha())) { error in
            XCTAssertTrue(stderr(of: error).contains("overwritten"), stderr(of: error))
        }
        XCTAssertEqual(try git("stash list --format=%gs"), "On master: w\n")
    }

    /// A clean master, and `diverged`, a branch whose a.swift differs from it.
    private func prepareCheckout() throws {
        try run("""
        cd "$1" && git reset -q --hard && git stash clear && rm -f c.txt
        git checkout -q -b diverged && printf 'let a = 9\\n' > a.swift && git commit -q -am diverge && git checkout -q master
        """, repository)
    }

    func testACheckoutSwitchesBranchAndCarriesChangesThatDontClash() throws {
        try prepareCheckout()
        try run("cd \"$1\" && printf 'u\\n' > u.txt", repository)
        try run(GitRepository.checkoutScript, repository, "branch", "feature", "0")
        XCTAssertEqual(try git("branch --show-current").trimmingCharacters(in: .whitespacesAndNewlines), "feature")
        XCTAssertEqual(try status(), ["?? u.txt"])
    }

    func testACheckoutOfACommitLeavesADetachedHead() throws {
        try prepareCheckout()
        let sha = try git("rev-parse feature").trimmingCharacters(in: .whitespacesAndNewlines)
        try run(GitRepository.checkoutScript, repository, "commit", sha, "0")
        XCTAssertEqual(try git("branch --show-current").trimmingCharacters(in: .whitespacesAndNewlines), "")
        XCTAssertEqual(try git("rev-parse HEAD").trimmingCharacters(in: .whitespacesAndNewlines), sha)
    }

    func testAChangeThatWouldBeOverwrittenBlocksTheCheckoutAndIsToldApart() throws {
        try prepareCheckout()
        try run("cd \"$1\" && printf 'mine\\n' > a.swift", repository)
        XCTAssertThrowsError(try run(GitRepository.checkoutScript, repository, "branch", "diverged", "0")) { error in
            XCTAssertTrue(stderr(of: error).hasPrefix(GitRepository.checkoutBlockedMarker), stderr(of: error))
            XCTAssertTrue(stderr(of: error).contains("overwritten"), stderr(of: error))
        }
        XCTAssertEqual(try git("branch --show-current").trimmingCharacters(in: .whitespacesAndNewlines), "master")
        XCTAssertEqual(try status(), [" M a.swift"])
    }

    func testAnAutostashCheckoutStashesChecksOutAndPops() throws {
        try prepareCheckout()
        try run("""
        cd "$1" && git checkout -q -b clash && printf 'let a = 1\\nline\\n' > a.swift && git commit -q -am clash && git checkout -q master
        printf 'top\\nlet a = 1\\n' > a.swift && printf 'u\\n' > u.txt
        """, repository)
        XCTAssertThrowsError(try run(GitRepository.checkoutScript, repository, "branch", "clash", "0"))
        try run(GitRepository.checkoutScript, repository, "branch", "clash", "1")
        XCTAssertEqual(try git("branch --show-current").trimmingCharacters(in: .whitespacesAndNewlines), "clash")
        XCTAssertEqual(try git("stash list"), "")
        XCTAssertEqual(try status(), [" M a.swift", "?? u.txt"])
        XCTAssertEqual(try run("cat \"$1/a.swift\"", repository), "top\nlet a = 1\nline\n")
    }

    func testAnAutostashCheckoutWithNothingToStashJustChecksOut() throws {
        try prepareCheckout()
        try run(GitRepository.checkoutScript, repository, "branch", "diverged", "1")
        XCTAssertEqual(try git("branch --show-current").trimmingCharacters(in: .whitespacesAndNewlines), "diverged")
        XCTAssertEqual(try git("stash list"), "")
    }

    func testAnAutostashPopThatConflictsKeepsTheStash() throws {
        try prepareCheckout()
        try run("cd \"$1\" && printf 'mine\\n' > a.swift", repository)
        XCTAssertThrowsError(try run(GitRepository.checkoutScript, repository, "branch", "diverged", "1")) { error in
            XCTAssertTrue(stderr(of: error).contains("conflicted"), stderr(of: error))
        }
        XCTAssertEqual(try git("branch --show-current").trimmingCharacters(in: .whitespacesAndNewlines), "diverged")
        XCTAssertTrue(try status().contains("UU a.swift"))
        XCTAssertEqual(try git("stash list --format=%gs").hasPrefix("On master: Autostash"), true)
    }

    private func currentBranch() throws -> String {
        try git("branch --show-current").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testANewBranchIsMadeOffAnotherBranchAndCheckedOut() throws {
        try prepareCheckout()
        try run(GitRepository.checkoutScript, repository, "new", "topic", "0", "diverged")
        XCTAssertEqual(try currentBranch(), "topic")
        XCTAssertEqual(try git("rev-parse topic"), try git("rev-parse diverged"))
        // A name that is taken is git's to refuse.
        XCTAssertThrowsError(try run(GitRepository.checkoutScript, repository, "new", "topic", "0", "master")) { error in
            XCTAssertTrue(stderr(of: error).contains("already exists"), stderr(of: error))
        }
    }

    /// A clean master, a bare remote `origin` that has it, and a second clone `other` that pushes to it.
    private func prepareRemote() throws {
        try prepareCheckout()
        try run("""
        cd "$1" && git init -q --bare origin.git && cd repo && git remote add origin ../origin.git && git push -q origin master
        cd "$1" && git clone -q -b master origin.git other
        """, directory.url.path)
    }

    /// A commit that `other` pushes to the remote's master, changing `file`.
    private func pushFromOther(_ file: String, _ text: String) throws {
        try run("""
        cd "$1/other" && printf '%s\\n' "$3" > "$2" && git add "$2" && git commit -q -m "other $2"
        git pull -q --rebase origin master && git push -q origin master
        """, directory.url.path, file, text)
    }

    func testAPushWithNoUpstreamPushesTheBranchAndSetsItAsTheUpstream() throws {
        try prepareRemote()
        try run("cd \"$1\" && git checkout -q -b topic && git commit -q --allow-empty -m topic", repository)
        XCTAssertThrowsError(try git("rev-parse --abbrev-ref topic@{upstream}"))
        try run(GitRepository.pushScript, repository, "upstream", "origin", "topic")
        XCTAssertEqual(try git("rev-parse --abbrev-ref topic@{upstream}"), "origin/topic\n")
        XCTAssertEqual(try run("git -C \"$1/origin.git\" rev-parse topic", directory.url.path),
                       try git("rev-parse topic"))
        // To another name: the remote branch has it, and the upstream follows.
        try run(GitRepository.pushScript, repository, "upstream", "origin", "renamed")
        XCTAssertEqual(try git("rev-parse --abbrev-ref topic@{upstream}"), "origin/renamed\n")
    }

    func testAPlainPushSendsNewCommitsAndAForcePushNeedsTheLeaseToHold() throws {
        try prepareRemote()
        try run("cd \"$1\" && git branch -q --set-upstream-to=origin/master && git commit -q --allow-empty -m mine", repository)
        try run(GitRepository.pushScript, repository, "plain", "", "")
        XCTAssertEqual(try run("git -C \"$1/origin.git\" rev-parse master", directory.url.path), try git("rev-parse HEAD"))
        // The remote moved on: a plain push is rejected, with git's message.
        try pushFromOther("o.txt", "o")
        try run("cd \"$1\" && git commit -q --allow-empty -m more", repository)
        XCTAssertThrowsError(try run(GitRepository.pushScript, repository, "plain", "", "")) { error in
            XCTAssertTrue(stderr(of: error).contains("rejected"), stderr(of: error))
        }
        // The lease is on what the last fetch saw: a remote that moved since is not overwritten.
        XCTAssertThrowsError(try run(GitRepository.pushScript, repository, "force", "", "")) { error in
            XCTAssertTrue(stderr(of: error).contains("stale info") || stderr(of: error).contains("rejected"), stderr(of: error))
        }
        XCTAssertNotEqual(try run("git -C \"$1/origin.git\" rev-parse master", directory.url.path), try git("rev-parse HEAD"))
        // After a fetch the lease holds, and the force push wins.
        try run("cd \"$1\" && git fetch -q", repository)
        try run(GitRepository.pushScript, repository, "force", "", "")
        XCTAssertEqual(try run("git -C \"$1/origin.git\" rev-parse master", directory.url.path), try git("rev-parse HEAD"))
    }

    func testAPullFollowsTheUsersGitConfigAndSetsAnUpstreamItWasGiven() throws {
        try prepareRemote()
        try pushFromOther("o.txt", "o")
        // No upstream: the one given is pulled from, and becomes the upstream.
        XCTAssertThrowsError(try run(GitRepository.pullScript, repository, "plain", "", ""))
        try run(GitRepository.pullScript, repository, "upstream", "origin", "master")
        XCTAssertEqual(try git("show -s --format=%s HEAD"), "other o.txt\n")
        XCTAssertEqual(try git("rev-parse --abbrev-ref master@{upstream}"), "origin/master\n")
        // With `pull.rebase`, the local commit goes on top of the remote's, as it does for git.
        try run("cd \"$1\" && git commit -q --allow-empty -m mine && git config pull.rebase true", repository)
        try pushFromOther("p.txt", "p")
        try run(GitRepository.pullScript, repository, "plain", "", "")
        XCTAssertEqual(try git("log --format=%s -3"), "mine\nother p.txt\nother o.txt\n")
    }

    func testAPullThatConflictsLeavesTheMergeInProgressAndSaysSo() throws {
        try prepareRemote()
        try run("cd \"$1\" && git branch -q --set-upstream-to=origin/master && git config pull.rebase false", repository)
        try pushFromOther("a.swift", "let a = 7")
        try run("cd \"$1\" && printf 'let a = 8\\n' > a.swift && git commit -q -am mine", repository)
        XCTAssertThrowsError(try run(GitRepository.pullScript, repository, "plain", "", "")) { error in
            XCTAssertTrue(stderr(of: error).contains("merge is in progress"), stderr(of: error))
        }
        XCTAssertTrue(try status().contains("UU a.swift"))
        // A rebase says so too.
        try run("cd \"$1\" && git merge --abort && git config pull.rebase true", repository)
        XCTAssertThrowsError(try run(GitRepository.pullScript, repository, "plain", "", "")) { error in
            XCTAssertTrue(stderr(of: error).contains("rebase is in progress"), stderr(of: error))
        }
        XCTAssertTrue(try status().contains("UU a.swift"))
    }

    func testThePreviousBranchIsWhatCheckoutDashGoesBackTo() throws {
        try prepareCheckout()
        let before = try GitRepository.parseSnapshot(run(GitRepository.snapshotScript, repository)).get()
        XCTAssertEqual(before.previousBranch, "diverged", "prepareCheckout moved from diverged to master")
        try run(GitRepository.checkoutScript, repository, "previous", "-", "0")
        XCTAssertEqual(try currentBranch(), "diverged")
        let after = try GitRepository.parseSnapshot(run(GitRepository.snapshotScript, repository)).get()
        XCTAssertEqual(after.previousBranch, "master")
        // A repository that never switched has none, and says so.
        try run("git init -q -b main \"$1/fresh\" && cd \"$1/fresh\" && git -c user.email=a@b -c user.name=a commit -q --allow-empty -m x", directory.url.path)
        let fresh = directory.url.appendingPathComponent("fresh").path
        XCTAssertNil(try GitRepository.parseSnapshot(run(GitRepository.snapshotScript, fresh)).get().previousBranch)
        XCTAssertThrowsError(try run(GitRepository.checkoutScript, fresh, "previous", "-", "0")) { error in
            XCTAssertTrue(stderr(of: error).contains("no previous branch"), stderr(of: error))
        }
    }

    func testARemoteBranchMakesALocalBranchThatTracksIt() throws {
        try prepareCheckout()
        try run("""
        cd "$1" && git init -q --bare ../origin.git && git remote add origin ../origin.git
        git push -q origin feature:remote-only && git fetch -q origin
        """, repository)
        let snapshot = try GitRepository.parseSnapshot(run(GitRepository.snapshotScript, repository)).get()
        XCTAssertEqual(snapshot.remoteBranches, ["origin/remote-only"])
        try run(GitRepository.checkoutScript, repository, "remote", "origin/remote-only", "0")
        XCTAssertEqual(try currentBranch(), "remote-only")
        XCTAssertEqual(try git("rev-parse --abbrev-ref remote-only@{upstream}").trimmingCharacters(in: .whitespacesAndNewlines),
                       "origin/remote-only")
    }

    func testARenameChangesTheNameAndKeepsTheBranch() throws {
        try prepareCheckout()
        let sha = try git("rev-parse feature")
        try run(GitRepository.renameBranchScript, repository, "feature", "renamed")
        XCTAssertEqual(try git("rev-parse renamed"), sha)
        XCTAssertFalse(try git("branch --format='%(refname:short)'").split(separator: "\n").contains("feature"))
        XCTAssertThrowsError(try run(GitRepository.renameBranchScript, repository, "renamed", "master")) { error in
            XCTAssertTrue(stderr(of: error).contains("already exists"), stderr(of: error))
        }
    }

    private func branchNames() throws -> [String] {
        try git("branch --format='%(refname:short)'").split(separator: "\n").map(String.init)
    }

    func testDeletingAMergedBranchNeedsNoForceAndAnUnmergedOneAsksFirst() throws {
        try run("cd \"$1\" && git branch merged master", repository)
        try run(GitRepository.deleteBranchScript, repository, "merged", "0")
        XCTAssertFalse(try branchNames().contains("merged"))
        // git refuses an unmerged branch, and the script says so apart from any other failure.
        XCTAssertThrowsError(try run(GitRepository.deleteBranchScript, repository, "feature", "0")) { error in
            XCTAssertEqual(stderr(of: error).trimmingCharacters(in: .whitespacesAndNewlines), GitRepository.branchNotMergedMarker)
        }
        XCTAssertTrue(try branchNames().contains("feature"))
        try run(GitRepository.deleteBranchScript, repository, "feature", "1")
        XCTAssertFalse(try branchNames().contains("feature"))
    }

    func testTheCurrentBranchAndAnotherWorktreesBranchAreNotDeletedEvenWithForce() throws {
        for (branch, force) in [("master", "0"), ("master", "1"), ("other", "0"), ("other", "1")] {
            XCTAssertThrowsError(try run(GitRepository.deleteBranchScript, repository, branch, force)) { error in
                // git's wording differs by version: "checked out at" or "used by worktree at".
                XCTAssertTrue(stderr(of: error).contains("checked out") || stderr(of: error).contains("worktree"), stderr(of: error))
                XCTAssertFalse(stderr(of: error).hasPrefix(GitRepository.branchNotMergedMarker))
            }
        }
        XCTAssertTrue(try branchNames().contains("master"))
        XCTAssertTrue(try branchNames().contains("other"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.url.appendingPathComponent("linked").path), "no Worktree is removed")
    }

    func testTheSnapshotNamesTheRepositoryFolderFromAnyWorktree() throws {
        let real = (repository as NSString).resolvingSymlinksInPath
        for path in [repository, directory.url.appendingPathComponent("linked").path] {
            let snapshot = try GitRepository.parseSnapshot(run(GitRepository.snapshotScript, path)).get()
            XCTAssertEqual((snapshot.repositoryFolder as NSString).resolvingSymlinksInPath, real)
        }
    }

    func testStashCanKeepTheIndex() throws {
        try prepareStash()
        try run(GitRepository.stashScript, repository, "keepindex", "k")
        XCTAssertEqual(try status(), ["A  s.txt", "?? u.txt"])
        XCTAssertEqual(try git("show stash@{0}:a.swift"), "let a = 3\n")
        XCTAssertEqual(try git("show stash@{0}:s.txt"), "staged\n")
        XCTAssertThrowsError(try run(GitRepository.stashScript, repository, "bogus", ""))
    }

    /// The changed lines of a file's diff with these texts, by hunk.
    private func pick(_ file: GitPatchFile, _ texts: Set<String>) -> [Int: Set<Int>] {
        var picked: [Int: Set<Int>] = [:]
        for (index, hunk) in file.hunks.enumerated() {
            for (line, diffLine) in hunk.lines.enumerated() where diffLine.kind != .context && texts.contains(diffLine.text) {
                picked[index, default: []].insert(line)
            }
        }
        return picked
    }

    /// Reversed to unstage or discard them.
    @MainActor
    private func lines(_ texts: Set<String>, of path: String, in group: GitChange.Group,
                       reversed: Bool = false) throws -> GitView.LineWrite {
        let patch = try change(path, group.rawValue)
        let file = try XCTUnwrap(patch.files.first)
        return GitView.lineWrite(picking: [file.id: pick(file, texts)], of: patch, in: [group], reversed: reversed, changes: [])
    }

    @MainActor
    func testLinesAreStagedAndUnstagedOneByOne() throws {
        try run("""
        cd "$1" && printf '1\\n2\\n3\\n4\\n5\\n6\\n7\\n8\\n9\\n10\\n11\\n12\\n' > n.txt && git add n.txt && git commit -qm n
        sed -e 's/^2$/two/' -e 's/^11$/eleven/' n.txt > n.new && mv n.new n.txt
        """, repository)
        let two = try lines(["2", "two"], of: "n.txt", in: .unstaged)
        XCTAssertEqual(two.lines, 2)
        XCTAssertEqual(two.paths, [])
        try run(GitRepository.applyPatchScript, repository, "stage", two.patch)
        XCTAssertEqual(try run("cd \"$1\" && git diff --cached --no-color -U0 n.txt | grep '^[-+][^-+]'", repository), "-2\n+two\n")
        // The rest of it is all of what's unstaged: the file is staged whole.
        let rest = try lines(["11", "eleven"], of: "n.txt", in: .unstaged)
        XCTAssertEqual(rest.paths, ["n.txt"])
        try run(GitRepository.stageScript, repository, "n.txt")
        // Unstaging takes them back out of what's staged.
        let eleven = try lines(["eleven"], of: "n.txt", in: .staged, reversed: true)
        try run(GitRepository.applyPatchScript, repository, "unstage", eleven.patch)
        XCTAssertEqual(try run("cd \"$1\" && git diff --cached --no-color -U0 n.txt | grep '^[-+][^-+]'", repository), "-2\n+two\n-11\n")
        XCTAssertEqual(try run("cd \"$1\" && git diff --no-color -U0 n.txt | grep '^[-+][^-+]'", repository), "+eleven\n")
    }

    @MainActor
    func testLinesAreDiscardedAndANewFilesLinesStaged() throws {
        try run("""
        cd "$1" && printf '1\\n2\\n3\\n4\\n5\\n6\\n7\\n8\\n9\\n10\\n11\\n12\\n' > n.txt && git add n.txt && git commit -qm n
        sed -e 's/^2$/two/' -e 's/^11$/eleven/' n.txt > n.new && mv n.new n.txt
        """, repository)
        let eleven = try lines(["11", "eleven"], of: "n.txt", in: .unstaged, reversed: true)
        try run(GitRepository.applyPatchScript, repository, "discard", eleven.patch)
        XCTAssertEqual(try run("sed -n '2p;11p' \"$1/n.txt\"", repository), "two\n11\n")
        // A new file's lines: git is told it's coming, then they're staged.
        let hello = try lines(["hello"], of: "c.txt", in: .untracked)
        XCTAssertEqual(hello.newFiles, ["c.txt"])
        try run(GitRepository.applyPatchScript, [repository, "stage", hello.patch] + hello.newFiles)
        XCTAssertEqual(try run("cd \"$1\" && git show :c.txt", repository), "hello\n")
        XCTAssertTrue(try status().contains("AM c.txt"))
        // A patch that doesn't apply leaves the new file untracked.
        try run("cd \"$1\" && git rm -q -f --cached c.txt", repository)
        XCTAssertThrowsError(try run(GitRepository.applyPatchScript, [repository, "stage", "not a patch"] + hello.newFiles))
        XCTAssertTrue(try status().contains("?? c.txt"))
    }

    func testAMergeInProgressIsReadAndItsConflictsStagedOnceResolved() throws {
        let merging = directory.url.appendingPathComponent("merging").path
        try run("""
        cd "$1" && git init -q -b master merging && cd merging
        printf 'one\\n' > f && git add f && git commit -qm base
        git checkout -q -b theirs && printf 'theirs\\n' > f && git commit -qam theirs
        git checkout -q master && printf 'ours\\n' > f && git commit -qam ours
        git merge theirs >/dev/null 2>&1 || true
        """, directory.url.path)
        let snapshot = try GitRepository.parseSnapshot(run(GitRepository.snapshotScript, merging)).get()
        let theirs = try XCTUnwrap(snapshot.branches.first { $0.name == "theirs" })
        XCTAssertEqual(snapshot.operation, .merge([theirs.sha]))
        XCTAssertEqual(snapshot.operationTitle, "Merging theirs")
        XCTAssertEqual(snapshot.mergeMessage, "Merge branch 'theirs'")
        XCTAssertEqual(snapshot.changes.map(\.status), ["UU"])
        // Its conflict markers are still there: nothing is staged.
        XCTAssertThrowsError(try run(GitRepository.stageScript, merging, ".")) { error in
            guard case TmuxError.failed(_, let stderr) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(stderr.hasPrefix("Still has conflict markers, so nothing was staged:\nf\n"), stderr)
        }
        try run("printf 'resolved\\n' > \"$1/f\"", merging)
        try run(GitRepository.stageScript, merging, ".")
        XCTAssertEqual(try run("cd \"$1\" && git status --porcelain", merging), "M  f\n")
    }

    func testARebaseCherryPickOrBisectInProgressIsRead() throws {
        let path = directory.url.appendingPathComponent("busy").path
        try run("""
        cd "$1" && git init -q -b master busy && cd busy
        printf 'one\\n' > f && git add f && git commit -qm base
        git checkout -q -b theirs && printf 'theirs\\n' > f && git commit -qam theirs
        git checkout -q master && printf 'ours\\n' > f && git commit -qam ours
        git cherry-pick theirs >/dev/null 2>&1 || true
        """, directory.url.path)
        func operation() throws -> GitOperation? {
            try GitRepository.parseSnapshot(run(GitRepository.snapshotScript, path)).get().operation
        }
        let theirs = try run("cd \"$1\" && git rev-parse theirs", path).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(try operation(), .cherryPick(theirs))
        try run("cd \"$1\" && git cherry-pick --abort && { git rebase theirs >/dev/null 2>&1 || true; }", path)
        XCTAssertEqual(try operation(), .rebase(branch: "master", step: 1, steps: 1))
        XCTAssertNotNil(try operation()?.commitBlock)
        try run("cd \"$1\" && git rebase --abort && git bisect start", path)
        XCTAssertEqual(try operation(), .bisect)
        try run("cd \"$1\" && git bisect reset >/dev/null 2>&1", path)
        XCTAssertNil(try operation())
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
        XCTAssertEqual(try command("1", keyCode: 0x12), .tab(.changes))
        XCTAssertEqual(try command("2", keyCode: 0x13), .tab(.history))
        XCTAssertEqual(try command("3", keyCode: 0x14), .tab(.branches))
        XCTAssertNil(try command("5", keyCode: 0x17))
        XCTAssertEqual(try command("\u{4}", keyCode: 0x02, flags: .control), .halfPage(1))
        XCTAssertEqual(try command("\t", keyCode: 0x30), .nextTab)
        XCTAssertEqual(try command("\u{19}", keyCode: 0x30, flags: .shift), .previousTab)
        XCTAssertEqual(try command("v", keyCode: 0x09), .range)
        XCTAssertEqual(try command("c", keyCode: 0x08, flags: .command), .copy)
        XCTAssertEqual(try command("-", keyCode: 0x1B), .collapseAll)
        XCTAssertEqual(try command("\u{1B}", keyCode: 0x35), .back)
        XCTAssertEqual(try command("\u{F701}", keyCode: 0x7D, flags: .option), .nextHunk)
        XCTAssertEqual(try command("]", keyCode: 0x1E), .nextFile)
        XCTAssertEqual(try command("/", keyCode: 0x2C), .filter)
        XCTAssertEqual(try command(" ", keyCode: 0x31), .toggle)
        XCTAssertEqual(try command("c", keyCode: 0x08), .commit)
        XCTAssertEqual(try command("d", keyCode: 0x02), .discard)
        // ⌘G goes on to toggle_git_view, ⌘B to the Browser.
        XCTAssertNil(try command("g", keyCode: 0x05, flags: .command))
        XCTAssertNil(try command("b", keyCode: 0x0B, flags: .command))
    }

    private func commit(_ sha: String, _ parents: [String] = []) -> GitCommit {
        GitCommit(sha: sha, author: "A", date: Date(), tags: [], parents: parents, subject: "Subject \(sha)")
    }

    private func branch(_ name: String, at sha: String, isHead: Bool = false, worktreePath: String? = nil) -> GitBranch {
        GitBranch(name: name, sha: sha, isHead: isHead, upstream: nil, track: "", date: nil, worktreePath: worktreePath)
    }

    private var snapshot: GitSnapshot {
        var snapshot = GitSnapshot(root: "/repo", repositoryName: "repo", head: "master")
        snapshot.commits = [commit("c2", ["c1"]), commit("c1")]
        snapshot.graph = GitGraphRow.layout(snapshot.commits)
        snapshot.branches = [branch("master", at: "c2", isHead: true), branch("feature", at: "f1")]
        snapshot.stashes = [GitStash(ref: "stash@{0}", sha: "s1", date: Date(), message: "On master: wip")]
        return snapshot
    }

    func testABranchGoesIntoItsCommitsAndACommitIntoItsFiles() {
        let gitView = GitView(windowID: "@1")
        gitView.apply(snapshot)
        // Nothing changed: Changes all the same, clean.
        XCTAssertEqual(gitView.tab, .changes)
        XCTAssertEqual(gitView.rows.map(\.text), ["Working tree clean"])
        gitView.perform(.tab(.history))
        XCTAssertEqual(gitView.level.selection, "commit:c2")
        gitView.perform(.tab(.branches))
        XCTAssertEqual(gitView.level.selection, "branch:master")
        XCTAssertEqual(gitView.request()?.id, "branch:master:c2")
        gitView.perform(.enter)
        XCTAssertEqual(gitView.list, .branch)
        XCTAssertEqual(gitView.level.owner?.id, "branch:master")
        XCTAssertEqual(gitView.level.selection, "commit:c2")
        gitView.perform(.down)
        gitView.perform(.enter)
        XCTAssertEqual(gitView.list, .files)
        XCTAssertEqual(gitView.level.owner?.id, "commit:c1")
        XCTAssertEqual(gitView.parentLevel?.selection, "commit:c1")
        // The commits stay above their files.
        XCTAssertEqual(gitView.listLevel.list, .branch)
        XCTAssertEqual(gitView.filesLevel?.owner?.id, "commit:c1")
        // A click on the other commit comes back out to it.
        gitView.select(.commit(commit("c2", ["c1"])), in: gitView.listLevel)
        XCTAssertEqual(gitView.list, .branch)
        XCTAssertEqual(gitView.level.selection, "commit:c2")
        XCTAssertEqual(gitView.filesLevel?.owner?.id, "commit:c2")
        XCTAssertNil(gitView.filesLevel?.selection)
        gitView.perform(.down)
        gitView.perform(.enter)
        // Each tab is kept as it was left.
        gitView.perform(.tab(.history))
        XCTAssertEqual(gitView.list, .history)
        gitView.perform(.nextTab)
        XCTAssertEqual(gitView.list, .files)
        gitView.perform(.back)
        XCTAssertEqual(gitView.list, .branch)
        XCTAssertEqual(gitView.level.selection, "commit:c1")
        gitView.perform(.focusList)
        XCTAssertEqual(gitView.list, .branches)
        XCTAssertEqual(gitView.level.selection, "branch:master")
        XCTAssertNil(gitView.filesLevel)
        // The branch's back button leaves its files too.
        gitView.perform(.enter)
        gitView.perform(.enter)
        XCTAssertEqual(gitView.list, .files)
        gitView.goBack(from: .branch)
        XCTAssertEqual(gitView.list, .branches)
        // The tab shown goes back to its own list.
        gitView.perform(.enter)
        gitView.perform(.tab(.branches))
        XCTAssertEqual(gitView.list, .branches)
    }

    func testAnotherBranchsCommitsAreReadAndEachListHasItsOwnFilter() {
        let gitView = GitView(windowID: "@1")
        gitView.apply(snapshot)
        gitView.perform(.tab(.branches))
        gitView.perform(.down)
        // Not read yet: its card and its commits wait for its history.
        XCTAssertEqual(gitView.request()?.id, "branch:feature:reading")
        gitView.perform(.enter)
        XCTAssertEqual(gitView.list, .branch)
        XCTAssertEqual(gitView.rows.map(\.text), ["Reading…"])
        gitView.perform(.back)
        gitView.perform(.tab(.history))
        gitView.filter = "c1"
        XCTAssertEqual(gitView.level.selection, "commit:c1")
        XCTAssertEqual(gitView.count(for: gitView.level), 1)
        gitView.perform(.tab(.stashes))
        XCTAssertEqual(gitView.filter, "")
        XCTAssertEqual(gitView.count(for: gitView.level), 1)
    }

    func testWMarksTheBaseAndTheSelectionIsComparedWithIt() {
        let gitView = GitView(windowID: "@1")
        gitView.apply(snapshot)
        XCTAssertEqual(GitView.commands[try! KeyTrigger("shift+w")], .mark)
        // Changes have no base to be.
        gitView.perform(.mark)
        XCTAssertNil(gitView.base)
        gitView.perform(.tab(.branches))
        gitView.perform(.mark)
        XCTAssertEqual(gitView.base?.id, "branch:master")
        XCTAssertNil(gitView.compared)
        // The base itself shows a note, with no Diff files to go into.
        XCTAssertEqual(gitView.request()?.id, "base:branch:master@c2")
        XCTAssertNil(gitView.filesLevel)
        gitView.perform(.enter)
        XCTAssertEqual(gitView.list, .branch, "↩ on the base still goes into its commits")
        gitView.perform(.back)
        // Another branch: base to it, with its Diff files under it.
        gitView.perform(.down)
        XCTAssertEqual(gitView.compared?.id, "branch:feature")
        let request = gitView.request()
        XCTAssertEqual(request?.id, "compare:branch:master@c2 branch:feature@f1")
        XCTAssertEqual(request?.arguments, ["/repo", "diff", "--no-color", "--no-ext-diff", "-M", "c2", "f1", "--"])
        XCTAssertEqual(request?.isFixed, true)
        XCTAssertEqual(gitView.filesLevel?.owner?.id, "branch:feature")
        gitView.perform(.enter)
        XCTAssertEqual(gitView.list, .files)
        XCTAssertEqual(gitView.contentItem?.id, "branch:feature")
        // Across tabs: a commit in History is compared with the branch.
        gitView.perform(.tab(.history))
        gitView.perform(.down)
        XCTAssertEqual(gitView.request()?.id, "compare:branch:master@c2 commit:c1@c1")
        XCTAssertEqual(gitView.filesLevel?.owner?.id, "commit:c1")
        // Changes are not affected.
        gitView.perform(.tab(.changes))
        XCTAssertNil(gitView.compared)
        XCTAssertNil(gitView.request())
        // W on another commit moves the base there.
        gitView.perform(.tab(.stashes))
        XCTAssertEqual(gitView.request()?.id, "compare:branch:master@c2 stash:s1@s1")
        gitView.perform(.tab(.history))
        gitView.perform(.mark)
        XCTAssertEqual(gitView.base?.id, "commit:c1")
        XCTAssertEqual(gitView.request()?.id, "base:commit:c1@c1")
    }

    func testTheComparisonFollowsABranchThatMoved() {
        let gitView = GitView(windowID: "@1")
        gitView.apply(snapshot)
        gitView.perform(.tab(.branches))
        gitView.perform(.down)
        gitView.perform(.mark)
        gitView.perform(.tab(.history))
        XCTAssertEqual(gitView.request()?.arguments.suffix(3), ["f1", "c2", "--"])
        var moved = snapshot
        moved.branches[1] = branch("feature", at: "f2")
        gitView.apply(moved)
        XCTAssertEqual(gitView.base?.sha, "f2")
        XCTAssertEqual(gitView.request()?.id, "compare:branch:feature@f2 commit:c2@c2")
    }

    func testWOnTheBaseOrEscapeEndsTheComparison() {
        let gitView = GitView(windowID: "@1")
        gitView.apply(snapshot)
        gitView.perform(.tab(.history))
        gitView.perform(.mark)
        gitView.perform(.mark)
        XCTAssertNil(gitView.base, "W on the base ends it")
        gitView.perform(.mark)
        // In a branch's Diff files, ⎋ comes back out first, then ends the
        // comparison; the Diff files only a comparison had close with it.
        gitView.perform(.tab(.branches))
        gitView.perform(.down)
        gitView.perform(.enter)
        XCTAssertEqual(gitView.list, .files)
        gitView.perform(.back)
        XCTAssertEqual(gitView.list, .branches)
        gitView.perform(.enter)
        gitView.perform(.tab(.history))
        gitView.perform(.back)
        XCTAssertNil(gitView.base, "⎋ where it would close the Git View ends the comparison")
        XCTAssertEqual(gitView.request()?.id, "commit:c2")
        gitView.perform(.tab(.branches))
        XCTAssertEqual(gitView.list, .branches, "a branch's Diff files closed with the comparison")
        XCTAssertNil(gitView.filesLevel)
        // W in the Diff files of what becomes the base leaves them.
        gitView.perform(.tab(.history))
        gitView.perform(.enter)
        XCTAssertEqual(gitView.list, .files)
        gitView.perform(.mark)
        XCTAssertEqual(gitView.list, .history)
        XCTAssertEqual(gitView.base?.id, "commit:c2")
    }

    func testAComparisonsCardNamesBothEnds() {
        func cards(_ content: GitView.Content) -> [Bool] {
            GitView.diffRows(for: content, layout: .unified).map { if case .card = $0.kind { true } else { false } }
        }
        let base = GitView.Item.branch(branch("master", at: "c2", isHead: true))
        let target = GitView.Item.commit(commit("c1abcdef9"))
        let content = GitView.Content(id: "x", header: .comparison(base: base, target: target), output: "",
                                      patch: GitPatch.parse(""), theme: nil)
        XCTAssertEqual(cards(content), [true, false])
        let note = GitView.Content(id: "y", header: .comparison(base: base, target: nil), output: "", patch: GitPatch.parse(""), theme: nil)
        XCTAssertEqual(cards(note), [true], "the base shows only its note")
        XCTAssertEqual(target.name, "c1abcde")
        XCTAssertEqual(GitView.Item.stash(snapshot.stashes[0]).name, "stash@{0}")
    }

    func testChangesAreOnTheirFirstFileOnceThereAreSome() {
        let gitView = GitView(windowID: "@1")
        gitView.apply(snapshot)
        XCTAssertNil(gitView.level.selection)
        var changed = snapshot
        changed.changes = [GitChange(index: " ", worktree: "M", path: "Sources/b.swift"),
                           GitChange(index: "?", worktree: "?", path: "a.txt")]
        gitView.apply(changed)
        XCTAssertEqual(gitView.tab, .changes)
        XCTAssertEqual(gitView.level.selection, "change:Sources/b.swift")
    }

    func testSpaceStagesUntilAllOfItIsStaged() {
        let unstaged = GitChange(index: " ", worktree: "M", path: "src/a.swift")
        let staged = GitChange(index: "M", worktree: " ", path: "src/b.swift")
        var renamed = GitChange(index: "R", worktree: " ", path: "src/new.swift")
        renamed.originalPath = "old.swift"
        XCTAssertTrue(GitView.staging([unstaged, staged], path: "src") == (true, ["src"]))
        XCTAssertTrue(GitView.staging([GitChange(index: "M", worktree: "M", path: "src/a.swift")], path: "src/a.swift").stage)
        XCTAssertTrue(GitView.staging([staged, renamed], path: "src") == (false, ["src", "old.swift"]))
    }

    func testSpaceGAndDOnAStashAskBeforeApplyingPoppingAndDropping() {
        let gitView = GitView(windowID: "@1")
        gitView.apply(snapshot)
        // In Changes, d still discards and g and space keep their meanings.
        gitView.perform(.pop)
        XCTAssertNil(gitView.menu)
        gitView.perform(.tab(.stashes))
        for (command, id, title, question) in [
            (GitView.Command.toggle, "stash-apply", "Apply stash", "Are you sure you want to apply this stash entry?"),
            (.pop, "stash-pop", "Pop stash", "Are you sure you want to pop this stash entry?"),
            (.discard, "stash-drop", "Drop stash", "Are you sure you want to drop the selected stash entry?"),
        ] {
            gitView.perform(command)
            XCTAssertEqual(gitView.menu?.id, id)
            XCTAssertEqual(gitView.menu?.title, title)
            XCTAssertEqual(gitView.menu?.subject, .text("stash@{0} On master: wip"))
            XCTAssertEqual(gitView.menu?.choices.map(\.key), ["y"])
            XCTAssertTrue(gitView.menu?.choices.first?.note?.hasPrefix(question) == true)
            XCTAssertEqual(gitView.menu?.choices.first?.isDestructive, command == .discard)
            gitView.closeMenu()
        }
        // In the stash's files, space folds a folder and d and g do nothing.
        gitView.perform(.enter)
        XCTAssertEqual(gitView.list, .files)
        gitView.perform(.pop)
        gitView.perform(.discard)
        XCTAssertNil(gitView.menu)
        gitView.perform(.back)
        // Nowhere else do they ask about a stash.
        gitView.perform(.tab(.history))
        gitView.perform(.pop)
        gitView.perform(.discard)
        XCTAssertNil(gitView.menu)
    }

    func testSpaceChecksOutABranchACommitAndNothingOnTheCurrentBranch() {
        let gitView = GitView(windowID: "@1")
        gitView.apply(snapshot)
        // The current branch: nothing.
        gitView.perform(.tab(.branches))
        gitView.perform(.toggle)
        XCTAssertNil(gitView.menu)
        XCTAssertEqual(gitView.queuedWriteArguments, [])
        // Another branch: checked out at once, with no Agent working there.
        gitView.perform(.down)
        XCTAssertEqual(gitView.level.selection, "branch:feature")
        gitView.perform(.toggle)
        XCTAssertNil(gitView.menu)
        XCTAssertEqual(gitView.queuedWriteArguments, [["/repo", "branch", "feature", "0"]])
        // A commit in History, and in a branch's commits: detached.
        gitView.perform(.tab(.history))
        gitView.perform(.toggle)
        XCTAssertEqual(gitView.queuedWriteArguments.last, ["/repo", "commit", "c2", "0"])
        gitView.perform(.tab(.branches))
        gitView.perform(.up)
        gitView.perform(.enter)
        XCTAssertEqual(gitView.list, .branch)
        gitView.perform(.down)
        gitView.perform(.toggle)
        XCTAssertEqual(gitView.queuedWriteArguments.last, ["/repo", "commit", "c1", "0"])
        // In the commit's files, space still folds, and checks nothing out.
        gitView.perform(.enter)
        XCTAssertEqual(gitView.list, .files)
        let queued = gitView.queuedWriteArguments.count
        gitView.perform(.toggle)
        XCTAssertEqual(gitView.queuedWriteArguments.count, queued)
        XCTAssertNil(gitView.menu)
    }

    private var snapshotWithRemotes: GitSnapshot {
        var snapshot = snapshot
        snapshot.remoteBranches = ["origin/master", "origin/feature", "origin/remote-only"]
        snapshot.previousBranch = "feature"
        return snapshot
    }

    func testNAsksForANameAndChecksOutANewBranchOffTheSelectedOne() {
        let gitView = GitView(windowID: "@1")
        gitView.apply(snapshot)
        // Only in Branches.
        gitView.perform(.newBranch)
        XCTAssertNil(gitView.prompt)
        gitView.perform(.tab(.branches))
        gitView.perform(.down)
        gitView.perform(.newBranch)
        XCTAssertEqual(gitView.prompt?.title, "New branch name (branch is off of 'feature')")
        XCTAssertEqual(gitView.promptText, "")
        XCTAssertEqual(gitView.prompt?.allowsEmpty, false)
        gitView.submitPrompt()
        XCTAssertNotNil(gitView.prompt, "an empty name submits nothing")
        gitView.promptText = "my  topic"
        gitView.submitPrompt()
        XCTAssertNil(gitView.prompt)
        XCTAssertEqual(gitView.queuedWriteArguments, [["/repo", "new", "my-topic", "0", "feature"]])
    }

    func testRRenamesTheSelectedBranchFromItsCurrentNameAndRefreshesElsewhere() {
        let gitView = GitView(windowID: "@1")
        gitView.apply(snapshot)
        // Outside Branches R still refreshes, and asks nothing.
        gitView.perform(.refresh)
        XCTAssertNil(gitView.prompt)
        gitView.perform(.tab(.branches))
        gitView.perform(.down)
        gitView.perform(.refresh)
        XCTAssertEqual(gitView.prompt?.id, "rename-branch")
        XCTAssertEqual(gitView.promptText, "feature")
        // The same name changes nothing.
        gitView.submitPrompt()
        XCTAssertEqual(gitView.queuedWriteArguments, [])
        gitView.perform(.refresh)
        gitView.promptText = "better"
        gitView.submitPrompt()
        XCTAssertEqual(gitView.queuedWriteArguments, [["/repo", "feature", "better"]])
    }

    private func topicRecord(_ id: String, title: String?, settled: Bool = false, repository: String = "/repo",
                             branch: String) -> TopicRecord {
        var record = TopicRecord(id: id, title: title)
        record.settledAt = settled ? "2026-01-01T00:00:00Z" : nil
        record.sessions = [.object(["id": .string("s"), "repository_path": .string(repository),
                                    "worktree_path": .string("/worktrees/\(id)"), "branch": .string(branch)])]
        return record
    }

    func testDInBranchesOpensTheDeleteMenuAndDeletesTheLocalBranchOnConfirm() {
        let gitView = GitView(windowID: "@1")
        gitView.apply(snapshot)
        // Elsewhere d keeps its meaning.
        gitView.perform(.discard)
        XCTAssertNil(gitView.menu)
        gitView.perform(.tab(.branches))
        gitView.perform(.down)
        gitView.perform(.discard)
        XCTAssertEqual(gitView.menu?.id, "delete-branch")
        XCTAssertEqual(gitView.menu?.title, "Delete branch")
        XCTAssertEqual(gitView.menu?.subject, .text("feature"))
        XCTAssertEqual(gitView.menu?.choices.map(\.title), ["Delete local branch"])
        XCTAssertEqual(gitView.menu?.choices.map(\.isEnabled), [true])
        XCTAssertNil(gitView.menu?.footnote)
        XCTAssertEqual(gitView.queuedWriteArguments, [], "opening the menu deletes nothing")
        gitView.handleMenuKey(try! KeyTrigger("c"))
        XCTAssertNil(gitView.menu)
        XCTAssertEqual(gitView.queuedWriteArguments, [["/repo", "feature", "0"]])
    }

    func testTheCurrentBranchHasNothingToDeleteAndSaysWhy() {
        let gitView = GitView(windowID: "@1")
        gitView.apply(snapshot)
        gitView.perform(.tab(.branches))
        gitView.perform(.discard)
        XCTAssertEqual(gitView.menu?.choices.map(\.isEnabled), [false])
        XCTAssertEqual(gitView.menu?.choices.first?.note, "You cannot delete the checked out branch!")
        gitView.handleMenuKey(try! KeyTrigger("c"))
        gitView.perform(.enter)
        XCTAssertEqual(gitView.queuedWriteArguments, [])
    }

    func testAnUnmergedBranchAsksForForceAndIsForceDeletedOnlyOnConfirm() {
        let gitView = GitView(windowID: "@1")
        gitView.apply(snapshot)
        gitView.perform(.tab(.branches))
        gitView.perform(.down)
        let feature = gitView.snapshot!.branches[1]
        let refusal = TmuxError.failed(status: 1, stderr: GitRepository.branchNotMergedMarker)
        gitView.finishDeleteBranch(feature, .failure(refusal))
        XCTAssertEqual(gitView.menu?.id, "force-delete-branch")
        XCTAssertEqual(gitView.menu?.title, "Force delete branch")
        XCTAssertEqual(gitView.menu?.choices.first?.note, "'feature' is not fully merged. Are you sure you want to delete it?")
        XCTAssertEqual(gitView.queuedWriteArguments, [])
        gitView.closeMenu()
        XCTAssertEqual(gitView.queuedWriteArguments, [], "cancelling deletes nothing")
        gitView.finishDeleteBranch(feature, .failure(refusal))
        gitView.handleMenuKey(try! KeyTrigger("y"))
        XCTAssertEqual(gitView.queuedWriteArguments, [["/repo", "feature", "1"]])
    }

    func testAnotherFailureOfTheDeleteShowsGitsMessage() {
        let gitView = GitView(windowID: "@1")
        gitView.apply(snapshot)
        let message = "error: Cannot delete branch 'other' checked out at '/linked'"
        gitView.finishDeleteBranch(gitView.snapshot!.branches[1], .failure(TmuxError.failed(status: 1, stderr: message)))
        XCTAssertNil(gitView.menu)
        XCTAssertEqual(gitView.writeError, message)
    }

    func testTheDeleteConfirmationNamesEveryTopicThatRemembersTheBranch() {
        let gitView = GitView(windowID: "@1")
        var snapshot = snapshot
        snapshot.repositoryFolder = "/repo"
        gitView.apply(snapshot)
        gitView.topicRecordsForTesting = [
            topicRecord("a", title: "Fix payments", branch: "feature"),
            topicRecord("b", title: "Old work", settled: true, branch: "feature"),
            topicRecord("c", title: "Other branch", branch: "master"),
            topicRecord("d", title: "Other repository", repository: "/elsewhere", branch: "feature"),
        ]
        gitView.perform(.tab(.branches))
        gitView.perform(.down)
        gitView.perform(.discard)
        XCTAssertEqual(gitView.menu?.footnote, "Topic 'Fix payments' remembers this branch; Reopen will start it again from its base. "
                       + "Topic 'Old work' remembers this branch; Reopen will start it again from its base.")
        // The confirmation to force names them too.
        gitView.finishDeleteBranch(snapshot.branches[1], .failure(TmuxError.failed(status: 1, stderr: GitRepository.branchNotMergedMarker)))
        XCTAssertTrue(gitView.menu?.footnote?.hasPrefix("Topic 'Fix payments' remembers this branch;") == true)
    }

    func testMinusChecksOutThePreviousBranchInBranchesAndStillFoldsElsewhere() {
        let gitView = GitView(windowID: "@1")
        gitView.apply(snapshotWithRemotes)
        gitView.perform(.tab(.branches))
        gitView.perform(.collapseAll)
        XCTAssertEqual(gitView.queuedWriteArguments, [["/repo", "branch", "feature", "0"]])
        // A previous commit, which is no branch of the repository, is git's to go back to.
        var detached = snapshot
        detached.previousBranch = nil
        gitView.apply(detached)
        gitView.perform(.collapseAll)
        XCTAssertEqual(gitView.queuedWriteArguments.last, ["/repo", "previous", "-", "0"])
        // In a branch's commits there is nothing to go back to: the key keeps its folding meaning.
        let queued = gitView.queuedWriteArguments.count
        gitView.perform(.tab(.history))
        gitView.perform(.collapseAll)
        XCTAssertEqual(gitView.queuedWriteArguments.count, queued)
    }

    func testCInBranchesChecksOutTheTypedOrChosenNameAndMakesTrackingBranchesOfRemoteOnes() {
        let gitView = GitView(windowID: "@1")
        gitView.apply(snapshotWithRemotes)
        gitView.perform(.tab(.branches))
        gitView.perform(.commit)
        XCTAssertEqual(gitView.prompt?.id, "checkout-by-name")
        // Nothing typed: every branch, local then remote.
        XCTAssertEqual(gitView.promptSuggestions, ["master", "feature", "origin/master", "origin/feature", "origin/remote-only"])
        gitView.promptText = "REM"
        XCTAssertEqual(gitView.promptSuggestions, ["origin/remote-only"])
        // ↓ chooses, ↩ takes the choice and not what was typed.
        XCTAssertNil(gitView.promptSuggestion)
        gitView.moveSuggestion(by: 1)
        XCTAssertEqual(gitView.promptSuggestion, "origin/remote-only")
        gitView.moveSuggestion(by: 1)
        XCTAssertEqual(gitView.promptSuggestion, "origin/remote-only", "the last stays chosen")
        gitView.submitPrompt()
        XCTAssertEqual(gitView.queuedWriteArguments, [["/repo", "remote", "origin/remote-only", "0"]])
        // Typed in full, with no choice: the name as typed. ↑ from the first goes back to the typed text.
        gitView.perform(.commit)
        gitView.promptText = "feat"
        XCTAssertEqual(gitView.promptSuggestions, ["feature", "origin/feature"])
        gitView.moveSuggestion(by: 1)
        gitView.moveSuggestion(by: -1)
        XCTAssertNil(gitView.promptSuggestion)
        gitView.promptText = "feature"
        gitView.submitPrompt()
        XCTAssertEqual(gitView.queuedWriteArguments.last, ["/repo", "branch", "feature", "0"])
        // A remote branch whose local branch exists checks out that one; a name that matches nothing is git's to judge.
        XCTAssertEqual(gitView.checkoutTarget(named: "origin/feature"), .branch("feature"))
        XCTAssertEqual(gitView.checkoutTarget(named: "origin/remote-only"), .remote("origin/remote-only"))
        XCTAssertEqual(gitView.checkoutTarget(named: "v1.0"), .branch("v1.0"))
    }

    func testCCommitsOnlyInChangesAndDoesNothingInHistoryAndStashes() {
        let gitView = GitView(windowID: "@1")
        var changed = snapshotWithRemotes
        changed.changes = [GitChange(index: "M", worktree: " ", path: "a.swift")]
        gitView.apply(changed)
        gitView.perform(.commit)
        XCTAssertTrue(gitView.isCommitOpen)
        gitView.closeCommit()
        for tab in [GitTab.history, .stashes] {
            gitView.perform(.tab(tab))
            gitView.perform(.commit)
            XCTAssertFalse(gitView.isCommitOpen, "c in \(tab)")
            XCTAssertNil(gitView.prompt)
            XCTAssertNil(gitView.menu)
        }
        gitView.perform(.tab(.branches))
        gitView.perform(.commit)
        XCTAssertFalse(gitView.isCommitOpen)
        XCTAssertEqual(gitView.prompt?.id, "checkout-by-name")
    }

    func testEveryCheckoutGoesThroughTheAgentGuard() {
        let gitView = GitView(windowID: "@1")
        gitView.apply(snapshot)
        gitView.agentsForTesting = [Agent(paneID: "%1", kind: .codex, status: .working, unread: false, windowID: "@1", sessionID: "$1",
                                          sessionName: "work", windowIndex: 0, windowTitle: "w", label: "", path: snapshot.root)]
        gitView.perform(.tab(.branches))
        gitView.perform(.down)
        gitView.perform(.toggle)
        XCTAssertEqual(gitView.menu?.title, "Check out")
        XCTAssertEqual(gitView.menu?.agents, ["Codex in work"])
        XCTAssertEqual(gitView.queuedWriteArguments, [])
        gitView.closeMenu()
        XCTAssertEqual(gitView.queuedWriteArguments, [])
        gitView.perform(.toggle)
        XCTAssertTrue(gitView.chooseMenu(key: "y"))
        XCTAssertEqual(gitView.queuedWriteArguments, [["/repo", "branch", "feature", "0"]])
        gitView.perform(.tab(.history))
        gitView.perform(.toggle)
        XCTAssertEqual(gitView.menu?.title, "Check out")
        XCTAssertEqual(gitView.menu?.subject, .text("c2"))
    }

    private func trackedSnapshot(ahead: Int = 0, behind: Int = 0) -> GitSnapshot {
        var snapshot = snapshot
        snapshot.upstream = "origin/master"
        snapshot.ahead = ahead
        snapshot.behind = behind
        return snapshot
    }

    func testPPushesTheBranchAndAsksForAnUpstreamWhenThereIsNone() {
        let gitView = GitView(windowID: "@1")
        gitView.apply(trackedSnapshot(ahead: 1))
        // In every tab, a branch with an upstream pushes at once.
        for tab in [GitTab.changes, .history, .branches, .stashes] {
            gitView.perform(.tab(tab))
            gitView.perform(.push)
        }
        XCTAssertEqual(gitView.networkArguments, Array(repeating: ["/repo", "plain", "", ""], count: 4))
        XCTAssertNil(gitView.menu)
        XCTAssertNil(gitView.prompt)
        // Without one, a prompt starts at origin and the branch, and its answer is pushed and set.
        gitView.apply(snapshot)
        gitView.perform(.push)
        XCTAssertEqual(gitView.prompt?.title, "Enter upstream as '<remote> <branch>'")
        XCTAssertEqual(gitView.promptText, "origin master")
        gitView.submitPrompt()
        XCTAssertEqual(gitView.networkArguments.last, ["/repo", "upstream", "origin", "master"])
        gitView.perform(.push)
        gitView.promptText = "fork  topic"
        gitView.submitPrompt()
        XCTAssertEqual(gitView.networkArguments.last, ["/repo", "upstream", "fork", "topic"])
        // ⎋ changes nothing; an answer that isn't two words says how to write it.
        let count = gitView.networkArguments.count
        gitView.perform(.push)
        gitView.closePrompt()
        gitView.perform(.push)
        gitView.promptText = "origin"
        gitView.submitPrompt()
        XCTAssertEqual(gitView.networkArguments.count, count)
        XCTAssertEqual(gitView.writeError, "Enter the upstream as '<remote> <branch>', such as 'origin master'.")
    }

    func testPOnADivergedBranchAsksBeforeAForcePushAndEscapeChangesNothing() {
        let gitView = GitView(windowID: "@1")
        gitView.apply(trackedSnapshot(ahead: 1, behind: 2))
        gitView.perform(.push)
        XCTAssertEqual(gitView.menu?.id, "force-push")
        XCTAssertEqual(gitView.menu?.choices.map(\.key), ["y"])
        XCTAssertEqual(gitView.menu?.choices.first?.note,
                       "Your branch has diverged from the remote branch. Press ⎋ to cancel, or ↩ to force push.")
        XCTAssertEqual(gitView.networkArguments, [])
        gitView.closeMenu()
        XCTAssertEqual(gitView.networkArguments, [])
        gitView.perform(.push)
        XCTAssertTrue(gitView.chooseMenu(key: "y"))
        XCTAssertEqual(gitView.networkArguments, [["/repo", "force", "", ""]])
        // Only behind the upstream asks; ahead alone pushes plainly.
        gitView.apply(trackedSnapshot(ahead: 3))
        gitView.perform(.push)
        XCTAssertNil(gitView.menu)
        XCTAssertEqual(gitView.networkArguments.last, ["/repo", "plain", "", ""])
    }

    func testPAndPSayWhyADetachedHeadCannotPushOrPull() {
        let gitView = GitView(windowID: "@1")
        var detached = snapshot
        detached.isDetached = true
        detached.head = "1a2b3c4"
        gitView.apply(detached)
        gitView.perform(.push)
        XCTAssertEqual(gitView.writeError, "A detached HEAD has no branch to push. Check out a branch first.")
        gitView.dismissWriteError()
        gitView.perform(.pull)
        XCTAssertEqual(gitView.writeError, "A detached HEAD has no branch to pull. Check out a branch first.")
        XCTAssertNil(gitView.prompt)
        XCTAssertNil(gitView.menu)
        XCTAssertEqual(gitView.networkArguments, [])
        XCTAssertEqual(gitView.queuedWriteArguments, [])
    }

    func testPPullsInTheWriteQueueAndAsksForAnUpstreamWhenThereIsNone() {
        let gitView = GitView(windowID: "@1")
        gitView.apply(trackedSnapshot(behind: 1))
        for tab in [GitTab.changes, .history, .branches, .stashes] {
            gitView.perform(.tab(tab))
            gitView.perform(.pull)
        }
        XCTAssertEqual(gitView.queuedWriteArguments, Array(repeating: ["/repo", "plain", "", ""], count: 4))
        XCTAssertEqual(gitView.networkArguments, [], "a pull waits in the write queue")
        gitView.apply(snapshot)
        gitView.perform(.pull)
        XCTAssertEqual(gitView.prompt?.id, "upstream")
        XCTAssertEqual(gitView.promptText, "origin master")
        gitView.submitPrompt()
        XCTAssertEqual(gitView.queuedWriteArguments.last, ["/repo", "upstream", "origin", "master"])
    }

    func testPullGoesThroughTheAgentGuardAfterTheUpstreamIsTyped() {
        let gitView = GitView(windowID: "@1")
        gitView.agentsForTesting = [Agent(paneID: "%1", kind: .codex, status: .working, unread: false, windowID: "@1", sessionID: "$1",
                                          sessionName: "work", windowIndex: 0, windowTitle: "w", label: "", path: snapshot.root)]
        gitView.apply(trackedSnapshot(behind: 1))
        gitView.perform(.pull)
        XCTAssertEqual(gitView.menu?.title, "Pull")
        XCTAssertEqual(gitView.menu?.agents, ["Codex in work"])
        XCTAssertEqual(gitView.queuedWriteArguments, [])
        gitView.closeMenu()
        XCTAssertEqual(gitView.queuedWriteArguments, [])
        gitView.perform(.pull)
        XCTAssertTrue(gitView.chooseMenu(key: "y"))
        XCTAssertEqual(gitView.queuedWriteArguments, [["/repo", "plain", "", ""]])
        // Without an upstream, the prompt comes first and the guard after it.
        gitView.apply(snapshot)
        gitView.perform(.pull)
        XCTAssertNil(gitView.menu)
        gitView.submitPrompt()
        XCTAssertEqual(gitView.menu?.title, "Pull")
        XCTAssertEqual(gitView.queuedWriteArguments.count, 1)
        // A push changes no files here, so the guard does not ask.
        gitView.closeMenu()
        gitView.apply(trackedSnapshot(ahead: 1))
        gitView.perform(.push)
        XCTAssertNil(gitView.menu)
        XCTAssertEqual(gitView.networkArguments.last, ["/repo", "plain", "", ""])
    }

    func testABranchCheckedOutByAnotherWorktreeAsksToGoThereAndEscapeChangesNothing() {
        let gitView = GitView(windowID: "@1")
        var snapshot = snapshot
        snapshot.branches = [branch("master", at: "c2", isHead: true, worktreePath: "/repo"),
                             branch("feature", at: "f1", worktreePath: "/work/repo-feature"), branch("other", at: "o1")]
        gitView.apply(snapshot)
        var visited: [String] = []
        gitView.worktreeVisitForTesting = { visited.append($0) }
        // An Agent working here doesn't matter: nothing changes files.
        gitView.agentsForTesting = [Agent(paneID: "%1", kind: .codex, status: .working, unread: false, windowID: "@1", sessionID: "$1",
                                          sessionName: "work", windowIndex: 0, windowTitle: "w", label: "", path: snapshot.root)]
        gitView.perform(.tab(.branches))
        gitView.perform(.down)
        XCTAssertEqual(gitView.level.selection, "branch:feature")
        gitView.perform(.toggle)
        XCTAssertEqual(gitView.menu?.id, "other-worktree")
        XCTAssertEqual(gitView.menu?.choices.first?.note, "Branch feature is checked out by Worktree repo-feature. Go to that Worktree?")
        XCTAssertEqual(gitView.menu?.agents, [])
        XCTAssertEqual(gitView.queuedWriteArguments, [])
        // ⎋ changes nothing, and nothing is checked out or visited.
        gitView.closeMenu()
        XCTAssertEqual(visited, [])
        XCTAssertEqual(gitView.queuedWriteArguments, [])
        XCTAssertNil(gitView.writeError)
        // y goes to that Worktree and checks nothing out.
        gitView.perform(.toggle)
        XCTAssertTrue(gitView.chooseMenu(key: "y"))
        XCTAssertEqual(visited, ["/work/repo-feature"])
        XCTAssertEqual(gitView.queuedWriteArguments, [])
        XCTAssertNil(gitView.menu)
        // A branch no Worktree has still checks out, through the Agent guard.
        gitView.perform(.down)
        gitView.perform(.toggle)
        XCTAssertEqual(gitView.menu?.title, "Check out")
        XCTAssertTrue(gitView.chooseMenu(key: "y"))
        XCTAssertEqual(gitView.queuedWriteArguments, [["/repo", "branch", "other", "0"]])
    }

    func testAChangeInTheWayOfACheckoutAsksToAutostashAndEscapeChangesNothing() {
        let gitView = GitView(windowID: "@1")
        gitView.apply(snapshot)
        let target = GitView.CheckoutTarget.branch("feature")
        gitView.finishCheckout(target, .failure(TmuxError.failed(status: 1, stderr: "\(GitRepository.checkoutBlockedMarker)\nerror: Your local changes would be overwritten by checkout")))
        XCTAssertEqual(gitView.menu?.id, "autostash")
        XCTAssertEqual(gitView.menu?.title, "Autostash?")
        XCTAssertEqual(gitView.menu?.choices.first?.note, "You must stash and pop your changes to bring them across. Do this automatically?")
        XCTAssertNil(gitView.writeError)
        gitView.closeMenu()
        XCTAssertEqual(gitView.queuedWriteArguments, [])
        gitView.finishCheckout(target, .failure(TmuxError.failed(status: 1, stderr: "\(GitRepository.checkoutBlockedMarker)\nerror")))
        XCTAssertTrue(gitView.chooseMenu(key: "y"))
        XCTAssertEqual(gitView.queuedWriteArguments, [["/repo", "branch", "feature", "1"]])
        // Another failure shows git's message.
        gitView.finishCheckout(target, .failure(TmuxError.failed(status: 1, stderr: "fatal: 'feature' is already used by worktree at '/x'")))
        XCTAssertNil(gitView.menu)
        XCTAssertEqual(gitView.writeError, "fatal: 'feature' is already used by worktree at '/x'")
    }

    func testApplyAndPopOfAStashListTheAgentsWorkingThereButDropDoesNot() {
        let gitView = GitView(windowID: "@1")
        gitView.apply(snapshot)
        gitView.perform(.tab(.stashes))
        gitView.agentsForTesting = [Agent(paneID: "%1", kind: .codex, status: .working, unread: false, windowID: "@1", sessionID: "$1",
                                          sessionName: "work", windowIndex: 0, windowTitle: "w", label: "", path: snapshot.root)]
        gitView.perform(.pop)
        XCTAssertEqual(gitView.menu?.agents, ["Codex in work"])
        gitView.closeMenu()
        gitView.perform(.toggle)
        XCTAssertEqual(gitView.menu?.agents, ["Codex in work"])
        gitView.closeMenu()
        gitView.perform(.discard)
        XCTAssertEqual(gitView.menu?.agents, [])
    }

    func testAListWhoseStashIsGoneCloses() {
        let gitView = GitView(windowID: "@1")
        gitView.apply(snapshot)
        gitView.perform(.tab(.stashes))
        gitView.perform(.enter)
        XCTAssertEqual(gitView.list, .files)
        var dropped = snapshot
        dropped.stashes = []
        gitView.apply(dropped)
        XCTAssertEqual(gitView.list, .stashes)
        XCTAssertNil(gitView.level.selection)
        XCTAssertEqual(gitView.rows.map(\.text), ["No stashes"])
    }

    func testDiscardAsksAsLazygitDoes() {
        let mixed = GitChange(index: "M", worktree: "M", path: "src/a.swift")
        var renamed = GitChange(index: "R", worktree: " ", path: "src/new.swift")
        renamed.originalPath = "old.swift"
        let untracked = GitChange(index: "?", worktree: "?", path: "src/c.txt")
        XCTAssertTrue(GitView.Discard(path: mixed.path, isFolder: false, changes: [mixed]).canDiscardUnstaged)
        XCTAssertFalse(GitView.Discard(path: untracked.path, isFolder: false, changes: [untracked]).canDiscardUnstaged)
        let folder = GitView.Discard(path: "src", isFolder: true, changes: [renamed, untracked])
        XCTAssertTrue(folder.canDiscardUnstaged)
        XCTAssertEqual(folder.paths(.all), ["src", "old.swift"])
        XCTAssertEqual(folder.paths(.unstaged), ["src"])
        // d asks about the selected change, and only in Changes.
        let gitView = GitView(windowID: "@1")
        var changed = snapshot
        changed.changes = [mixed, untracked]
        gitView.apply(changed)
        gitView.perform(.discard)
        XCTAssertEqual(gitView.menu?.id, "discard")
        XCTAssertEqual(gitView.menu?.subject, .file("src/a.swift"))
        gitView.closeMenu()
        gitView.perform(.tab(.history))
        gitView.perform(.discard)
        XCTAssertNil(gitView.menu)
    }

    func testTheDiscardMenuOffersWhatLazygitDoes() {
        let gitView = GitView(windowID: "@1")
        let mixed = GitChange(index: "M", worktree: "M", path: "src/a.swift")
        let untracked = GitChange(index: "?", worktree: "?", path: "src/c.txt")
        let file = gitView.discardMenu(GitView.Discard(path: mixed.path, isFolder: false, changes: [mixed]))
        XCTAssertEqual(file.title, "Discard changes")
        XCTAssertEqual(file.choices.map(\.key), ["x", "u"])
        XCTAssertEqual(file.choices.map(\.isEnabled), [true, true])
        XCTAssertEqual(file.highlightedChoice?.key, "x")
        let new = gitView.discardMenu(GitView.Discard(path: untracked.path, isFolder: false, changes: [untracked]))
        XCTAssertEqual(new.choices.map(\.isEnabled), [true, false])
        let folder = gitView.discardMenu(GitView.Discard(path: "src", isFolder: true, changes: [mixed, untracked]))
        XCTAssertEqual(folder.subject, .folder("src", files: 2))
        var lines = GitView.LineWrite()
        lines.lines = 3
        lines.paths = ["src/a.swift"]
        let picked = gitView.discardMenu(GitView.Discard(path: mixed.path, isFolder: false, changes: [mixed], lines: lines))
        XCTAssertEqual(picked.title, "Discard lines")
        XCTAssertEqual(picked.choices.map(\.title), ["Discard 3 lines"])
    }

    func testDiscardNamesTheAgentsWorkingInTheWorktreeAndOtherwiseAsksAsBefore() {
        let gitView = GitView(windowID: "@1")
        let mixed = GitChange(index: "M", worktree: "M", path: "src/a.swift")
        var changed = snapshot
        changed.changes = [mixed]
        gitView.apply(changed)
        func agent(_ id: String, _ status: AgentStatus?, at path: String) -> Agent {
            Agent(paneID: id, kind: .claude, status: status, unread: false, windowID: "@1", sessionID: "$1", sessionName: "work",
                  windowIndex: 0, windowTitle: "w", label: "", path: path)
        }
        let inside = changed.root + "/src"
        // Done, failed and Status-less Agents, and Agents elsewhere, leave the menu as it was.
        gitView.agentsForTesting = [agent("%1", .done, at: inside), agent("%2", .failed, at: inside), agent("%3", nil, at: inside),
                                    agent("%4", .working, at: changed.root + "-other")]
        gitView.perform(.discard)
        XCTAssertEqual(gitView.menu?.id, "discard")
        XCTAssertEqual(gitView.menu?.agents, [])
        gitView.closeMenu()
        // A working or blocked Agent inside the Worktree is named in the same menu, and ⎋ discards nothing.
        gitView.agentsForTesting = [agent("%1", .working, at: inside), agent("%2", .blocked, at: changed.root), agent("%3", .done, at: inside)]
        gitView.perform(.discard)
        XCTAssertEqual(gitView.menu?.id, "discard", "the guard folds into the discard menu instead of asking twice")
        XCTAssertEqual(gitView.menu?.agents, ["Claude Code in work", "Claude Code in work"])
        gitView.closeMenu()
        XCTAssertNil(gitView.menu)
    }

    func testTheAgentGuardAsksOnceForAnOperationWithNoMenuOfItsOwn() {
        let gitView = GitView(windowID: "@1")
        gitView.apply(snapshot)
        var ran = 0
        gitView.guardFiles("Pop stash", symbol: "tray.and.arrow.up", confirm: "Pop it") { ran += 1 }
        XCTAssertEqual(ran, 1, "no Agent is working: it runs at once")
        XCTAssertNil(gitView.menu)
        gitView.agentsForTesting = [Agent(paneID: "%1", kind: .codex, status: .blocked, unread: false, windowID: "@1", sessionID: "$1",
                                          sessionName: "work", windowIndex: 0, windowTitle: "w", label: "", path: snapshot.root)]
        gitView.guardFiles("Pop stash", symbol: "tray.and.arrow.up", confirm: "Pop it") { ran += 1 }
        XCTAssertEqual(ran, 1, "an Agent is blocked there: it asks first")
        XCTAssertEqual(gitView.menu?.title, "Pop stash")
        XCTAssertEqual(gitView.menu?.agents, ["Codex in work"])
        gitView.closeMenu()
        XCTAssertEqual(ran, 1)
        gitView.guardFiles("Pop stash", symbol: "tray.and.arrow.up", confirm: "Pop it") { ran += 1 }
        XCTAssertTrue(gitView.chooseMenu(key: "y"))
        XCTAssertEqual(ran, 2)
    }

    func testAGitViewMenuMovesRunsAndClosesOnItsKeys() throws {
        let gitView = GitView(windowID: "@1")
        var ran: [String] = []
        func open() {
            gitView.open(GitMenu(id: "test", title: "Test", symbol: "circle", choices: [
                GitMenu.Choice(key: "a", title: "A") { ran.append("a") },
                GitMenu.Choice(key: "b", title: "B", isEnabled: false) { ran.append("b") },
                GitMenu.Choice(key: "shift+c", title: "C", note: "The last.") { ran.append("c") },
            ]))
        }
        func key(_ name: String) throws -> Bool { gitView.handleMenuKey(try KeyTrigger(name)) }
        open()
        XCTAssertEqual(gitView.menu?.highlightedChoice?.key, "a")
        // j and ↓ skip what's disabled, and stop at the ends.
        XCTAssertTrue(try key("j"))
        XCTAssertEqual(gitView.menu?.highlightedChoice?.key, "shift+c")
        XCTAssertTrue(try key("down"))
        XCTAssertEqual(gitView.menu?.highlightedChoice?.key, "shift+c")
        XCTAssertTrue(try key("k"))
        XCTAssertTrue(try key("up"))
        XCTAssertEqual(gitView.menu?.highlightedChoice?.key, "a")
        XCTAssertTrue(try key("j"))
        XCTAssertTrue(try key("enter"))
        XCTAssertEqual(ran, ["c"])
        XCTAssertNil(gitView.menu)
        // A choice's own key runs it; a disabled one's does nothing, and goes no further.
        open()
        XCTAssertTrue(try key("b"))
        XCTAssertNotNil(gitView.menu)
        XCTAssertTrue(try key("a"))
        XCTAssertEqual(ran, ["c", "a"])
        // ⎋ and q close it and run nothing; other keys aren't the Git View's while it's open.
        for name in ["escape", "q"] {
            open()
            XCTAssertTrue(try key(name))
            XCTAssertNil(gitView.menu)
        }
        open()
        XCTAssertFalse(try key("d"))
        XCTAssertFalse(try key("cmd+b"))
        XCTAssertNotNil(gitView.menu)
        XCTAssertTrue(gitView.chooseMenu(key: "shift+c"))
        XCTAssertFalse(gitView.chooseMenu(key: "a"))
        XCTAssertEqual(ran, ["c", "a", "c"])
    }

    func testAPromptStartsWithItsTextAndSubmitsOrCancelsWithNoChange() {
        let gitView = GitView(windowID: "@1")
        var submitted: [String] = []
        func open(allowsEmpty: Bool = true) {
            gitView.open(GitPrompt(id: "test", title: "Test", symbol: "circle", initialText: "start", isSecret: true,
                                   allowsEmpty: allowsEmpty) { submitted.append($0) })
        }
        open()
        XCTAssertEqual(gitView.promptText, "start")
        XCTAssertEqual(gitView.prompt?.isSecret, true)
        gitView.closePrompt()
        XCTAssertNil(gitView.prompt)
        XCTAssertEqual(submitted, [], "cancelling submits nothing")
        open()
        gitView.promptText = "typed"
        gitView.submitPrompt()
        XCTAssertNil(gitView.prompt)
        XCTAssertEqual(submitted, ["typed"])
        gitView.submitPrompt()
        XCTAssertEqual(submitted, ["typed"], "a closed prompt submits nothing more")
        // An empty value is submitted unless the prompt wants one.
        open()
        gitView.promptText = ""
        gitView.submitPrompt()
        XCTAssertEqual(submitted, ["typed", ""])
        open(allowsEmpty: false)
        gitView.promptText = "  "
        gitView.submitPrompt()
        XCTAssertNotNil(gitView.prompt, "↩ on an empty value the prompt doesn't take leaves it open")
        XCTAssertEqual(submitted, ["typed", ""])
    }

    func testSAsksForTheStashMessageAndSOpensTheStashOptions() throws {
        let gitView = GitView(windowID: "@1")
        var changed = snapshot
        // Nothing changed: it says so and opens nothing.
        gitView.apply(changed)
        gitView.perform(.stash)
        XCTAssertNil(gitView.prompt)
        XCTAssertEqual(gitView.writeError, "Nothing to stash: the working tree is clean.")
        gitView.perform(.stashOptions)
        XCTAssertNil(gitView.menu)
        // Only an untracked file: s has nothing to take, but S can.
        changed.changes = [GitChange(index: "?", worktree: "?", path: "new.txt")]
        gitView.apply(changed)
        gitView.perform(.stash)
        XCTAssertNil(gitView.prompt)
        XCTAssertEqual(gitView.writeError, "Nothing to stash but untracked files. S stashes them too.")
        gitView.perform(.stashOptions)
        XCTAssertEqual(gitView.menu?.choices.map(\.isEnabled), [false, true, false, false, false])
        gitView.closeMenu()
        // A staged and an unstaged change: all five, in lazygit's keys.
        changed.changes = [GitChange(index: "M", worktree: "M", path: "a.swift"), GitChange(index: "?", worktree: "?", path: "new.txt")]
        gitView.apply(changed)
        gitView.perform(.stashOptions)
        XCTAssertEqual(gitView.menu?.id, "stash")
        XCTAssertEqual(gitView.menu?.choices.map(\.title), [
            "Stash all changes", "Stash all changes including untracked files", "Stash staged changes",
            "Stash unstaged changes", "Stash all changes and keep index",
        ])
        XCTAssertEqual(gitView.menu?.choices.map(\.key), ["a", "shift+u", "s", "u", "i"])
        XCTAssertEqual(gitView.menu?.choices.map(\.isEnabled), [true, true, true, true, true])
        // A choice asks for the message.
        XCTAssertTrue(gitView.chooseMenu(key: "shift+u"))
        XCTAssertNil(gitView.menu)
        XCTAssertEqual(gitView.prompt?.id, "stash")
        XCTAssertEqual(gitView.prompt?.subject, .text("Stash all changes including untracked files"))
        XCTAssertEqual(gitView.prompt?.allowsEmpty, true)
        gitView.closePrompt()
        // s asks for the message of a stash of all changes, in Changes only.
        gitView.perform(.stash)
        XCTAssertEqual(gitView.prompt?.subject, .text("Stash all changes"))
        gitView.closePrompt()
        gitView.perform(.tab(.history))
        gitView.perform(.stash)
        gitView.perform(.stashOptions)
        XCTAssertNil(gitView.prompt)
        XCTAssertNil(gitView.menu)
        // Only staged or only unstaged changes disable the other's option.
        gitView.perform(.tab(.changes))
        changed.changes = [GitChange(index: "A", worktree: " ", path: "a.swift")]
        gitView.apply(changed)
        gitView.perform(.stashOptions)
        XCTAssertEqual(gitView.menu?.choices.map(\.isEnabled), [true, true, true, false, true])
        gitView.closeMenu()
        changed.changes = [GitChange(index: " ", worktree: "M", path: "a.swift")]
        gitView.apply(changed)
        gitView.perform(.stashOptions)
        XCTAssertEqual(gitView.menu?.choices.map(\.isEnabled), [true, true, false, true, true])
    }

    func testStashingGoesThroughTheAgentGuard() {
        let gitView = GitView(windowID: "@1")
        var changed = snapshot
        changed.changes = [GitChange(index: " ", worktree: "M", path: "a.swift")]
        gitView.apply(changed)
        gitView.agentsForTesting = [Agent(paneID: "%1", kind: .claude, status: .working, unread: false, windowID: "@1", sessionID: "$1",
                                          sessionName: "work", windowIndex: 0, windowTitle: "w", label: "", path: changed.root)]
        gitView.perform(.stash)
        XCTAssertEqual(gitView.prompt?.id, "stash")
        gitView.promptText = "wip"
        gitView.submitPrompt()
        // The message is asked first; an Agent is working there, so stashing then asks once more.
        XCTAssertNil(gitView.prompt)
        XCTAssertEqual(gitView.menu?.title, "Stash changes")
        XCTAssertEqual(gitView.menu?.agents, ["Claude Code in work"])
        gitView.closeMenu()
        XCTAssertNil(gitView.menu)
    }

    func testCommittingWaitsForARebaseAndConcludesAMerge() {
        let gitView = GitView(windowID: "@1")
        var rebasing = snapshot
        rebasing.operation = .rebase(branch: "master", step: 1, steps: 2)
        rebasing.changes = [GitChange(index: "M", worktree: " ", path: "a.swift")]
        gitView.apply(rebasing)
        gitView.perform(.commit)
        XCTAssertFalse(gitView.isCommitOpen)
        XCTAssertEqual(gitView.writeError, GitOperation.rebase(branch: nil, step: nil, steps: nil).commitBlock)
        // A merge: once its conflicts are resolved, with nothing more staged.
        var merging = snapshot
        merging.operation = .merge(["f1"])
        merging.mergeMessage = "Merge branch 'feature'\n\nThe body."
        merging.changes = [GitChange(index: "U", worktree: "U", path: "a.swift")]
        gitView.apply(merging)
        gitView.perform(.commit)
        XCTAssertFalse(gitView.isCommitOpen)
        merging.changes = []
        gitView.apply(merging)
        XCTAssertEqual(merging.operationTitle, "Merging feature")
        gitView.perform(.commit)
        XCTAssertTrue(gitView.isCommitOpen)
        XCTAssertEqual(gitView.commitSummary, "Merge branch 'feature'")
        XCTAssertEqual(gitView.commitDescription, "The body.")
        // A message already written stays.
        gitView.closeCommit()
        gitView.commitSummary = "Mine"
        gitView.perform(.commit)
        XCTAssertEqual(gitView.commitSummary, "Mine")
    }

    func testAAmendsAfterAskingAndSaysWhyItCant() {
        let gitView = GitView(windowID: "@1")
        var changed = snapshot
        changed.changes = [GitChange(index: " ", worktree: "M", path: "a.swift")]
        gitView.apply(changed)
        gitView.perform(.amend)
        XCTAssertNil(gitView.menu)
        XCTAssertTrue(gitView.writeError?.contains("Nothing is staged") == true)
        changed.changes = [GitChange(index: "M", worktree: " ", path: "a.swift")]
        gitView.apply(changed)
        gitView.perform(.tab(.history))
        gitView.perform(.amend)
        XCTAssertNil(gitView.menu)
        gitView.perform(.tab(.changes))
        gitView.perform(.amend)
        XCTAssertEqual(gitView.menu?.id, "amend")
        XCTAssertEqual(gitView.menu?.choices.first?.note, "Are you sure you want to amend the last commit?")
        XCTAssertEqual(gitView.queuedWriteArguments, [])
        XCTAssertTrue(gitView.chooseMenu(key: "y"))
        XCTAssertEqual(gitView.queuedWriteArguments, [[changed.root]])
        // No commit, or something in progress.
        gitView.closeMenu()
        var unborn = changed
        unborn.commits = []
        gitView.apply(unborn)
        gitView.perform(.amend)
        XCTAssertNil(gitView.menu)
        XCTAssertEqual(gitView.writeError, "There is no commit to amend yet.")
        for operation in [GitOperation.merge(["f1"]), .rebase(branch: nil, step: nil, steps: nil), .applying(step: nil, steps: nil), .cherryPick("abc"), .revert("abc")] {
            var busy = changed
            busy.operation = operation
            gitView.apply(busy)
            gitView.perform(.amend)
            XCTAssertNil(gitView.menu, "\(operation)")
            XCTAssertNotNil(gitView.writeError, "\(operation)")
        }
    }

    func testMOffersContinueSkipAndAbortWhereGitHasThem() {
        let operations: [(GitOperation, String, [String])] = [
            (.merge(["f1"]), "merge", ["c", "a"]),
            (.rebase(branch: "feature", step: 1, steps: 2), "rebase", ["c", "s", "a"]),
            (.applying(step: 1, steps: 2), "am", ["c", "s", "a"]),
            (.cherryPick("abc1234"), "cherry-pick", ["c", "s", "a"]),
            (.revert("abc1234"), "revert", ["c", "s", "a"]),
        ]
        for (operation, command, keys) in operations {
            for tab in GitTab.allCases {
                let gitView = GitView(windowID: "@1")
                var busy = snapshot
                busy.operation = operation
                gitView.apply(busy)
                gitView.perform(.tab(tab))
                gitView.perform(.operation)
                XCTAssertEqual(gitView.menu?.id, "operation", "\(operation) \(tab)")
                XCTAssertEqual(gitView.menu?.choices.map(\.key), keys, "\(operation)")
                XCTAssertEqual(gitView.menu?.choices.last?.isDestructive, true)
                XCTAssertEqual(gitView.queuedWriteArguments, [])
            }
            for (key, verb) in [("c", "continue"), ("s", "skip"), ("a", "abort")] where keys.contains(key) {
                let gitView = GitView(windowID: "@1")
                var busy = snapshot
                busy.operation = operation
                gitView.apply(busy)
                gitView.perform(.operation)
                XCTAssertTrue(gitView.chooseMenu(key: key))
                XCTAssertEqual(gitView.queuedWriteArguments, [["/repo", command, verb]], "\(operation) \(key)")
            }
        }
    }

    func testMWithNothingInProgressOrABisectOpensNothing() {
        let gitView = GitView(windowID: "@1")
        gitView.apply(snapshot)
        gitView.perform(.operation)
        XCTAssertNil(gitView.menu)
        XCTAssertTrue(gitView.writeError?.contains("Nothing is in progress") == true)
        var bisecting = snapshot
        bisecting.operation = .bisect
        gitView.apply(bisecting)
        gitView.perform(.operation)
        XCTAssertNil(gitView.menu)
        XCTAssertTrue(gitView.writeError?.contains("bisect") == true)
    }

    func testMInBranchesOffersLazygitsFourMergesAndEachRunsTheScript() {
        let kinds = [("f", "ff"), ("n", "no-ff"), ("s", "squash"), ("u", "squash-leave")]
        for (key, kind) in kinds {
            let gitView = GitView(windowID: "@1")
            gitView.apply(snapshot)
            // Elsewhere M does nothing.
            gitView.perform(.merge)
            XCTAssertNil(gitView.menu)
            gitView.perform(.tab(.branches))
            gitView.perform(.down)
            gitView.perform(.merge)
            XCTAssertEqual(gitView.menu?.id, "merge")
            XCTAssertEqual(gitView.menu?.title, "Merge 'feature' into 'master'")
            XCTAssertEqual(gitView.menu?.choices.map(\.key), ["f", "n", "s", "u"])
            XCTAssertEqual(gitView.menu?.choices.map(\.title), [
                "Regular merge (fast-forward)", "Regular merge (with merge commit)", "Squash merge and commit",
                "Squash merge and leave uncommitted",
            ])
            XCTAssertEqual(gitView.queuedWriteArguments, [], "opening the menu merges nothing")
            XCTAssertTrue(gitView.chooseMenu(key: key))
            XCTAssertEqual(gitView.queuedWriteArguments, [["/repo", "feature", kind, "master"]], key)
        }
    }

    func testMOnTheCurrentBranchSaysItCannotMergeIntoItself() {
        let gitView = GitView(windowID: "@1")
        gitView.apply(snapshot)
        gitView.perform(.tab(.branches))
        gitView.perform(.merge)
        XCTAssertNil(gitView.menu)
        XCTAssertTrue(gitView.writeError?.contains("cannot merge a branch into itself") == true, gitView.writeError ?? "")
        XCTAssertEqual(gitView.queuedWriteArguments, [])
    }

    func testMWhileAnOperationIsInProgressAsksToConcludeItFirst() {
        let gitView = GitView(windowID: "@1")
        var busy = snapshot
        busy.operation = .merge(["f1"])
        gitView.apply(busy)
        gitView.perform(.tab(.branches))
        gitView.perform(.down)
        gitView.perform(.merge)
        XCTAssertNil(gitView.menu)
        XCTAssertTrue(gitView.writeError?.contains("in progress") == true, gitView.writeError ?? "")
    }

    func testTheMergeMenuGoesThroughTheAgentGuard() {
        let gitView = GitView(windowID: "@1")
        gitView.apply(snapshot)
        gitView.agentsForTesting = [Agent(paneID: "%1", kind: .codex, status: .working, unread: false, windowID: "@1", sessionID: "$1",
                                          sessionName: "work", windowIndex: 0, windowTitle: "w", label: "", path: snapshot.root)]
        gitView.perform(.tab(.branches))
        gitView.perform(.down)
        gitView.perform(.merge)
        XCTAssertEqual(gitView.menu?.id, "merge")
        XCTAssertEqual(gitView.menu?.agents, ["Codex in work"])
        XCTAssertEqual(gitView.queuedWriteArguments, [])
    }

    func testRInBranchesOffersTheSimpleRebaseAndRunsTheScriptOnlyAfterTheChoice() {
        let gitView = GitView(windowID: "@1")
        gitView.apply(snapshot)
        // Elsewhere r does nothing.
        gitView.perform(.rebase)
        XCTAssertNil(gitView.menu)
        gitView.perform(.tab(.branches))
        gitView.perform(.down)
        gitView.perform(.rebase)
        XCTAssertEqual(gitView.menu?.id, "rebase")
        XCTAssertEqual(gitView.menu?.title, "Rebase 'master'")
        XCTAssertEqual(gitView.menu?.choices.map(\.key), ["s"])
        XCTAssertEqual(gitView.menu?.choices.map(\.title), ["Simple rebase onto 'feature'"])
        XCTAssertEqual(gitView.queuedWriteArguments, [], "opening the menu rebases nothing")
        XCTAssertTrue(gitView.chooseMenu(key: "s"))
        XCTAssertEqual(gitView.queuedWriteArguments, [["/repo", "feature", "master"]])
    }

    func testROnTheCurrentBranchSaysItCannotRebaseOntoItself() {
        let gitView = GitView(windowID: "@1")
        gitView.apply(snapshot)
        gitView.perform(.tab(.branches))
        gitView.perform(.rebase)
        XCTAssertNil(gitView.menu)
        XCTAssertTrue(gitView.writeError?.contains("cannot rebase a branch onto itself") == true, gitView.writeError ?? "")
        XCTAssertEqual(gitView.queuedWriteArguments, [])
    }

    func testRWhileAnOperationIsInProgressAsksToContinueItFirst() {
        let gitView = GitView(windowID: "@1")
        var busy = snapshot
        busy.operation = .rebase(branch: "feature", step: 1, steps: 2)
        gitView.apply(busy)
        gitView.perform(.tab(.branches))
        gitView.perform(.down)
        gitView.perform(.rebase)
        XCTAssertNil(gitView.menu)
        XCTAssertTrue(gitView.writeError?.contains("in progress") == true, gitView.writeError ?? "")
    }

    func testTheRebaseMenuGoesThroughTheAgentGuard() {
        let gitView = GitView(windowID: "@1")
        gitView.apply(snapshot)
        gitView.agentsForTesting = [Agent(paneID: "%1", kind: .codex, status: .working, unread: false, windowID: "@1", sessionID: "$1",
                                          sessionName: "work", windowIndex: 0, windowTitle: "w", label: "", path: snapshot.root)]
        gitView.perform(.tab(.branches))
        gitView.perform(.down)
        gitView.perform(.rebase)
        XCTAssertEqual(gitView.menu?.id, "rebase")
        XCTAssertEqual(gitView.menu?.agents, ["Codex in work"])
        XCTAssertEqual(gitView.queuedWriteArguments, [])
    }

    func testTheOperationMenuGoesThroughTheAgentGuard() {
        let gitView = GitView(windowID: "@1")
        var busy = snapshot
        busy.operation = .rebase(branch: "feature", step: 1, steps: 2)
        gitView.apply(busy)
        gitView.agentsForTesting = [Agent(paneID: "%1", kind: .codex, status: .working, unread: false, windowID: "@1", sessionID: "$1",
                                          sessionName: "work", windowIndex: 0, windowTitle: "w", label: "", path: snapshot.root)]
        gitView.perform(.operation)
        XCTAssertEqual(gitView.menu?.agents, ["Codex in work"])
        XCTAssertEqual(gitView.queuedWriteArguments, [])
        gitView.closeMenu()
        XCTAssertEqual(gitView.queuedWriteArguments, [])
    }

    func testNoMessageSendsYouToTheTerminalAndTheyPointAtM() {
        let gitView = GitView(windowID: "@1")
        var busy = snapshot
        busy.changes = [GitChange(index: "M", worktree: " ", path: "a.swift")]
        for operation in [GitOperation.rebase(branch: nil, step: nil, steps: nil), .applying(step: nil, steps: nil), .cherryPick("abc"), .revert("abc")] {
            busy.operation = operation
            gitView.apply(busy)
            gitView.perform(.commit)
            XCTAssertTrue(gitView.writeError?.contains("continue it with m") == true, "\(operation)")
            gitView.perform(.amend)
            XCTAssertFalse(gitView.writeError?.contains("terminal") == true, "\(operation)")
            XCTAssertTrue(gitView.writeError?.contains("with m") == true, "\(operation)")
        }
    }

    func testStagingTheLastConflictedFileAsksToContinueTheOperation() {
        var conflicted = snapshot
        conflicted.operation = .rebase(branch: "feature", step: 1, steps: 2)
        conflicted.changes = [GitChange(index: "U", worktree: "U", path: "a.swift"), GitChange(index: "U", worktree: "U", path: "b.swift")]
        let gitView = GitView(windowID: "@1")
        gitView.apply(conflicted)
        gitView.perform(.toggle)
        XCTAssertEqual(gitView.queuedWriteArguments.count, 1)
        // One file of two is staged: the other still conflicts.
        var next = conflicted
        next.changes = [GitChange(index: "M", worktree: " ", path: "a.swift"), GitChange(index: "U", worktree: "U", path: "b.swift")]
        gitView.apply(next)
        XCTAssertNil(gitView.menu)
        // The read after the last one shows no conflict.
        gitView.perform(.down)
        gitView.perform(.toggle)
        next.changes = [GitChange(index: "M", worktree: " ", path: "a.swift"), GitChange(index: "M", worktree: " ", path: "b.swift")]
        gitView.apply(next)
        XCTAssertEqual(gitView.menu?.id, "continue")
        XCTAssertEqual(gitView.menu?.choices.first?.note, "All merge conflicts resolved. Continue the rebase?")
        XCTAssertTrue(gitView.chooseMenu(key: "y"))
        XCTAssertEqual(gitView.queuedWriteArguments.last, ["/repo", "rebase", "continue"])
        // Reading again asks nothing more; ⎋ leaves it for later.
        gitView.apply(next)
        XCTAssertNil(gitView.menu)
    }

    func testTheContinuePromptIsAskedOnlyAfterStagingAndNamesTheOperation() {
        var conflicted = snapshot
        conflicted.operation = .cherryPick("abc1234")
        conflicted.changes = [GitChange(index: "U", worktree: "U", path: "a.swift")]
        let gitView = GitView(windowID: "@1")
        gitView.apply(conflicted)
        var resolved = conflicted
        resolved.changes = [GitChange(index: "M", worktree: " ", path: "a.swift")]
        // Resolved outside the Git View: nothing was staged here, so nothing asks.
        gitView.apply(resolved)
        XCTAssertNil(gitView.menu)
        gitView.apply(conflicted)
        gitView.perform(.toggle)
        gitView.apply(resolved)
        XCTAssertEqual(gitView.menu?.title, "Continue the cherry-pick?")
        gitView.closeMenu()
        XCTAssertEqual(gitView.queuedWriteArguments.count, 1)
    }

    func testTheMessageIsDroppedInAnotherRepository() {
        let gitView = GitView(windowID: "@1")
        var changed = snapshot
        changed.changes = [GitChange(index: "M", worktree: " ", path: "a.swift")]
        gitView.apply(changed)
        gitView.commitSummary = "Half written"
        gitView.apply(changed)
        XCTAssertEqual(gitView.commitSummary, "Half written")
        changed.root = "/other"
        gitView.apply(changed)
        XCTAssertEqual(gitView.commitSummary, "")
    }

    func testEachWindowKeepsItsOwnGitView() {
        let store = WorkspaceStore(configStore: ConfigStore(path: "/nonexistent/muxify/config.yaml"))
        let first = store.gitView(for: "@1")
        XCTAssertTrue(store.gitView(for: "@1") === first)
        XCTAssertFalse(store.gitView(for: "@2") === first)
        first.apply(snapshot)
        first.perform(.tab(.stashes))
        first.perform(.enter)
        // Another Window selected and this one again: as it was left.
        first.suspend()
        first.resume()
        XCTAssertEqual(first.tab, .stashes)
        XCTAssertEqual(first.list, .files)
        XCTAssertEqual(first.level.owner?.id, "stash:s1")
        XCTAssertEqual(store.gitView(for: "@2").tab, .changes)
    }
}
