import Foundation

/// Where a Window's Session belongs in its Topic: the Project it works on, and the Worktree when the record
/// remembers one. The longest remembered directory that holds the Session directory decides; without one,
/// the Config Project that holds it, else the directory itself.
public struct TopicLocation {
    public let project: Project
    public let worktree: Folder?

    /// Topics are local, so the record's paths and the Session directory resolve on this Mac.
    public init(of window: TmuxWindow, record: TopicRecord?, projects: [Project]) {
        let directory = Folder.local(window.sessionPath)
        let home = record?.homeProject.map(Folder.local)
        var candidates: [(directory: Folder, project: Folder, worktree: Folder?)] = []
        if let home { candidates.append((home, home, nil)) }
        for session in record?.sessions ?? [] {
            guard let path = session["project_path"]?.string else { continue }
            let project = Folder.local(path)
            candidates.append((project, project, nil))
            if let worktree = session["worktree_path"]?.string.map(Folder.local) { candidates.append((worktree, project, worktree)) }
        }
        let match = candidates.filter { $0.directory.contains(directory) }
            .max { ($0.directory.real.count, $0.worktree != nil ? 1 : 0) < ($1.directory.real.count, $1.worktree != nil ? 1 : 0) }
        let folder = match?.project ?? Project.containing(directory, in: projects)?.folder ?? directory
        let project = Project.named(at: folder, in: projects)
        self.project = project.name.isEmpty ? Project(folder: folder, name: "Unknown Project") : project
        worktree = match?.worktree
    }
}
