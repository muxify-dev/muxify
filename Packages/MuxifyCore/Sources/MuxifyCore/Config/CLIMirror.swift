/// The path of each verb of the command line, such as "topic snooze". The CLI has one verb for each case, so a
/// mirror that names a case names a verb that exists.
public enum CLIVerbPath: String, CaseIterable, Sendable {
    case browserOpen = "browser open"
    case browserAvailable = "browser available"
    case sessionOpen = "session open"
    case sessionLock = "session lock"
    case sessionUnlock = "session unlock"
    case sessionRemoveFromTopic = "session remove-from-topic"
    case sessionNew = "session new"
    case sessionRename = "session rename"
    case sessionKill = "session kill"
    case sessionMove = "session move"
    case sessionList = "session list"
    case extensionsInstall = "extensions install"
    case topicNew = "topic new"
    case topicOpen = "topic open"
    case topicAddSession = "topic add-session"
    case topicForget = "topic forget"
    case topicSettle = "topic settle"
    case topicSnooze = "topic snooze"
    case topicUnsnooze = "topic unsnooze"
    case topicTag = "topic tag"
    case topicRename = "topic rename"
    case topicReopen = "topic reopen"
    case topicStartFresh = "topic start-fresh"
    case topicPin = "topic pin"
    case topicUnpin = "topic unpin"
    case topicMove = "topic move"
    case topicSortSessions = "topic sort-sessions"
    case topicList = "topic list"
    case topicShow = "topic show"
    case topicStatus = "topic status"
    case topicDiff = "topic diff"
    case topicExec = "topic exec"
    case windowOpen = "window open"
    case windowMove = "window move"
    case windowRemoveFromTopic = "window remove-from-topic"
    case windowNew = "window new"
    case windowRename = "window rename"
    case windowKill = "window kill"
    case zenStart = "zen start"
    case zenEnd = "zen end"
    case agentList = "agent list"
    case agentConversation = "agent conversation"
    case topicMarkRead = "topic mark-read"
    case topicMarkUnread = "topic mark-unread"
    case sessionMarkRead = "session mark-read"
    case sessionMarkUnread = "session mark-unread"
    case windowMarkRead = "window mark-read"
    case windowMarkUnread = "window mark-unread"
    case agentMarkRead = "agent mark-read"
    case agentMarkUnread = "agent mark-unread"
    case markAllRead = "mark-all-read"

    public var words: [String] { rawValue.split(separator: " ").map(String.init) }
}

/// The CLI verbs that make the same change as a palette Action or Command (ADR 0039). Each palette type has an
/// exhaustive `mirror` switch, so a new Action does not compile until it names its verbs or says why it needs none.
public enum CLIMirror: Equatable, Sendable {
    case verbs([CLIVerbPath])
    /// The Action changes nothing that continues after the App Window closes, for this reason.
    case noMirror(String)

    public static func verb(_ path: CLIVerbPath) -> CLIMirror { .verbs([path]) }

    public var paths: [CLIVerbPath] {
        if case .verbs(let paths) = self { return paths }
        return []
    }
}

extension PaletteAction {
    public var mirror: CLIMirror {
        switch self {
        case .jumpTo: .verbs([.topicOpen, .sessionOpen, .windowOpen])
        case .markRead: .verbs([.topicMarkRead, .sessionMarkRead, .windowMarkRead, .agentMarkRead])
        case .markUnread: .verbs([.topicMarkUnread, .sessionMarkUnread, .windowMarkUnread, .agentMarkUnread])
        case .newSession: .verb(.sessionNew)
        case .selectNext, .selectPrev, .showActions: .noMirror("It moves the selection of the palette.")
        case .copyFolder, .copyTmuxTarget, .pasteFolder: .noMirror("It uses the macOS pasteboard.")
        case .revealFolder: .noMirror("It shows the folder in Finder.")
        case .snoozeTopic: .verb(.topicSnooze)
        case .move: .verb(.windowMove)
        case .addSessionToTopic, .toggleNewWorktree: .verb(.topicAddSession)
        case .rename: .verbs([.topicRename, .sessionRename, .windowRename])
        case .editTags: .verb(.topicTag)
        case .suggestTopicTitle: .noMirror("It changes only the title that the palette shows.")
        case .startZen: .verbs([.zenStart, .zenEnd])
        case .settleTopic: .verb(.topicSettle)
        case .forgetTopic: .verb(.topicForget)
        case .unsnoozeTopic: .verb(.topicUnsnooze)
        case .reopenTopic: .verb(.topicReopen)
        case .startTopicFresh: .verb(.topicStartFresh)
        case .pinTopic: .verb(.topicPin)
        case .unpinTopic: .verb(.topicUnpin)
        case .removeFromTopic: .verbs([.sessionRemoveFromTopic, .windowRemoveFromTopic])
        case .removeFromTopicAndKill: .verb(.sessionRemoveFromTopic)
        case .newWindow: .verb(.windowNew)
        case .killWindow: .verb(.windowKill)
        case .killSession: .verb(.sessionKill)
        case .lockSession: .verb(.sessionLock)
        case .unlockSession: .verb(.sessionUnlock)
        case .choosePane, .chooseWindow, .chooseSession: .verb(.windowMove)
        case .toggleIncludeTab: .noMirror("The Tab is the view of one App Window.")
        }
    }
}
