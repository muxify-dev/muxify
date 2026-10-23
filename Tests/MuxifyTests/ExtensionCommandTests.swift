import XCTest
@testable import MuxifyCore

final class ExtensionCommandTests: XCTestCase {
    func testInstalledSymlinkFindsBundledPayloadsAndInstallationIsIdempotent() throws {
        let root = try TestDirectory()
        let fm = FileManager.default
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let resources = root.url.appendingPathComponent("My App/Contents/Resources")
        let home = root.url.appendingPathComponent("home")
        let bin = home.appendingPathComponent(".local/bin")
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let bundledBin = resources.appendingPathComponent("bin")
        try fm.createDirectory(at: bundledBin, withIntermediateDirectories: true)
        try fm.copyItem(at: repository.appendingPathComponent(".build/debug/muxify"), to: bundledBin.appendingPathComponent("muxify"))
        try fm.copyItem(at: repository.appendingPathComponent("extensions"), to: resources.appendingPathComponent("extensions"))
        for path in [".claude", ".codex", ".config/opencode", ".pi/agent"] {
            try fm.createDirectory(at: home.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        let config = home.appendingPathComponent(".claude/settings.json")
        try "{\"unrelated\": true}".write(to: config, atomically: true, encoding: .utf8)
        let alias = bin.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: resources.appendingPathComponent("bin/muxify"))
        let command = bin.appendingPathComponent("muxify")
        try fm.createSymbolicLink(atPath: command.path, withDestinationPath: "alias")
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["CODEX_HOME"] = nil
        guard (try? CommandRunner().run(CommandInvocation(executable: "/bin/sh", arguments: ["-c", "command -v jq && command -v python3 && codex app-server --help </dev/null | grep -q 'codex app-server'"]), environment: environment)) != nil else {
            throw XCTSkip("The Extension installer requires jq, python3 and a codex with app-server")
        }
        let invocation = CommandInvocation(executable: command.path, arguments: ["extensions", "install"])
        let first = try CommandRunner().run(invocation, environment: environment)
        let installed = try Data(contentsOf: config)
        let second = try CommandRunner().run(invocation, environment: environment)
        XCTAssertEqual(try Data(contentsOf: config), installed)
        for agent in ["claude", "codex", "opencode", "pi"] {
            XCTAssertTrue(first.contains("\(agent): installed"), first)
            XCTAssertTrue(second.contains("\(agent): updated"), second)
        }
        let json = try JSONSerialization.jsonObject(with: installed) as! [String: Any]
        XCTAssertEqual(json["unrelated"] as? Bool, true)
        XCTAssertTrue(fm.fileExists(atPath: home.appendingPathComponent(".claude/settings.json.bak").path))
        XCTAssertTrue(fm.fileExists(atPath: home.appendingPathComponent(".config/opencode/plugins/muxify-status/tui.js").path))
    }
}
