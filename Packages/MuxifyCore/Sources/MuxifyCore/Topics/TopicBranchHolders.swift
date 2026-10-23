import Foundation

/// The Topics whose records remember a branch (ADR 0041): one of their remembered Sessions' Worktree has it as its
/// `branch`. Reopen checks that branch out when a Worktree's folder is gone, and starts again from `base` when the
/// branch is gone too, so deleting it loses that work for Reopen. Open, Dormant and Settled Topics all count.
public enum TopicBranchHolders {
    /// The records of `records` that remember `branch` in the repository whose own folder and Worktree folders are
    /// `repository`, in their order. A remembered Session is in the repository when its `repository_path` or its
    /// `worktree_path` is one of those folders, compared by real path (ADR 0022), so a record of another repository
    /// that has a branch of the same name is not one.
    public static func records(remembering branch: String, in repository: [Folder], among records: [TopicRecord]) -> [TopicRecord] {
        records.filter { record in
            record.sessions.contains { session in
                guard session["branch"]?.string == branch else { return false }
                return ["repository_path", "worktree_path"].contains { key in
                    guard let path = session[key]?.string, !path.isEmpty else { return false }
                    return repository.contains(Folder.local(path))
                }
            }
        }
    }
}
