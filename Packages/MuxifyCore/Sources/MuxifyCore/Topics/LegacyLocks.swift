import Foundation

extension BoardSession {
    /// Moves each Lock that an older Muxify kept in the tmux option `legacyOption` into the `guest_sessions` table, with
    /// the order that the option had, then removes the option. The new Lock's id is the Session's `sessionRecordID`, so
    /// two Muxify processes that import one Session at the same time make one row. A Session in an open Topic had no
    /// Lock, so only its option goes. `run` runs one tmux command. Once every command ran, `snapshot` is as tmux has
    /// it now, so its reader needs no second read. True when there was anything to import.
    @discardableResult
    public static func importLegacy(from snapshot: inout TmuxSnapshot, into store: TopicStore, run: ([String]) throws -> Void) throws -> Bool {
        var seen: Set<String> = []
        let legacy = snapshot.windows.compactMap { window in
            window.legacyLockOrder.flatMap { seen.insert(window.sessionID).inserted ? (window: window, order: $0) : nil }
        }
        guard !legacy.isEmpty else { return false }
        let imported = try store.write { transaction -> [TmuxWindow] in
            let open = transaction.records.openTopicIDs
            let noTopic = legacy.filter { $0.window.topicID.map { !open.contains($0) } ?? true }
            for (window, order) in noTopic { transaction.importBoardSession(BoardSession(session: window, order: order, snapshot: snapshot)) }
            return noTopic.map(\.window)
        }
        for window in imported { try run(["set-option", "-t", window.sessionID, "@muxify_session_id", window.sessionRecordID]) }
        for (window, _) in legacy { try run(["set-option", "-u", "-t", window.sessionID, legacyOption]) }
        let importedSessions = Set(imported.map(\.sessionID))
        for index in snapshot.windows.indices where snapshot.windows[index].legacyLockOrder != nil {
            if importedSessions.contains(snapshot.windows[index].sessionID) {
                snapshot.windows[index].savedSessionID = snapshot.windows[index].sessionRecordID
            }
            snapshot.windows[index].legacyLockOrder = nil
        }
        return true
    }
}
