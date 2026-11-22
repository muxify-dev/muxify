import Foundation

/// The Session Path reads and the visit write that need no Topic, Window or Pane. The command line serves them to
/// the phone; a Host Server request for a Remote App Window would call the same two functions.
extension EnvironmentService {
    /// This machine's Session Paths and Worktrees, ranked for `query` as Go to… ranks them, by this machine's visits.
    /// `tiebreak` is the Go to… palette's, and `home` is the folder that a row's path shows as `~`.
    public func rankedSessionPaths(query: String, tiebreak: [PaletteTiebreak], home: String) -> Result<[RankedSessionPath], TopicFailure> {
        do {
            let rows = SessionPathRows.build(sessionPaths: sessionPaths, windows: try serverSnapshot().windows, records: try store.read().records)
            return .success(SessionPathRanking.rank(rows, query: query, visits: try VisitStore(paths: paths).times(), tiebreak: tiebreak, home: home))
        } catch { return .failure(failure(error, phase: .nothingChanged)) }
    }

    /// Records that a Session opened at `directory` at `now`: a visit to the SessionPath or Worktree that holds the
    /// folder, as a look at the Session in the app records it, else to the folder itself. It gives the visited folder.
    public func recordVisit(opening directory: Folder, at now: Date) -> Result<Folder, TopicFailure> {
        let visited = SessionChoice.containing(directory, in: sessionPaths)?.directory ?? directory
        do {
            try VisitStore(paths: paths).add([.directory(visited.real): now])
            return .success(visited)
        } catch { return .failure(failure(error, phase: .nothingChanged)) }
    }
}
