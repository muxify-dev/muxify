import XCTest
@testable import MuxifyCore

/// The script's output from a machine where the Config's root goes through a symlink: `/h/Dev` leads to `/h/real`.
/// None of these folders exist on this Mac, as on a Remote Environment.
final class SessionPathDiscoveryOutputTests: XCTestCase {
    private let roots = [SessionPathRoot(path: "~/Dev/*")]

    private func output(_ lines: [String]) -> String {
        lines.map { $0.replacingOccurrences(of: "|", with: Tmux.separator) }.joined(separator: "\n") + "\n"
    }

    func testEveryCheckoutThatTheConfigFindsShowsWithTheConfigsPath() {
        let found = output([
            "H|/h", "R|0",
            "D|/h/Dev/app|plain|/h/real/app",
            "W|worktree /h/real/app", "W|branch refs/heads/main", "W|",
            "W|worktree /h/real/app-fix", "W|branch refs/heads/fix", "W|",
            "W|worktree /h/real/app/.trees/inside", "W|branch refs/heads/inside",
            "D|/h/Dev/app-fix|plain|/h/real/app-fix",
            "W|worktree /h/real/app", "W|branch refs/heads/main", "W|",
            "W|worktree /h/real/app-fix", "W|branch refs/heads/fix",
        ])
        let sessionPaths = SessionPathDiscovery.sessionPaths(in: found, roots: roots, aliases: [:])
        XCTAssertEqual(sessionPaths.map(\.folder.path), ["/h/Dev/app"])
        XCTAssertEqual(sessionPaths.first?.layout.worktrees.map(\.folder.path), ["/h/Dev/app", "/h/Dev/app-fix", "/h/Dev/app/.trees/inside"],
                       "a Worktree beside its repository shows as the Config found it, not as git gives it")
    }
}
