import Foundation

/// The commits `C` copied in the Git View, to cherry-pick with `V` (CONTEXT.md, ADR 0041). They belong to the
/// repository, not to a Window: they are kept by its common git directory, which every Worktree shares, so a Git View
/// in any Worktree sees and pastes them. Kept while Muxify runs, not saved.
@MainActor @Observable
final class CopiedCommits {
    /// The full hashes copied in each repository, in the order they were copied.
    private var byRepository: [String: [String]] = [:]

    func shas(in repository: String) -> [String] {
        byRepository[repository] ?? []
    }

    func contains(_ sha: String, in repository: String) -> Bool {
        byRepository[repository]?.contains(sha) == true
    }

    /// `C`: copies the commit, or takes it out again.
    func toggle(_ sha: String, in repository: String) {
        var shas = shas(in: repository)
        if let index = shas.firstIndex(of: sha) { shas.remove(at: index) } else { shas.append(sha) }
        byRepository[repository] = shas.isEmpty ? nil : shas
    }

    /// Takes out these commits: what a paste took, so a commit copied since stays.
    func remove(_ removed: [String], in repository: String) {
        let shas = shas(in: repository).filter { !removed.contains($0) }
        byRepository[repository] = shas.isEmpty ? nil : shas
    }

    func clear(in repository: String) {
        byRepository[repository] = nil
    }
}
