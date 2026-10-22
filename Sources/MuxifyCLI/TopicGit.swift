import Foundation
import MuxifyCore

/// git in the top folder of one Session's repository. Every run uses `--no-optional-locks`, so a read never takes the
/// index lock away from the user's own git command.
struct Git {
    struct Failure: Error {
        let message: String
    }

    /// The commit of git's empty tree: what a diff starts from in a repository with no commit.
    static let emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
    static let timeout: TimeInterval = 60
    /// The git that MuxifyCore runs for Worktrees, in the C locale so that its messages can be read.
    private static let command = ["/usr/bin/git", "--no-optional-locks"]
    private static let inherited = ProcessInfo.processInfo.environment.merging(["LC_ALL": "C"]) { $1 }

    let directory: String
    var environment = Git.inherited

    /// The repository whose work tree holds `directory`, or nil when no work tree holds it.
    static func repository(holding directory: String) throws -> Git? {
        let child = TopicExec.child(command + ["rev-parse", "--show-toplevel"], in: directory, timeout: timeout, environment: inherited)
        if case .exited(128) = child.outcome {
            let problem = String(decoding: child.stderr, as: UTF8.self)
            if problem.contains("not a git repository") || problem.contains("must be run in a work tree") { return nil }
        }
        return Git(directory: String(decoding: try output(of: child, for: "rev-parse"), as: UTF8.self).trimmingCharacters(in: .newlines))
    }

    /// The standard output of `git <arguments>`. A run that exits with a status outside `success` throws.
    func run(_ arguments: [String], success: Set<Int32> = [0]) throws -> String {
        String(decoding: try runData(arguments, success: success), as: UTF8.self)
    }

    /// The standard output as git wrote it, for output such as a patch whose bytes need not be UTF-8.
    func runData(_ arguments: [String], success: Set<Int32> = [0]) throws -> Data {
        let child = TopicExec.child(Self.command + arguments, in: directory, timeout: Self.timeout, environment: environment)
        return try Self.output(of: child, for: arguments[0], success: success)
    }

    private static func output(of child: (outcome: TopicExec.Outcome, stdout: Data, stderr: Data), for command: String,
                               success: Set<Int32> = [0]) throws -> Data {
        switch child.outcome {
        case .exited(let status) where success.contains(status):
            return child.stdout
        case .exited(let status):
            let problem = String(decoding: child.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(message: "git \(command) exited with status \(status)" + (problem.isEmpty ? "" : ": " + problem))
        case .timedOut: throw Failure(message: "git \(command) did not exit in \(Int(timeout)) s")
        case .notStarted(let reason): throw Failure(message: "git \(command) did not start: \(reason)")
        }
    }

    /// The commit that the Session's work started from: the `base` that the Topic recorded for its Worktree when the
    /// repository still has it, else the merge base of HEAD and the default branch. Nil when neither is known.
    func base(recorded: String?) throws -> String? {
        if let recorded, try !run(["rev-parse", "--verify", "-q", "--end-of-options", recorded + "^{commit}"], success: [0, 1]).isEmpty {
            return recorded
        }
        guard try hasCommit, let branch = try defaultBranch() else { return nil }
        let base = try run(["merge-base", "HEAD", branch], success: [0, 1]).trimmingCharacters(in: .newlines)
        return base.isEmpty ? nil : base
    }

    /// The branch that `origin/HEAD` names, else a local `main` or `master`.
    private func defaultBranch() throws -> String? {
        let remote = try run(["symbolic-ref", "-q", "--short", "refs/remotes/origin/HEAD"], success: [0, 1])
            .trimmingCharacters(in: .newlines)
        if !remote.isEmpty { return remote }
        for branch in ["main", "master"] {
            if try !run(["rev-parse", "--verify", "-q", "refs/heads/" + branch], success: [0, 1]).isEmpty { return branch }
        }
        return nil
    }

    var hasCommit: Bool {
        get throws { try !run(["rev-parse", "--verify", "-q", "HEAD"], success: [0, 1]).isEmpty }
    }
}

/// One Session's `git status --porcelain=v2 --branch`, read into values.
struct GitStatus: Encodable, Equatable {
    struct Change: Encodable, Equatable {
        enum Kind: String, Encodable {
            case changed, renamed, copied, unmerged, untracked
        }

        var kind: Kind
        /// The path from the repository's top folder.
        var path: String
        /// The path before a rename or copy, else nil.
        var originalPath: String?
        /// The X and Y letters of `git status`: the index, then the work tree. "." is a side with no change.
        var index: String
        var worktree: String

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(kind, forKey: .kind)
            try values.encode(path, forKey: .path)
            try values.encode(originalPath, forKey: .originalPath)
            try values.encode(index, forKey: .index)
            try values.encode(worktree, forKey: .worktree)
        }

        private enum CodingKeys: String, CodingKey {
            case kind, path, index, worktree
            case originalPath = "original_path"
        }
    }

    /// Nil when HEAD is detached.
    var branch: String?
    /// The full id of HEAD. Nil before the first commit.
    var commit: String?
    var upstream: String?
    /// Nil when the branch has no upstream, or its upstream is gone.
    var ahead: Int?
    var behind: Int?
    /// The commit that `topic diff` starts from. Nil when it is not known.
    var base: String?
    var changes: [Change]

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(branch, forKey: .branch)
        try values.encode(commit, forKey: .commit)
        try values.encode(upstream, forKey: .upstream)
        try values.encode(ahead, forKey: .ahead)
        try values.encode(behind, forKey: .behind)
        try values.encode(base, forKey: .base)
        try values.encode(changes, forKey: .changes)
    }

    private enum CodingKeys: String, CodingKey { case branch, commit, upstream, ahead, behind, base, changes }

    /// `output` is from `git status --porcelain=v2 --branch -z`.
    init(porcelain output: String, base: String?) {
        self.base = base
        changes = []
        var fields = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)[...]
        while let field = fields.popFirst() {
            let words = field.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            func path(after count: Int) -> String { words.dropFirst(count).joined(separator: " ") }
            func letters() -> (String, String) {
                let xy = Array(words[1])
                return (String(xy.first ?? "."), String(xy.dropFirst().first ?? "."))
            }
            switch words.first {
            case "#" where words.count >= 3:
                let value = path(after: 2)
                switch words[1] {
                case "branch.oid": commit = value == "(initial)" ? nil : value
                case "branch.head": branch = value == "(detached)" ? nil : value
                case "branch.upstream": upstream = value
                case "branch.ab" where words.count == 4:
                    ahead = Int(words[2].dropFirst())
                    behind = Int(words[3].dropFirst())
                default: break
                }
            case "1" where words.count >= 9:
                let (x, y) = letters()
                changes.append(Change(kind: .changed, path: path(after: 8), index: x, worktree: y))
            case "2" where words.count >= 10:
                let (x, y) = letters()
                // With -z, the path before the rename or copy is the next field.
                changes.append(Change(kind: words[8].hasPrefix("C") ? .copied : .renamed, path: path(after: 9),
                                      originalPath: fields.popFirst(), index: x, worktree: y))
            case "u" where words.count >= 11:
                let (x, y) = letters()
                changes.append(Change(kind: .unmerged, path: path(after: 10), index: x, worktree: y))
            case "?" where words.count >= 2:
                changes.append(Change(kind: .untracked, path: path(after: 1), index: "?", worktree: "?"))
            default: break
            }
        }
    }

    /// The status as `git status --short --branch` prints it.
    var shortLines: [String] {
        var head = "## "
        switch (branch, commit) {
        case (let branch?, nil): head += "No commits yet on " + branch
        case (nil, _): head += "HEAD (no branch)"
        case (let branch?, _?):
            head += branch
            if let upstream {
                head += "..." + upstream
                switch (ahead ?? 0, behind ?? 0) {
                case _ where ahead == nil: head += " [gone]"
                case (0, 0): break
                case (let ahead, 0): head += " [ahead \(ahead)]"
                case (0, let behind): head += " [behind \(behind)]"
                case (let ahead, let behind): head += " [ahead \(ahead), behind \(behind)]"
                }
            }
        }
        return [head] + changes.map { change in
            let xy = change.kind == .untracked ? "??" : (change.index + change.worktree).replacingOccurrences(of: ".", with: " ")
            return xy + " " + (change.originalPath.map { $0 + " -> " } ?? "") + change.path
        }
    }

    static func read(_ git: Git, base: String?) throws -> GitStatus {
        GitStatus(porcelain: try git.run(["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"]), base: base)
    }
}

/// One Session's changes since its base, as a patch whose paths start with the Session's name, so that the patches
/// of all Sessions read as one changeset.
struct GitChanges: Encodable {
    struct File: Encodable, Equatable {
        /// The path from the repository's top folder.
        var path: String
        /// Nil for a binary file.
        var added: Int?
        var deleted: Int?

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(path, forKey: .path)
            try values.encode(added, forKey: .added)
            try values.encode(deleted, forKey: .deleted)
        }

        private enum CodingKeys: String, CodingKey { case path, added, deleted }
    }

    var base: String?
    var files: [File]
    /// As git wrote it: a text file that is not UTF-8 keeps its bytes, so the patch still applies.
    var patch: Data

    // A Session's JSON gives its base and files. The patch is one key for all Sessions.
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(base, forKey: .base)
        try values.encode(files, forKey: .files)
    }

    private enum CodingKeys: String, CodingKey { case base, files }

    /// The work tree against `base`, else against HEAD, with untracked files that git does not ignore as new files.
    /// The untracked files go into a copy of the index, so the user's index does not change.
    static func read(_ git: Git, base: String?, session: String) throws -> GitChanges {
        let from = try base ?? (git.hasCommit ? "HEAD" : Git.emptyTree)
        let index = FileManager.default.temporaryDirectory.appendingPathComponent("muxify-index-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: index) }
        let indexPath = try git.run(["rev-parse", "--git-path", "index"]).trimmingCharacters(in: .newlines)
        let source = indexPath.hasPrefix("/") ? indexPath : (git.directory as NSString).appendingPathComponent(indexPath)
        if FileManager.default.fileExists(atPath: source) {
            try FileManager.default.copyItem(atPath: source, toPath: index.path)
        }
        var copy = git
        copy.environment["GIT_INDEX_FILE"] = index.path
        _ = try copy.run(["add", "--intent-to-add", "--", "."])
        let options = ["--no-color", "--no-ext-diff", "--no-textconv", "--no-relative", "--no-renames"]
        let patch = try copy.runData(["diff"] + options + ["--src-prefix=a/\(session)/", "--dst-prefix=b/\(session)/", from])
        let numstat = try copy.run(["diff"] + options + ["--numstat", "-z", from])
        let files = numstat.split(separator: "\0").compactMap { line -> File? in
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { return nil }
            return File(path: String(fields[2]), added: Int(fields[0]), deleted: Int(fields[1]))
        }
        return GitChanges(base: base, files: files, patch: patch)
    }
}

/// `topic status` and `topic diff`: git in each live Session's folder, all at the same time. A Session whose folder is
/// in no git repository has `"git": null`.
struct TopicGit {
    enum Report {
        case status
        /// `stat` prints a summary of the changeset, not the patch.
        case diff(stat: Bool)
    }

    let report: Report

    func run(_ targets: [TopicExec.Target], topic: TopicDetail, output: RequestInvocation.Output) throws {
        switch report {
        case .status:
            let results = TopicExec.atOnce(targets) { target in
                Result { try Git.repository(holding: target.directory).map { git in
                    try GitStatus.read(git, base: try git.base(recorded: target.session.worktree?.base))
                } }
            }
            switch output {
            case .json: try Self.print(Lines(topic: topic, targets: targets, results: results, patch: nil))
            case .text:
                for (target, result) in zip(targets, results) {
                    let lines: [String]
                    switch result {
                    case .success(let status?): lines = status.shortLines
                    case .success(nil): lines = ["not in a git repository"]
                    case .failure: lines = []
                    }
                    Swift.print((["==> \(target.session.name.oneLineField) <=="] + lines).joined(separator: "\n"))
                }
            }
            try Self.check(targets, results)
        case .diff(let stat):
            let results = TopicExec.atOnce(targets) { target in
                Result { try Git.repository(holding: target.directory).map { git in
                    try GitChanges.read(git, base: try git.base(recorded: target.session.worktree?.base), session: target.session.name)
                } }
            }
            let patch = results.compactMap { try? $0.get()?.patch }.reduce(Data(), +)
            switch output {
            case .json:
                // JSON holds text, so bytes that are not UTF-8 become U+FFFD here. The text output keeps them.
                try Self.print(Lines(topic: topic, targets: targets, results: results,
                                     patch: stat ? nil : String(decoding: patch, as: UTF8.self)))
            case .text: FileHandle.standardOutput.write(stat ? Data(try Self.stat(patch).utf8) : patch)
            }
            try Self.check(targets, results)
        }
    }

    /// The `git apply --stat` summary of `patch`: one line per file, then the totals.
    private static func stat(_ patch: Data) throws -> String {
        guard !patch.isEmpty else { return "" }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("muxify-patch-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try patch.write(to: file)
        return try Git(directory: FileManager.default.temporaryDirectory.path).run(["apply", "--stat", file.path])
    }

    private static func check<T>(_ targets: [TopicExec.Target], _ results: [Result<T, Error>]) throws {
        let failures = zip(targets, results).compactMap { target, result -> String? in
            guard case .failure(let error) = result else { return nil }
            return "\(target.session.name): " + message(error)
        }
        if !failures.isEmpty { throw CLIError(failures.joined(separator: "; ")) }
    }

    private static func print<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        Swift.print(String(decoding: try encoder.encode(value), as: UTF8.self))
    }

    /// The `--json` line: the Topic, each Session with its git value, and for `topic diff` the whole patch.
    private struct Lines<Value>: Encodable where Value: Encodable {
        struct Topic: Encodable {
            var id: String
            var label: String
        }

        struct Session: Encodable {
            var id: String
            var name: String
            var directory: String
            var git: Value?
            /// Why git failed in this Session, else null.
            var error: String?

            func encode(to encoder: Encoder) throws {
                var values = encoder.container(keyedBy: CodingKeys.self)
                try values.encode(id, forKey: .id)
                try values.encode(name, forKey: .name)
                try values.encode(directory, forKey: .directory)
                try values.encode(git, forKey: .git)
                try values.encode(error, forKey: .error)
            }

            private enum CodingKeys: String, CodingKey { case id, name, directory, git, error }
        }

        var topic: Topic
        var sessions: [Session]
        /// Only `topic diff` without `--stat` has this key.
        var patch: String?

        init(topic: TopicDetail, targets: [TopicExec.Target], results: [Result<Value?, Error>], patch: String?) {
            self.topic = Topic(id: topic.id, label: topic.label)
            sessions = zip(targets, results).map { target, result in
                var git: Value?
                var error: String?
                switch result {
                case .success(let value): git = value
                case .failure(let failure): error = TopicGit.message(failure)
                }
                return Session(id: target.session.id, name: target.session.name, directory: target.directory, git: git, error: error)
            }
            self.patch = patch
        }
    }

    private static func message(_ error: Error) -> String {
        (error as? Git.Failure)?.message ?? error.localizedDescription
    }
}
