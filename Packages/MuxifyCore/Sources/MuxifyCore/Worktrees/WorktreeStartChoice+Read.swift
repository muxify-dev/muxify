import Foundation

extension WorktreeStartChoice {
    /// Each local branch, newest commit first, with the Worktree that has it checked out.
    static let readScript = #"""
    cd "$1" 2>/dev/null || { echo "No folder is at $1." >&2; exit 3; }
    git worktree list --porcelain | awk '/^worktree /{w=substr($0,10)} /^branch refs\/heads\//{print "W\t" substr($0,19) "\t" w}'
    git for-each-ref --sort=-committerdate --format='B%09%(refname:short)' refs/heads
    """#

    public static func read(from path: String, scripts: any ScriptRunning) throws -> [WorktreeStartChoice] {
        var checkouts: [String: String] = [:]
        var branches: [String] = []
        for line in try scripts.runScript(readScript, arguments: [path], timeout: 20).split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            if fields.count == 3, fields[0] == "W" { checkouts[fields[1]] = fields[2] }
            if fields.count == 2, fields[0] == "B" { branches.append(fields[1]) }
        }
        return branches.map { WorktreeStartChoice(branch: $0, checkedOutAt: checkouts[$0]) }
    }
}
