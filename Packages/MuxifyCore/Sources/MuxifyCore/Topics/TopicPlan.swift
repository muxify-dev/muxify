import Foundation

enum TopicNaming {
    public static func slugify(_ title: String) -> String {
        let ascii = title.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        let words = ascii.components(separatedBy: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789").inverted).filter { !$0.isEmpty }
        var slug = ""
        for word in words {
            let candidate = slug.isEmpty ? word : slug + "-" + word
            if candidate.count > 28 {
                if slug.isEmpty { slug = String(word.prefix(28)) }
                break
            }
            slug = candidate
        }
        return slug.isEmpty ? "topic" : slug
    }

    public static func slug(title: String, records: [TopicRecord], excludingTopicID: String? = nil) -> String {
        let used = Set(records.filter { $0.id != excludingTopicID }.compactMap(\.slug))
        func available(_ slug: String) -> Bool { !used.contains(slug) }
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var number = 1
            while !available("untitled-\(number)") { number += 1 }
            return "untitled-\(number)"
        }
        let base = slugify(title)
        var slug = base
        var number = 2
        while !available(slug) { slug = "\(base)-\(number)"; number += 1 }
        return slug
    }
}

/// Where a Topic's first Session opens.
enum TopicWorkingCopy: Equatable {
    /// The SessionPath folder of a plain directory.
    case directory
    /// A Worktree the user picked in the SessionPath list.
    case worktree(Worktree)
    /// A Worktree the Topic creates on the branch `<slug>` at `commit`, in `root/<sessionPath name>/<slug>` for a bare
    /// and a plain repository alike.
    case newWorktree(at: String, root: String)
    /// A Worktree the Topic creates on the local branch `branch`, now at `commit`, in `root/<sessionPath name>/<branch>`.
    case branchWorktree(branch: String, commit: String, root: String)
}

extension TopicWorkingCopy {
    public struct SessionStart {
        public let directory: String
        /// The remembered-Session fields that name the Worktree; empty for the SessionPath folder.
        public let worktreeFields: [String: JSONValue]
        public let newWorktree: TopicPlan.NewWorktree?
    }

    /// `slug` names the branch and folder of a new Worktree.
    public func sessionStart(in sessionPath: SessionPath, slug: String) -> SessionStart {
        switch self {
        case .directory:
            return SessionStart(directory: sessionPath.folder.path, worktreeFields: [:], newWorktree: nil)
        case .worktree(let worktree):
            var fields: [String: JSONValue] = ["repository_path": .string(sessionPath.folder.path), "worktree_path": .string(worktree.folder.path), TopicWorktrees.createdKey: .bool(false)]
            fields["branch"] = worktree.branch.map(JSONValue.string)
            return SessionStart(directory: worktree.folder.path, worktreeFields: fields, newWorktree: nil)
        case .newWorktree(let commit, let root):
            let parent = (root as NSString).appendingPathComponent(sessionPath.name)
            let branches = Set((try? Shell.run("/usr/bin/git", ["for-each-ref", "--format=%(refname:short)", "refs/heads"], directory: sessionPath.folder.path))?.split(separator: "\n").map(String.init) ?? [])
            var branch = slug
            var number = 2
            while branches.contains(branch) || FileManager.default.fileExists(atPath: (parent as NSString).appendingPathComponent(branch)) {
                branch = "\(slug)-\(number)"; number += 1
            }
            let path = Folder.lexical((parent as NSString).appendingPathComponent(branch))
            return Self.made(TopicPlan.WorktreeSpec(repositoryPath: sessionPath.folder.path, path: path, branch: branch), commit: commit,
                             checkout: .newBranch)
        case .branchWorktree(let branch, let commit, let root):
            let parent = (root as NSString).appendingPathComponent(sessionPath.name)
            // A branch such as feature/x makes one folder, not two.
            let name = branch.replacingOccurrences(of: "/", with: "-")
            var folder = name
            var number = 2
            while FileManager.default.fileExists(atPath: (parent as NSString).appendingPathComponent(folder)) {
                folder = "\(name)-\(number)"; number += 1
            }
            let path = Folder.lexical((parent as NSString).appendingPathComponent(folder))
            return Self.made(TopicPlan.WorktreeSpec(repositoryPath: sessionPath.folder.path, path: path, branch: branch), commit: commit,
                             checkout: .existingBranch)
        }
    }

    /// A Worktree that Muxify makes: the record says so and keeps the commit it started at, so Settle may remove it.
    private static func made(_ worktree: TopicPlan.WorktreeSpec, commit: String, checkout: TopicPlan.NewWorktree.Checkout) -> SessionStart {
        SessionStart(directory: worktree.path,
                     worktreeFields: ["repository_path": .string(worktree.repositoryPath), "worktree_path": .string(worktree.path),
                                      "branch": .string(worktree.branch), TopicWorktrees.createdKey: .bool(true),
                                      TopicWorktrees.baseKey: .string(commit)],
                     newWorktree: TopicPlan.NewWorktree(worktree: worktree, commit: commit, checkout: checkout))
    }
}

/// The values that the Topic plans share: what git makes and what the executor runs.
public enum TopicPlan {
    public struct WorktreeSpec: Codable, Hashable, Sendable {
        public let repositoryPath: String
        public let path: String
        public let branch: String

        private enum CodingKeys: String, CodingKey {
            case path, branch
            case repositoryPath = "repository_path"
        }

        public var arguments: [String] { ["worktree", "add", "-b", branch, path] }
    }

    /// A Worktree that git makes before Muxify saves the record and runs `commands`, so a git
    /// failure leaves no Topic and no recorded Session behind.
    public struct NewWorktree: Equatable, Sendable {
        public enum Checkout: Equatable, Sendable {
            /// git makes the branch at `commit`.
            case newBranch
            /// The branch exists; `commit` is where it is now.
            case existingBranch
        }
        public let worktree: WorktreeSpec
        /// The full id of the commit the Worktree starts at.
        public let commit: String
        public var checkout = Checkout.newBranch
    }

    public enum Command: Equatable, Sendable {
        /// `base` is the commit that the remembered Session records. A branch that is gone starts again there.
        case restoreWorktree(WorktreeSpec, base: String?)
        case removeMergedWorktree(WorktreeSpec)
        case removeCleanWorktree(WorktreeSpec)
        case reopenSession(name: String, directory: String, windowName: String)
        case tmux([String])
        /// A `new-session` or `new-window` whose Session, Window and Pane go back to the caller in `TopicChange`.
        /// The executor asks tmux to print their ids. A plan has at most one.
        case tmuxMaking([String])
        /// Keys typed into the target's pane, `literal` as text rather than key names.
        case sendKeys(target: String, keys: [String], literal: Bool)
        case newTopicSession(name: String, directory: String)
        case removeTopicPlaceholder
    }
}

extension TopicRecord {
    /// An open Topic with no Session. The transaction gives it a place in the list.
    public init(newTopic id: String, title: String, slug: String, now: Date) {
        self.init(id: id, title: title.isEmpty ? nil : title, slug: slug)
        createdAt = ISO8601DateFormatter().string(from: now)
    }
}
