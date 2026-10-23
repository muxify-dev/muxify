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
        git mv a.swift renamed.swift && printf 'let c = 3\\n' > c.swift && git add c.swift && git commit -q -m Move
        """, repository)
        let gitView = GitView(windowID: "@1")
        gitView.apply(try GitRepository.parseSnapshot(run(GitRepository.snapshotScript, repository)).get())
        gitView.perform(.tab(.branches))
        while gitView.selectedItem?.name != "feature" { gitView.perform(.down) }
        gitView.perform(.mark)
        while gitView.selectedItem?.name != "moved" { gitView.perform(.down) }
        let request = try XCTUnwrap(gitView.request())
        XCTAssertEqual(request.script, GitRepository.gitScript)
        let patch = GitPatch.parse(try run(request.script, request.arguments))
        XCTAssertEqual(patch.files.map(\.path), ["c.swift", "renamed.swift"])
        XCTAssertEqual(patch.files.map(\.change), [.added, .renamed])
        XCTAssertEqual(patch.additions, 1)
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

    private func branch(_ name: String, at sha: String, isHead: Bool = false) -> GitBranch {
        GitBranch(name: name, sha: sha, isHead: isHead, upstream: nil, track: "", date: nil, worktreePath: nil)
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
        XCTAssertEqual(gitView.discard?.path, "src/a.swift")
        gitView.closeDiscard()
        gitView.perform(.tab(.history))
        gitView.perform(.discard)
        XCTAssertNil(gitView.discard)
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
