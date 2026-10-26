import XCTest
@testable import MuxifyCore

final class SessionPathCacheTests: XCTestCase {
    private var stateHome: URL!
    private var paths: MuxifyPaths!
    private let roots = [SessionPathRoot(path: "~/Dev/*")]
    private let output = ["H|/h", "R|0", "D|/h/Dev/app|directory|/h/Dev/app", "D|/h/Dev/lib|directory|/h/Dev/lib"]
        .map { $0.replacingOccurrences(of: "|", with: Tmux.separator) }.joined(separator: "\n") + "\n"

    override func setUpWithError() throws {
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("muxify-cache-" + UUID().uuidString)
        stateHome = state
        paths = MuxifyPaths(environment: ["XDG_STATE_HOME": state.path], home: "/nowhere")
        addTeardownBlock { try? FileManager.default.removeItem(at: state) }
    }

    func testASavedOutputGivesTheSessionPathsWithTheCurrentAliasesAfterARestart() {
        let arguments = SessionPathDiscovery.arguments(for: roots)
        XCTAssertNil(SessionPathCache(file: paths.sessionPathCache(remote: nil)).output(for: arguments), "no file is no cache")
        SessionPathCache(file: paths.sessionPathCache(remote: nil)).save(output, for: arguments)

        let restarted = SessionPathCache(file: MuxifyPaths(environment: ["XDG_STATE_HOME": stateHome.path], home: "/nowhere").sessionPathCache(remote: nil))
        let cached = restarted.output(for: arguments)
        XCTAssertEqual(cached, output)
        let sessionPaths = cached.map { SessionPathDiscovery.sessionPaths(in: $0, roots: roots, aliases: ["/h/Dev/lib": "Library"]) } ?? []
        XCTAssertEqual(sessionPaths.map(\.displayName), ["app", "Library"], "an alias the Config gained since the save applies")
    }

    func testAnOutputForOtherRootsOrDepthsIsNoCache() {
        let cache = SessionPathCache(file: paths.sessionPathCache(remote: nil))
        cache.save(output, for: SessionPathDiscovery.arguments(for: roots))
        for other in [[SessionPathRoot(path: "~/Dev/*", depth: 1)], [SessionPathRoot(path: "~/Src/*")], roots + [SessionPathRoot(path: "~")]] {
            XCTAssertNil(cache.output(for: SessionPathDiscovery.arguments(for: other)), "\(other)")
        }
        XCTAssertEqual(cache.output(for: SessionPathDiscovery.arguments(for: [SessionPathRoot(path: "~/Dev/*", displayDepth: 2)])), output,
                       "display_depth applies when the output is parsed, so it keeps the cache")
    }

    func testAnUnreadableFileIsNoCacheAndTheNextSaveReplacesIt() throws {
        let file = paths.sessionPathCache(remote: nil)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: file)
        let cache = SessionPathCache(file: file)
        let arguments = SessionPathDiscovery.arguments(for: roots)
        XCTAssertNil(cache.output(for: arguments))
        cache.save(output, for: arguments)
        XCTAssertEqual(cache.output(for: arguments), output)
    }

    func testSavingTheSameOutputAgainLeavesTheFile() throws {
        let file = paths.sessionPathCache(remote: nil)
        let cache = SessionPathCache(file: file)
        let arguments = SessionPathDiscovery.arguments(for: roots)
        let inode = { try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? Int }
        cache.save(output, for: arguments)
        let first = try inode()
        cache.save(output, for: arguments)
        XCTAssertEqual(try inode(), first, "an unchanged output is not written again")
        cache.save(output + "D\(Tmux.separator)/h/Dev/new\(Tmux.separator)directory\(Tmux.separator)/h/Dev/new\n", for: arguments)
        XCTAssertNotEqual(try inode(), first, "a changed output replaces the file")
    }

    func testEachEnvironmentHasItsOwnFileInTheStateFolder() {
        let folder = paths.state.appendingPathComponent("session-paths")
        let files = [nil, "local", "Build Box", "a/b", "../x", "a%2Fb"].map { paths.sessionPathCache(remote: $0) }
        XCTAssertEqual(Set(files).count, files.count, "\(files.map(\.lastPathComponent))")
        for file in files {
            XCTAssertEqual(file.deletingLastPathComponent().path, folder.path, file.path)
        }
        XCTAssertEqual(files[0].lastPathComponent, "local.json")
    }
}
