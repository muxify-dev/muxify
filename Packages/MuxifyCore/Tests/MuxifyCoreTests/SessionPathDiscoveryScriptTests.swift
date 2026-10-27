import XCTest
@testable import MuxifyCore

/// The discovery script on real folders, with more folders than it has workers.
final class SessionPathDiscoveryScriptTests: XCTestCase {
    private var home = ""

    override func setUpWithError() throws {
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("muxify-discovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        // git prints real paths: /private/var, not /var.
        home = String(cString: realpath(made.path, nil))
        addTeardownBlock { [home] in try? FileManager.default.removeItem(atPath: home) }
    }

    private func git(_ arguments: [String]) throws {
        _ = try CommandRunner().run(CommandInvocation(executable: "/usr/bin/env", arguments: ["git", "-c", "user.name=t", "-c", "user.email=t@t"] + arguments),
                                    environment: ["HOME": home, "PATH": "/usr/bin:/bin:/opt/homebrew/bin", "GIT_CONFIG_NOSYSTEM": "1"])
    }

    private func run(_ shell: String, _ script: String, _ roots: [SessionPathRoot]) throws -> String {
        try CommandRunner().run(CommandInvocation(executable: shell, arguments: ["-c", script, "muxify"] + SessionPathDiscovery.arguments(for: roots)),
                                environment: ["HOME": home, "PATH": "/usr/bin:/bin:/opt/homebrew/bin"])
    }

    func testTheParallelScriptPrintsEachFolderWholeAndInOrderInEveryShell() throws {
        let fm = FileManager.default
        let directories = ["dir0", "dir1", "dir2", "dir3", " my notes\\"]
        let repositories = (0..<6).map { "repo\($0)" }
        for folder in (directories + repositories).map({ "code/" + $0 }) + ["more/sub1", "more/sub2", "more/lib", "trees"] {
            try fm.createDirectory(atPath: "\(home)/\(folder)", withIntermediateDirectories: true)
        }
        for repository in repositories + ["../more/lib"] {
            try git(["-C", "\(home)/code/\(repository)", "init", "-q", "-b", "main"])
            try git(["-C", "\(home)/code/\(repository)", "commit", "-q", "--allow-empty", "-m", "x"])
        }
        try git(["-C", "\(home)/code/repo0", "worktree", "add", "-q", "\(home)/trees/repo0-fix", "-b", "fix"])
        try git(["clone", "-q", "--bare", "\(home)/code/repo1", "\(home)/code/bare"])
        try git(["-C", "\(home)/code/bare", "worktree", "add", "-q", "\(home)/code/bare/main", "main"])

        let roots = [SessionPathRoot(path: "~/code/*"), SessionPathRoot(path: "~/more", depth: 1),
                     SessionPathRoot(path: "~/missing"), SessionPathRoot(path: "~/code/repo0", displayDepth: 2)]
        let parallel = try run("/bin/sh", SessionPathDiscovery.script, roots)
        let serial = try run("/bin/sh", SessionPathDiscovery.script.replacingOccurrences(of: "width=8", with: "width=1"), roots)
        XCTAssertTrue(SessionPathDiscovery.script.contains("width=8"), "the script names its width")
        XCTAssertEqual(parallel, serial, "8 workers print what one worker prints")
        if fm.isExecutableFile(atPath: "/bin/dash") {
            XCTAssertEqual(try run("/bin/dash", SessionPathDiscovery.script, roots), parallel, "dash, the sh of Debian and Ubuntu")
        }
        XCTAssertEqual(parallel.split(separator: "\n").filter { $0.hasPrefix("R") }.map { $0.components(separatedBy: Tmux.separator)[1] },
                       ["0", "1", "2", "3"])

        let sessionPaths = SessionPathDiscovery.sessionPaths(in: parallel, roots: roots, aliases: [:])
        let relative = { (sessionPath: SessionPath) in String(sessionPath.folder.path.dropFirst(self.home.count + 1)) }
        XCTAssertEqual(sessionPaths.map(relative),
                       ["code/ my notes\\", "code/bare", "code/dir0", "code/dir1", "code/dir2", "code/dir3",
                        "code/repo0", "code/repo1", "code/repo2", "code/repo3", "code/repo4", "code/repo5",
                        "more/lib", "more/sub1", "more/sub2"])
        XCTAssertEqual(sessionPaths.filter { $0.layout != .directory }.map(relative),
                       ["code/bare", "code/repo0", "code/repo1", "code/repo2", "code/repo3", "code/repo4", "code/repo5", "more/lib"])
        XCTAssertEqual(sessionPaths[6].name, "repo0", "the first root to find a folder names it")
        XCTAssertEqual(sessionPaths[6].layout, .plainRepository([
            Worktree(path: "\(home)/code/repo0", branch: "main"), Worktree(path: "\(home)/trees/repo0-fix", branch: "fix"),
        ]))
        guard case .bareRepository(let worktrees) = sessionPaths[1].layout else { return XCTFail("bare: \(sessionPaths[1].layout)") }
        XCTAssertEqual(worktrees.map(\.folder.path), ["\(home)/code/bare/main"])
        for sessionPath in sessionPaths[7...12] {
            XCTAssertEqual(sessionPath.layout, .plainRepository([Worktree(path: sessionPath.folder.path, branch: "main")]),
                           "each folder keeps its own git worktree lines")
        }
    }
}
