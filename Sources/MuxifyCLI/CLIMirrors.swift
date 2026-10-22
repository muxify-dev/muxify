import MuxifyCore

extension EnvironmentCommand {
    /// The verbs that send this request (ADR 0039). No default, so a new request does not compile until it names
    /// its verbs.
    var mirror: CLIMirror {
        switch self {
        case .list: .verb(.topicList)
        case .show: .verbs([.topicOpen, .topicShow, .topicStatus, .topicDiff, .topicExec])
        case .create: .verb(.topicNew)
        case .addSession: .verb(.topicAddSession)
        case .settle: .verb(.topicSettle)
        case .forget: .verb(.topicForget)
        case .move: .verbs([.windowMove, .windowRemoveFromTopic])
        case .removeFromTopic, .removeAndKill: .verb(.sessionRemoveFromTopic)
        case .rename: .verb(.topicRename)
        case .reopen: .verb(.topicReopen)
        case .startFresh: .verb(.topicStartFresh)
        case .moveSession: .verb(.sessionMove)
        case .sortSessions: .verb(.topicSortSessions)
        case .lock: .verb(.sessionLock)
        case .unlock: .verb(.sessionUnlock)
        case .snooze: .verb(.topicSnooze)
        case .unsnooze: .verb(.topicUnsnooze)
        case .tags: .verb(.topicTag)
        case .newWindow: .verb(.windowNew)
        case .newSession: .verb(.sessionNew)
        case .renameSession: .verb(.sessionRename)
        case .renameWindow: .verb(.windowRename)
        case .moveWindow: .verb(.windowMove)
        case .killWindow: .verb(.windowKill)
        case .killSession: .verb(.sessionKill)
        case .pin: .verb(.topicPin)
        case .unpin: .verb(.topicUnpin)
        case .moveCard: .verb(.topicMove)
        case .startZen: .verb(.zenStart)
        case .endZen: .verb(.zenEnd)
        case .markRead(let change, let scope): .verb(.markRead(change, scope: scope))
        case .markAllRead: .verb(.markAllRead)
        }
    }
}
