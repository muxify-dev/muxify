import XCTest
@testable import MuxifyCore

/// The Host CLI install with a real `sh` (and `dash` where there is one), a temporary HOME, a PATH of only the tools
/// it may use, and a `file://` base URL whose assets are small scripts that print a version line.
final class HostCLIScriptTests: XCTestCase {
    private let published = "muxify abc1234 200"
    private var root = ""
    private var home: String { root + "/home" }
    private var tools: String { root + "/tools" }
    private var assets: String { root + "/assets" }
    private var installed: String { home + "/.local/bin/muxify" }
    private var shells: [String] {
        ["/bin/sh", "/bin/dash"].filter(FileManager.default.isExecutableFile(atPath:))
    }

    override func setUpWithError() throws {
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("muxify-host-cli-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        root = String(cString: realpath(made.path, nil))
        addTeardownBlock { [root] in try? FileManager.default.removeItem(atPath: root) }
    }

    /// A fresh HOME, tools folder and assets for one run.
    private func reset(curl: Bool = true) throws {
        let fm = FileManager.default
        for folder in [home, tools, assets] {
            try? fm.removeItem(atPath: folder)
            try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        }
        for tool in ["sh", "uname", "tr", "readlink", "mkdir", "rm", "mv", "chmod"] + (curl ? ["curl"] : []) {
            let real = try XCTUnwrap(Self.which(tool), "no \(tool)")
            try fm.createSymbolicLink(atPath: "\(tools)/\(tool)", withDestinationPath: real)
        }
        try write(published + "\n", to: "\(assets)/version")
        for asset in ["muxify-darwin-arm64", "muxify-linux-aarch64", "muxify-linux-x86_64"] {
            try executable(printing: published, at: "\(assets)/\(asset)")
        }
    }

    private static func which(_ tool: String) -> String? {
        ["/bin", "/usr/bin"].map { "\($0)/\(tool)" }.first(where: FileManager.default.isExecutableFile(atPath:))
    }

    private func write(_ text: String, to path: String, mode: Int = 0o644) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
    }

    private func executable(printing line: String, at path: String) throws {
        try write("#!/bin/sh\necho '\(line)'\n", to: path, mode: 0o755)
    }

    private func run(_ shell: String, bundle: String? = nil, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let arguments = ["-c", HostCLI.script, "muxify", "file://\(assets)/", bundle ?? "\(root)/Applications/Muxify.app/Contents/Resources/bin/muxify"]
        let output = try CommandRunner().run(CommandInvocation(executable: shell, arguments: arguments),
                                             environment: ["HOME": home, "PATH": tools])
        XCTAssertEqual(output.filter { $0 == "\n" }.count, 1, "one result line: \(output)", file: file, line: line)
        return output.trimmingCharacters(in: .newlines)
    }

    private func versionLine(_ path: String) throws -> String {
        try CommandRunner().run(CommandInvocation(executable: path, arguments: ["--version"])).trimmingCharacters(in: .newlines)
    }

    private var leftover: Bool { FileManager.default.fileExists(atPath: installed + ".new") }

    func testNoMuxifyInstallsThePublishedOne() throws {
        for shell in shells {
            try reset()
            XCTAssertEqual(try run(shell), "installed abc1234 200", shell)
            XCTAssertEqual(try versionLine(installed), published, shell)
            XCTAssertFalse(leftover, shell)
        }
    }

    func testAnOlderOneIsUpdated() throws {
        for shell in shells {
            try reset()
            try executable(printing: "muxify old1234 100", at: installed)
            XCTAssertEqual(try run(shell), "updated old1234 100 -> abc1234 200", shell)
            XCTAssertEqual(try versionLine(installed), published, shell)
            XCTAssertFalse(leftover, shell)
        }
    }

    func testAnUnstampedBuildIsUpdated() throws {
        try reset()
        try executable(printing: "muxify dev 0", at: installed)
        XCTAssertEqual(try run("/bin/sh"), "updated dev 0 -> abc1234 200")
    }

    func testAnOlderOneOnThePathIsLeftAndOneIsInstalledInLocalBin() throws {
        try reset()
        try executable(printing: "muxify old1234 100", at: "\(tools)/muxify")
        let before = try String(contentsOfFile: "\(tools)/muxify", encoding: .utf8)
        XCTAssertEqual(try run("/bin/sh"), "updated old1234 100 -> abc1234 200")
        XCTAssertEqual(try String(contentsOfFile: "\(tools)/muxify", encoding: .utf8), before)
        XCTAssertEqual(try versionLine(installed), published)
    }

    func testTheSameOneIsCurrent() throws {
        for shell in shells {
            try reset()
            try executable(printing: published, at: installed)
            XCTAssertEqual(try run(shell), "current abc1234 200", shell)
        }
    }

    func testANewerOneIsKeptUnchanged() throws {
        for shell in shells {
            try reset()
            try executable(printing: "muxify new1234 300", at: installed)
            let before = try Data(contentsOf: URL(fileURLWithPath: installed))
            XCTAssertEqual(try run(shell), "kept new1234 300 (newer than abc1234 200)", shell)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: installed)), before, shell)
            XCTAssertFalse(leftover, shell)
        }
    }

    func testOneInsideAMuxifyAppIsSkipped() throws {
        for shell in shells {
            try reset()
            let bundled = "\(root)/Applications/Muxify.app/Contents/Resources/bin/muxify"
            try? FileManager.default.removeItem(atPath: "\(root)/Applications")
            try executable(printing: "muxify old1234 100", at: bundled)
            // The bundle path itself, the phone's last step.
            XCTAssertEqual(try run(shell), "skipped: app bundle \(bundled)", shell)
            // Install Command Line Tool's link in ~/.local/bin.
            try FileManager.default.createDirectory(atPath: home + "/.local/bin", withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: installed, withDestinationPath: bundled)
            XCTAssertEqual(try run(shell, bundle: "/nonexistent"), "skipped: app bundle \(bundled)", shell)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: installed), bundled, shell)
            XCTAssertEqual(try versionLine(bundled), "muxify old1234 100", shell)
        }
    }

    func testAVersionThatExitsTwoIsUpdated() throws {
        for shell in shells {
            try reset()
            try write("#!/bin/sh\necho 'usage: muxify <command>'\nexit 2\n", to: installed, mode: 0o755)
            XCTAssertEqual(try run(shell), "updated unknown -> abc1234 200", shell)
            XCTAssertEqual(try versionLine(installed), published, shell)
        }
    }

    func testNeitherCurlNorWgetFails() throws {
        for shell in shells {
            try reset(curl: false)
            XCTAssertEqual(try run(shell), "failed: neither curl nor wget", shell)
            XCTAssertFalse(FileManager.default.fileExists(atPath: installed), shell)
        }
    }

    func testWgetIsUsedWithoutCurl() throws {
        let curl = try XCTUnwrap(Self.which("curl"))
        try reset(curl: false)
        // wget -q -O <file> <url>, served by curl because wget does not read file:// URLs.
        try write("#!/bin/sh\n[ \"$1 $2\" = '-q -O' ] || exit 9\nexec \(curl) -fsSL -o \"$3\" \"$4\"\n", to: "\(tools)/wget", mode: 0o755)
        XCTAssertEqual(try run("/bin/sh"), "installed abc1234 200")
        XCTAssertEqual(try versionLine(installed), published)
    }

    func testAnUnknownMachineFails() throws {
        for shell in shells {
            try reset()
            try FileManager.default.removeItem(atPath: "\(tools)/uname")
            try write("#!/bin/sh\ncase $1 in -s) echo Linux ;; -m) echo riscv64 ;; esac\n", to: "\(tools)/uname", mode: 0o755)
            XCTAssertEqual(try run(shell), "failed: no Host CLI for linux riscv64", shell)
            XCTAssertFalse(FileManager.default.fileExists(atPath: installed), shell)
        }
    }

    func testALinuxMachineGetsItsAsset() throws {
        try reset()
        try FileManager.default.removeItem(atPath: "\(tools)/uname")
        try write("#!/bin/sh\ncase $1 in -s) echo Linux ;; -m) echo x86_64 ;; esac\n", to: "\(tools)/uname", mode: 0o755)
        for other in ["muxify-darwin-arm64", "muxify-linux-aarch64"] {
            try FileManager.default.removeItem(atPath: "\(assets)/\(other)")
        }
        XCTAssertEqual(try run("/bin/sh"), "installed abc1234 200")
    }

    func testADownloadWithTheWrongVersionFailsAndKeepsTheOldOne() throws {
        for shell in shells {
            try reset()
            for asset in ["muxify-darwin-arm64", "muxify-linux-aarch64", "muxify-linux-x86_64"] {
                try executable(printing: "muxify abc1234 199", at: "\(assets)/\(asset)")
            }
            try executable(printing: "muxify old1234 100", at: installed)
            let before = try Data(contentsOf: URL(fileURLWithPath: installed))
            let output = try run(shell)
            XCTAssertTrue(output.hasPrefix("failed: muxify-"), output)
            XCTAssertTrue(output.hasSuffix("prints 'muxify abc1234 199', not 'muxify abc1234 200'"), output)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: installed)), before, shell)
            XCTAssertFalse(leftover, shell)
        }
    }

    func testAMissingVersionFileFails() throws {
        try reset()
        try FileManager.default.removeItem(atPath: "\(assets)/version")
        XCTAssertEqual(try run("/bin/sh"), "failed: cannot fetch file://\(assets)/version")
    }

    func testTheBaseURLDefaultsToTheReleaseAndTheEnvironmentOverridesIt() {
        XCTAssertEqual(HostCLI.baseURL(environment: [:]), "https://github.com/muxify-dev/muxify/releases/download/cli-latest/")
        XCTAssertEqual(HostCLI.baseURL(environment: ["MUXIFY_CLI_BASE_URL": ""]), HostCLI.defaultBaseURL)
        XCTAssertEqual(HostCLI.baseURL(environment: ["MUXIFY_CLI_BASE_URL": "http://host.orb.internal:8000/"]),
                       "http://host.orb.internal:8000/")
    }
}
