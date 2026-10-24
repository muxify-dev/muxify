import Foundation
import MuxifyCore
import XCTest

/// The tmux binary for a test that runs real tmux. Without tmux the test skips, so a Mac without tmux can
/// run the other tests. With MUXIFY_REQUIRE_TMUX=1, as in CI, it fails: a run that skips these tests does
/// not prove the code that talks to tmux.
public func requireTmux(file: StaticString = #filePath, line: UInt = #line) throws -> String {
    _ = childProcessesSkipXcodeLibraryPaths
    if let binary = Tmux.binary { return binary }
    if ProcessInfo.processInfo.environment["MUXIFY_REQUIRE_TMUX"] == "1" {
        XCTFail("tmux is not installed, and MUXIFY_REQUIRE_TMUX=1 requires it", file: file, line: line)
    }
    throw XCTSkip("tmux is not installed", file: file, line: line)
}

// xcodebuild starts the test process with DYLD_LIBRARY_PATH and DYLD_FRAMEWORK_PATH set to its build folders,
// and every child inherits them. dyld then searches those folders for each library a child loads, so each tmux
// start takes about 17 ms instead of 11. Tests that run real tmux start thousands of processes, and this made
// MuxifyCoreTests about 40% slower under xcodebuild than under swift test. The test process has already loaded
// its libraries, so it no longer needs these variables.
private let childProcessesSkipXcodeLibraryPaths: Void = {
    unsetenv("DYLD_LIBRARY_PATH")
    unsetenv("DYLD_FRAMEWORK_PATH")
}()
