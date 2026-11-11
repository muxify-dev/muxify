import XCTest
@testable import MuxifyCore

final class SessionPathDiscoveryTests: XCTestCase {
    private func load(_ text: String, at path: String = "/cfg/muxify/config.yaml") throws -> Config {
        try Config.load(path: path) { _ in text }.get()
    }

    private func discover(_ roots: [SessionPathRoot], aliases: [String: String], within folders: [String]? = nil) -> [SessionPath] {
        SessionPathDiscovery.output(for: roots, within: folders).map { SessionPathDiscovery.sessionPaths(in: $0, roots: roots, aliases: aliases) } ?? []
    }

    func testSessionsPathsTakeAGlobADepthAndADisplayDepth() throws {
        let config = try load("""
        sessions:
          paths:
            - path: ~/Dev/*/*
              display_depth: 2
            - path: ~/sessionPaths
              depth: 1
            - path: work
            - path: "~"
        """)
        XCTAssertEqual(config.problems, [])
        XCTAssertEqual(config.sessionRoots, [
            SessionPathRoot(path: "~/Dev/*/*", depth: 0, displayDepth: 2),
            SessionPathRoot(path: "~/sessionPaths", depth: 1, displayDepth: 1),
            SessionPathRoot(path: "/cfg/muxify/work", depth: 0, displayDepth: 1),
            SessionPathRoot(path: "~", depth: 0, displayDepth: 1),
        ], "~ stays for the machine that looks; a relative path starts at the Config's folder")
        XCTAssertEqual(config.sessionPaths, [], "loading never looks on disk")
    }

    func testTheOldSessionPathsSectionsAreProblemsThatNameTheirNewPlace() throws {
        for (text, message) in [("sessionPaths:\n  - path: ~/Dev/*", "unknown section \"sessionPaths\""),
                                ("projects:\n  paths: [{path: ~/src}]", "unknown section \"projects\""),
                                ("projects_aliases:\n  - ~/Dev/x: X", "unknown section \"projects_aliases\"")] {
            let config = try load(text)
            XCTAssertEqual(config.problems.map(\.message), [message], text)
            XCTAssertEqual(config.sessionRoots, [], text)
        }
    }

    func testWrongSessionsPathsShapesAreProblemsAndSkipTheirEntry() throws {
        for entry in ["wrong", "{display_depth: 2}", "{path: 42}", "{path: true}", "{path: ''}",
                      "{path: /tmp, display_depth: 0}", "{path: /tmp, display_depth: -1}", "{path: /tmp, display_depth: '2'}",
                      "{path: /tmp, depth: -1}", "{path: /tmp, depth: 1.5}", "{path: /tmp, color: red}"] {
            let config = try load("sessions:\n  paths: [\(entry)]")
            XCTAssertEqual(config.problems.count, 1, entry)
            XCTAssertEqual(config.problems.first?.line, 2, entry)
            XCTAssertEqual(config.sessionRoots, [], entry)
        }
        for text in ["sessions: 42", "sessions: [{path: /tmp}]", "sessions:\n  paths: {}", "sessions:\n  folders: []"] {
            XCTAssertFalse(try load(text).problems.isEmpty, text)
        }
    }

    func testDiscoveryNamesByDisplayDepthKeepsTheFirstRootAndFindsFoldersMadeLater() throws {
        let root = try TestDirectory()
        for name in ["alpha", "beta"] {
            try FileManager.default.createDirectory(at: root.url.appendingPathComponent("work/" + name), withIntermediateDirectories: true)
        }
        try Data().write(to: root.url.appendingPathComponent("work/file"))
        let roots = [SessionPathRoot(path: root.url.path + "/work/*", displayDepth: 2), SessionPathRoot(path: root.url.path + "/work/alpha")]
        XCTAssertEqual(discover(roots, aliases: [:]).map(\.name), ["work/alpha", "work/beta"])
        for name in ["gamma.app", "my notes"] {
            try FileManager.default.createDirectory(at: root.url.appendingPathComponent("work/" + name), withIntermediateDirectories: true)
        }
        XCTAssertEqual(discover(roots, aliases: [:]).map(\.name),
                       ["work/alpha", "work/beta", "work/gamma_app", "work/mynotes"],
                       "a folder made later is a SessionPath, named as tmux takes it")
    }

    func testDepthListsSubfoldersAndARepositoryIsOneSessionPathWithItsWorktrees() throws {
        let directory = try TestDirectory()
        // git prints real paths: /private/var, not /var.
        let home = String(cString: realpath(directory.url.path, nil))
        let fm = FileManager.default
        for folder in ["sessionPaths/app/src", "sessionPaths/lib/nested/deep", "sessionPaths/.cache", "sessionPaths/lib/.hidden", "dotfiles", "trees"] {
            try fm.createDirectory(atPath: "\(home)/\(folder)", withIntermediateDirectories: true)
        }
        let git = { (args: [String]) in
            _ = try CommandRunner().run(CommandInvocation(executable: "/usr/bin/env", arguments: ["git"] + args),
                                        environment: ["HOME": home, "PATH": "/usr/bin:/bin:/opt/homebrew/bin",
                                                      "GIT_CONFIG_NOSYSTEM": "1"])
        }
        try git(["-C", "\(home)/sessionPaths/app", "init", "-q", "-b", "main"])
        try git(["-C", "\(home)/sessionPaths/app", "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "x"])
        try git(["-C", "\(home)/sessionPaths/app", "worktree", "add", "-q", "\(home)/trees/fix", "-b", "fix"])

        let roots = [
            SessionPathRoot(path: "~/sessionPaths/", depth: 2),
            SessionPathRoot(path: "~/dotfiles"),
            SessionPathRoot(path: "~/missing", depth: 1),
            SessionPathRoot(path: "~/trees", depth: 1),
        ]
        let output = try CommandRunner().run(
            CommandInvocation(executable: "/bin/sh",
                              arguments: ["-c", SessionPathDiscovery.script, "muxify"] + SessionPathDiscovery.arguments(for: roots)),
            environment: ["HOME": home, "PATH": "/usr/bin:/bin:/opt/homebrew/bin"]
        )
        let sessionPaths = SessionPathDiscovery.sessionPaths(in: output, roots: roots, aliases: ["~/dotfiles": "Dotfiles"])
        // A SessionPath shows the Config's spelling, here through $HOME, so it keeps the /private that git gives too.
        let shown = home
        XCTAssertEqual(sessionPaths.map { $0.folder.path.replacingOccurrences(of: shown, with: "~") },
                       ["~/sessionPaths/app", "~/sessionPaths/lib", "~/sessionPaths/lib/nested", "~/dotfiles"],
                       "no repository subfolder, Worktree, hidden or missing folder is a SessionPath")
        XCTAssertEqual(sessionPaths[0].layout, .plainRepository([
            Worktree(path: "\(shown)/sessionPaths/app", branch: "main"), Worktree(path: "\(shown)/trees/fix", branch: "fix"),
        ]))
        XCTAssertEqual(SessionChoice.choices(of: sessionPaths[0]).map(\.name), ["app", "app/fix"])
        XCTAssertEqual(sessionPaths[3].displayName, "Dotfiles", "an alias with ~ means the home folder of the machine that looks")
    }

    func testDiscoveryWithinFoldersFindsOnlyTheSessionPathsThatHoldThemAsTheFullRunDoes() throws {
        let directory = try TestDirectory()
        let home = String(cString: realpath(directory.url.path, nil))
        for folder in ["sessionPaths/app/src", "sessionPaths/lib/nested/deep", "sessionPaths/other", "dotfiles"] {
            try FileManager.default.createDirectory(atPath: "\(home)/\(folder)", withIntermediateDirectories: true)
        }
        _ = try CommandRunner().run(CommandInvocation(executable: "/usr/bin/env", arguments: ["git", "-C", "\(home)/sessionPaths/app", "init", "-q"]),
                                    environment: ["HOME": home, "PATH": "/usr/bin:/bin:/opt/homebrew/bin", "GIT_CONFIG_NOSYSTEM": "1"])
        let roots = [SessionPathRoot(path: "\(home)/sessionPaths", depth: 2), SessionPathRoot(path: "\(home)/dotfiles")]
        let all = discover(roots, aliases: [:])
        let folders = ["\(home)/sessionPaths/app/src", "\(home)/sessionPaths/lib/nested/deep"]
        let within = discover(roots, aliases: [:], within: folders)
        XCTAssertEqual(within.map(\.name), ["app", "lib", "nested"])
        XCTAssertEqual(within, all.filter { sessionPath in within.contains { $0.folder.path == sessionPath.folder.path } })
        for folder in folders {
            XCTAssertEqual(SessionPath.containing(.local(folder), in: within), SessionPath.containing(.local(folder), in: all), folder)
        }
        XCTAssertEqual(discover(roots, aliases: [:], within: []), [])
    }

    func testALinkedWorktreeThatSortsFirstIsARowOfItsRepository() throws {
        let directory = try TestDirectory()
        let home = String(cString: realpath(directory.url.path, nil))
        try FileManager.default.createDirectory(atPath: "\(home)/code/zzz", withIntermediateDirectories: true)
        let git = { (args: [String]) in
            _ = try CommandRunner().run(CommandInvocation(executable: "/usr/bin/env", arguments: ["git"] + args),
                                        environment: ["HOME": home, "PATH": "/usr/bin:/bin:/opt/homebrew/bin",
                                                      "GIT_CONFIG_NOSYSTEM": "1"])
        }
        try git(["-C", "\(home)/code/zzz", "init", "-q", "-b", "main"])
        try git(["-C", "\(home)/code/zzz", "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "x"])
        try git(["-C", "\(home)/code/zzz", "worktree", "add", "-q", "\(home)/code/aaa-wt", "-b", "fix"])

        let roots = [SessionPathRoot(path: "\(home)/code/*")]
        let output = try CommandRunner().run(
            CommandInvocation(executable: "/bin/sh",
                              arguments: ["-c", SessionPathDiscovery.script, "muxify"] + SessionPathDiscovery.arguments(for: roots)),
            environment: ["HOME": home, "PATH": "/usr/bin:/bin:/opt/homebrew/bin"]
        )
        let sessionPaths = SessionPathDiscovery.sessionPaths(in: output, roots: roots, aliases: [:])
        XCTAssertEqual(sessionPaths.map(\.name), ["zzz"], "the repository is the SessionPath, not its Worktree")
        XCTAssertEqual(SessionChoice.choices(of: sessionPaths[0]).map(\.name), ["zzz", "zzz/aaa-wt"])
    }

    func testRemoteConfigFileOutput() {
        XCTAssertEqual(RemoteConfigFile.parse("/h/.config/muxify/config.yaml\npresent\nui:\n  header_height: 30\n")?.text,
                       "ui:\n  header_height: 30\n")
        XCTAssertEqual(RemoteConfigFile.parse("/h/.config/muxify/config.yaml\npresent\n")?.text, "")
        let missing = RemoteConfigFile.parse("/h/.config/muxify/config.yaml\nmissing\n")
        XCTAssertEqual(missing?.path, "/h/.config/muxify/config.yaml")
        XCTAssertNil(missing?.text)
        XCTAssertNil(RemoteConfigFile.parse("Welcome!\n"))
    }

    func testRemoteConfigOverridesOutput() {
        let paths = ["~/.config/muxify/config.override.yaml", "/etc/muxify.yaml", "~/none.yaml"]
        let output = "present\nui:\n  header_height: 40\n\nEND\npresent\nno newline\nEND\nmissing\n\nEND\n"
        let texts = RemoteConfigFile.parseOverrides(output, paths: paths, end: "END")
        XCTAssertEqual(texts?[paths[0]], "ui:\n  header_height: 40\n")
        XCTAssertEqual(texts?[paths[1]], "no newline")
        XCTAssertEqual(texts?.keys.contains(paths[2]), true)
        XCTAssertEqual(texts?[paths[2]], .some(nil))
        // Not one block per path: a failed read, which keeps what the App Window has.
        XCTAssertNil(RemoteConfigFile.parseOverrides("present\nx\nEND\n", paths: paths, end: "END"))
        XCTAssertNil(RemoteConfigFile.parseOverrides("Welcome!\n", paths: paths, end: "END"))
        XCTAssertNil(RemoteConfigFile.parseOverrides("present\nx\nEND\ntrailing", paths: Array(paths.prefix(1)), end: "END"))
    }

    func testTheRemoteOverridesScriptReadsPathsFromTheRemoteHome() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".config/muxify"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try "ui:\n  header_height: 40\n".write(to: home.appendingPathComponent(".config/muxify/local.yaml"), atomically: true, encoding: .utf8)
        try "no newline".write(to: home.appendingPathComponent("abs.yaml"), atomically: true, encoding: .utf8)
        let paths = ["~/.config/muxify/local.yaml", home.appendingPathComponent("abs.yaml").path, "~/missing.yaml"]
        let end = "muxify-override-end-test"
        let output = try Shell.run("/usr/bin/env", ["HOME=\(home.path)", "/bin/sh", "-c", RemoteConfigFile.overridesScript, "muxify"]
                                   + RemoteConfigFile.overridesArguments(paths, end: end))
        let texts = try XCTUnwrap(RemoteConfigFile.parseOverrides(output, paths: paths, end: end))
        XCTAssertEqual(texts[paths[0]], "ui:\n  header_height: 40\n")
        XCTAssertEqual(texts[paths[1]], "no newline")
        XCTAssertEqual(texts[paths[2]], .some(nil))
    }

    func testARemoteConfigMergesItsOverridesResolvedOnTheRemote() throws {
        let shown = "box:~/.config/muxify/config.yaml"
        let text = "override: [~/machine.yaml, local.yaml, /etc/muxify.yaml, ../up.yaml]\nui:\n  header_height: 30\n"
        let named = try RemoteConfigFile.load(text, shown: shown).get()
        XCTAssertEqual(named.overrides, ["box:~/machine.yaml", "box:~/.config/muxify/local.yaml",
                                         "box:/etc/muxify.yaml", "box:~/.config/up.yaml"])
        XCTAssertEqual(named.headerHeight, 30)

        let texts: [String: String?] = [
            "box:~/machine.yaml": "ui:\n  header_height: 40\n",
            "box:~/.config/muxify/local.yaml": "ui:\n  header_height: 50\n  bogus: 1\n",
            "box:/etc/muxify.yaml": nil,
        ]
        let merged = try RemoteConfigFile.load(text, shown: shown, overrides: texts).get()
        XCTAssertEqual(merged.headerHeight, 50)
        XCTAssertTrue(merged.problems.contains { $0.path == "box:~/.config/muxify/local.yaml" && $0.line == 3 },
                      "\(merged.problems)")

        let broken = RemoteConfigFile.load(text, shown: shown, overrides: ["box:~/machine.yaml": "ui: [\n"])
        guard case .failure(let error) = broken else { return XCTFail("a syntax error in an Override fails the load") }
        XCTAssertEqual(error.problem.path, "box:~/machine.yaml")
        var loaded = LoadedConfig()
        loaded.update(with: RemoteConfigFile.load(text, shown: shown, overrides: ["box:~/machine.yaml": "ui:\n  header_height: 40\n"]))
        loaded.update(with: broken)
        XCTAssertEqual(loaded.config.headerHeight, 40)
        XCTAssertEqual(loaded.problems.map(\.path), ["box:~/machine.yaml"])
    }
}
