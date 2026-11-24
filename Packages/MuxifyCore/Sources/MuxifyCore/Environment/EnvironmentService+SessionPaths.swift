import Foundation

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

    /// This machine's Go to… list as the Mac app gives it for the same state: the palette's topics and sessions
    /// Sources, with its `show`, `tiebreak` and `order`, by this machine's visits. The windows, agents and commands
    /// Sources are of an App Window only. `offersTopics` is the Config's `sidebar.board`, and `home` is the folder that
    /// a row's path shows as `~`.
    public func goTo(_ ask: GoToRequest, palette: CommandPaletteConfig, offersTopics: Bool, home: String, now: Date) -> Result<GoToAnswer, TopicFailure> {
        do {
            let snapshot = try serverSnapshot()
            let contents = try store.read()
            let marks = AgentMarks(snapshot.agents, notifications: notifications)
            let board = Board(records: contents.records, openPlaces: contents.openPlaces, boardSessions: contents.boardSessions,
                              windows: snapshot.windows, marks: marks, topics: topics)
            let input = GoToInput(board: offersTopics ? board : nil, records: contents.records, windows: snapshot.windows, sessionPaths: sessionPaths,
                                  sessionMarks: marks.sessions, tags: topics.tags, visits: try VisitStore(paths: paths).times(),
                                  current: ask.currentSession.map(GoToLocation.session), home: home, now: now)
            return .success(GoToAnswer(input.list(palette.sources, query: ask.query, tagFilter: ask.tag, rules: palette.rules, order: palette.order,
                                                  payload: { $0 })))
        } catch { return .failure(failure(error, phase: .nothingChanged)) }
    }

    /// Records that a client shows the Session named `name` at `now`, with the keys that a look at it in the app
    /// stamps (`VisitKey.keys`). A name that no running Session has fails, and records nothing.
    public func recordVisit(toSession name: String, at now: Date) -> Result<Void, TopicFailure> {
        do {
            let snapshot = try serverSnapshot()
            let open = Set(try store.read().records.filter { $0.settledAt == nil }.map(\.id))
            guard let window = snapshot.windows.first(where: { $0.sessionName == name }) else { throw TopicRequestError.sessionUnavailable(name) }
            let keys = VisitKey.keys(of: window, group: .visited(window, open: open), sessionPaths: sessionPaths,
                                     folders: .local)
            try VisitStore(paths: paths).add(Dictionary(uniqueKeysWithValues: keys.map { ($0, now) }))
            return .success(())
        } catch { return .failure(failure(error, phase: .nothingChanged)) }
    }
}
