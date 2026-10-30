/// The path of each verb of the command line, such as "topic settle". The CLI has one verb for each case, so a
/// mirror that names a case names a verb that exists.
public enum CLIVerbPath: String, CaseIterable, Sendable {
    case browserOpen = "browser open"
    case browserAvailable = "browser available"
    case browserTabs = "browser tabs"
    case browserSnapshot = "browser snapshot"
    case browserClick = "browser click"
    case browserFill = "browser fill"
    case browserPress = "browser press"
    case browserWait = "browser wait"
    case browserEval = "browser eval"
    case browserScreenshot = "browser screenshot"
    case browserClose = "browser close"
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
    case topicTag = "topic tag"
    case topicRename = "topic rename"
    case topicNote = "topic note"
    case topicReopen = "topic reopen"
    case topicStartFresh = "topic start-fresh"
    case topicPin = "topic pin"
    case topicUnpin = "topic unpin"
    case topicMove = "topic move"
    case topicChooseInPlay = "topic choose-in-play"
    case topicReplaceFromBench = "topic replace-from-bench"
    case topicMakeGuest = "topic make-guest"
    case topicEndGuest = "topic end-guest"
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
    case windowZoom = "window zoom"
    case windowKill = "window kill"
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
        case .move: .verb(.windowMove)
        case .addSessionToTopic, .toggleNewWorktree: .verb(.topicAddSession)
        case .rename: .verbs([.topicRename, .sessionRename, .windowRename])
        case .editTags: .verb(.topicTag)
        case .setTopicNote, .clearTopicNote: .verb(.topicNote)
        case .settleTopic: .verb(.topicSettle)
        case .forgetTopic: .verb(.topicForget)
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
        case .makeGuest: .verbs([.topicMakeGuest, .sessionLock])
        case .endGuest: .verbs([.topicEndGuest, .sessionUnlock])
        case .choosePane, .chooseWindow, .chooseSession: .verb(.windowMove)
        case .toggleIncludeTab: .noMirror("The Tab is the view of one App Window.")
        }
    }
}
