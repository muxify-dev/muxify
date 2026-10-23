import Foundation
import MuxifyCore
import XCTest

/// The tmux binary for a test that runs real tmux. Without tmux the test skips, so a Mac without tmux can
/// run the other tests. With MUXIFY_REQUIRE_TMUX=1, as in CI, it fails: a run that skips these tests does
/// not prove the code that talks to tmux.
public func requireTmux(file: StaticString = #filePath, line: UInt = #line) throws -> String {
    if let binary = Tmux.binary { return binary }
    if ProcessInfo.processInfo.environment["MUXIFY_REQUIRE_TMUX"] == "1" {
        XCTFail("tmux is not installed, and MUXIFY_REQUIRE_TMUX=1 requires it", file: file, line: line)
    }
    throw XCTSkip("tmux is not installed", file: file, line: line)
}
