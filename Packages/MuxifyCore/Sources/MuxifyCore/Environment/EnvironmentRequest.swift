import Foundation

// The values an Environment request and its response are made of. They are a versioned contract: the CLI, the
// muxify://topic URL and a later server all send the same values, so the JSON form is pinned by tests.

/// A tmux id with its sigil, parsed once where a request comes in.
public struct PaneID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    /// `%` and a number, as tmux writes it.
    public init?(rawValue: String) {
        guard rawValue.first == "%", rawValue.count > 1, rawValue.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        self.rawValue = rawValue
    }
}

public struct WindowID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    /// `@` and a number, as tmux writes it.
    public init?(rawValue: String) {
        guard rawValue.first == "@", rawValue.count > 1, rawValue.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        self.rawValue = rawValue
    }
}

public struct SessionID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    /// `$` and a number, as tmux writes it.
    public init?(rawValue: String) {
        guard rawValue.first == "$", rawValue.count > 1, rawValue.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        self.rawValue = rawValue
    }
}

/// An open Topic, as a request names it.
public enum TopicRef: Codable, Hashable, Sendable {
    /// Exactly this id.
    case id(String)
    /// This id, else the one open Topic with this slug or title.
    case named(String)

    private enum CodingKeys: String, CodingKey { case id, named }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try values.decodeIfPresent(String.self, forKey: .id) { self = .id(id) }
        else { self = .named(try values.decode(String.self, forKey: .named)) }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .id(let id): try values.encode(id, forKey: .id)
        case .named(let value): try values.encode(value, forKey: .named)
        }
    }
}

/// What a request acts on.
public enum EnvironmentTarget: Codable, Hashable, Sendable {
    case topic(TopicRef)
    case session(SessionID)
    /// The Session with exactly this tmux name.
    case sessionName(String)
    case window(WindowID)
    case pane(PaneID)

    private enum CodingKeys: String, CodingKey {
        case topic, session, window, pane
        case sessionName = "session_name"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let topic = try values.decodeIfPresent(TopicRef.self, forKey: .topic) { self = .topic(topic) }
        else if let session = try values.decodeIfPresent(SessionID.self, forKey: .session) { self = .session(session) }
        else if let name = try values.decodeIfPresent(String.self, forKey: .sessionName) { self = .sessionName(name) }
        else if let window = try values.decodeIfPresent(WindowID.self, forKey: .window) { self = .window(window) }
        else { self = .pane(try values.decode(PaneID.self, forKey: .pane)) }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .topic(let topic): try values.encode(topic, forKey: .topic)
        case .session(let session): try values.encode(session, forKey: .session)
        case .sessionName(let name): try values.encode(name, forKey: .sessionName)
        case .window(let window): try values.encode(window, forKey: .window)
        case .pane(let pane): try values.encode(pane, forKey: .pane)
        }
    }
}

/// Where a request comes from. It is only the default target: an explicit target always wins.
public enum TopicCaller: Codable, Hashable, Sendable {
    /// A command run in this Pane.
    case pane(PaneID)
    /// The Pane that the host's tmux client shows now.
    case currentClient

    private enum CodingKeys: String, CodingKey {
        case pane
        case currentClient = "current_client"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let pane = try values.decodeIfPresent(PaneID.self, forKey: .pane) { self = .pane(pane) }
        else if try values.decode(Bool.self, forKey: .currentClient) { self = .currentClient }
        else { throw DecodingError.dataCorruptedError(forKey: .currentClient, in: values, debugDescription: "expected true") }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pane(let pane): try values.encode(pane, forKey: .pane)
        case .currentClient: try values.encode(true, forKey: .currentClient)
        }
    }
}

/// Which working copy of a SessionPath a new Session opens.
public enum TopicWorkingCopyChoice: Codable, Hashable, Sendable {
    /// The SessionPath folder.
    case directory
    /// The Worktree at this path.
    case worktree(path: String)
    /// A new Worktree from the Worktree at this path. Wire: `{"new_worktree":{"from":…}}`, with `"base"` for
    /// `.ref` or `"branch"` for `.branch`. Both keys at once do not decode.
    case newWorktree(from: String, start: WorktreeStart = .head)

    private enum CodingKeys: String, CodingKey {
        case directory, worktree
        case newWorktree = "new_worktree"
    }

    private enum WorktreeKeys: String, CodingKey { case path }
    private enum NewWorktreeKeys: String, CodingKey { case from, base, branch }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard values.allKeys.count == 1, let key = values.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(codingPath: values.codingPath, debugDescription: "One working copy"))
        }
        switch key {
        case .directory: self = .directory
        case .worktree: self = .worktree(path: try values.nestedContainer(keyedBy: WorktreeKeys.self, forKey: .worktree).decode(String.self, forKey: .path))
        case .newWorktree:
            let new = try values.nestedContainer(keyedBy: NewWorktreeKeys.self, forKey: .newWorktree)
            let base = try new.decodeIfPresent(String.self, forKey: .base), branch = try new.decodeIfPresent(String.self, forKey: .branch)
            let start: WorktreeStart
            switch (base, branch) {
            case (nil, nil): start = .head
            case (let ref?, nil): start = .ref(ref)
            case (nil, let branch?): start = .branch(branch)
            default: throw DecodingError.dataCorrupted(.init(codingPath: new.codingPath, debugDescription: "base or branch, not both"))
            }
            self = .newWorktree(from: try new.decode(String.self, forKey: .from), start: start)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .directory: _ = values.nestedContainer(keyedBy: WorktreeKeys.self, forKey: .directory)
        case .worktree(let path):
            var worktree = values.nestedContainer(keyedBy: WorktreeKeys.self, forKey: .worktree)
            try worktree.encode(path, forKey: .path)
        case .newWorktree(let from, let start):
            var new = values.nestedContainer(keyedBy: NewWorktreeKeys.self, forKey: .newWorktree)
            try new.encode(from, forKey: .from)
            switch start {
            case .head: break
            case .ref(let ref): try new.encode(ref, forKey: .base)
            case .branch(let branch): try new.encode(branch, forKey: .branch)
            }
        }
    }
}

/// Where a new Worktree starts.
public enum WorktreeStart: Hashable, Sendable {
    /// A new branch named from the Topic slug, at the HEAD of the Worktree it starts from.
    case head
    /// A new branch named from the Topic slug, at the commit that the ref names.
    case ref(String)
    /// This local branch, which exists and no other Worktree has checked out. Muxify makes the Worktree, so Settle
    /// can remove it (ADR 0038). It never deletes the branch.
    case branch(String)
}

/// A local branch that a new Worktree can start from, as the palette's start step lists it.
public struct WorktreeStartChoice: Equatable, Sendable {
    public let branch: String
    /// The Worktree that has the branch checked out. git checks out a branch in one Worktree only.
    public let checkedOutAt: String?

    public init(branch: String, checkedOutAt: String?) {
        self.branch = branch
        self.checkedOutAt = checkedOutAt
    }
}

/// One move of a card of the Topics list.
public enum CardMove: Codable, Hashable, Sendable {
    /// One card up or down among the cards that the Topics list shows now (`TopicCards`).
    case up, down
    /// Next to another card, shown or not, as the Sidebar drag puts it.
    case before(TopicListRef)
    case after(TopicListRef)

    private enum BeforeCodingKeys: String, CodingKey { case _0 = "card" }
    private enum AfterCodingKeys: String, CodingKey { case _0 = "card" }
}

/// A card on the wire: a Topic, or a Locked Session by its tmux id.
public enum TopicListRef: Codable, Hashable, Sendable {
    case topic(TopicRef)
    case lock(SessionID)

    private enum TopicCodingKeys: String, CodingKey { case _0 = "ref" }
    private enum LockCodingKeys: String, CodingKey { case _0 = "session" }
}

/// Where `move` puts its target.
public enum TopicDestination: Codable, Hashable, Sendable {
    case topic(TopicRef)
    case session(SessionID)
    case newSession(topic: TopicRef?)
    /// A new Topic with this title.
    case newTopic(title: String)
    /// A new Window in the source Pane's Session.
    case newWindow(title: String)

    private enum CodingKeys: String, CodingKey {
        case topic, session
        case newSession = "new_session"
        case newTopic = "new_topic"
        case newWindow = "new_window"
    }

    private enum TopicCodingKeys: String, CodingKey { case _0 = "ref" }
}

/// Where `moveSession` puts its target Session: before or after another Session of the same Topic, or one place
/// up or down among them.
public enum TopicSessionPlacement: Codable, Hashable, Sendable {
    case before(SessionID)
    case after(SessionID)
    case up
    case down

    private enum BeforeCodingKeys: String, CodingKey { case _0 = "session" }
    private enum AfterCodingKeys: String, CodingKey { case _0 = "session" }
}

/// Where `moveWindow` puts its target Window: before or after another Window of the same Session.
public enum WindowPlacement: Codable, Hashable, Sendable {
    case before(WindowID)
    case after(WindowID)

    private enum BeforeCodingKeys: String, CodingKey { case _0 = "window" }
    private enum AfterCodingKeys: String, CodingKey { case _0 = "window" }
}

public enum EnvironmentCommand: Codable, Hashable, Sendable {
    /// The open Topics.
    case list
    /// The target's open Topic, with its live Sessions, Windows, Panes and Agents. It changes nothing.
    case show
    /// An Empty Topic. It starts no Session and reads no target or caller, so it works outside tmux. A Session comes
    /// with `addSession`, and a Pane moves into a new Topic with `move(to: .newTopic)`.
    case create(title: String, tags: [Tag]? = nil)
    /// Adds a Session for `sessionPath` to the target's Topic.
    case addSession(sessionPath: String, workingCopy: TopicWorkingCopyChoice, name: String? = nil)
    /// Empty `choices` take the default choice for each Session.
    case settle(choices: [TopicSettleSession], outcome: String)
    case forget(choices: [TopicSettleSession], worktrees: [String])
    /// Moves the target Session, Window or Pane. A Pane in a shared Window leaves the other Panes there.
    case move(to: TopicDestination)
    /// Takes the target's Session out of its Topic. The Topic forgets it, so Reopen does not make it again.
    case removeFromTopic
    /// Takes the target Session out of its Topic and kills it. Of the Worktrees in `worktrees`, it removes the clean
    /// one that the Topic made for that Session, as Forget does.
    case removeAndKill(worktrees: [String])
    case rename(title: String)
    /// Creates the remembered Sessions, Windows, Tabs and Agents of a Dormant or Settled Topic again.
    case reopen
    /// Creates one Session with one shell Window in each SessionPath that a Dormant or Settled Topic remembers.
    case startFresh
    /// Puts the target Session before or after another Session of its Topic, or one place up or down. From then on
    /// the Topic keeps its Sessions in the order the user gave them. `up` and `down` on a Locked Session, which is in
    /// no Topic, move its card, as `moveCard` does.
    case moveSession(to: TopicSessionPlacement)
    /// The target Topic lists its Sessions by when tmux created them again, in the Config's order.
    case sortSessions
    /// Locks the target No Topic Session: it gets a card last among the Topics that are not Pinned (ADR 0018).
    /// A Locked Session stays where it is.
    case lock
    /// Ends the Lock of the target Session. A Session that is not Locked does not change.
    case unlock
    /// Snoozes each open Topic in `topics` until this time, also one that was Snoozed until later. Empty `topics`
    /// is the target's open Topic. One write: when one Topic is not open, nothing changes. It changes nothing in tmux.
    case snooze(until: SnoozeDeadline, topics: [TopicRef] = [])
    /// Ends the Snooze of each open Topic in `topics`, as `snooze` names them. A Topic that is not Snoozed does not change.
    case unsnooze(topics: [TopicRef] = [])
    /// Changes the Tags of the target's open Topic. It changes nothing in tmux.
    case tags(TopicTagChange)
    /// A tmux Window in the target's Session, in the folder of the target's Window. A `.topic` target names the
    /// Topic's only live Session; with none or more than one the request fails. It never makes a Session.
    /// `command` runs in place of the default shell.
    case newWindow(command: [String]?)
    /// A No Topic Session in the folder `sessionPath`. `name` nil takes the Session Path's name. A name that a
    /// Session has gets +2, +3, and so on.
    case newSession(sessionPath: String, name: String?)
    /// Renames the target's Session. A Session in an open Topic keeps the Topic's slug after the name, and a name
    /// that another Session has gets +2.
    case renameSession(name: String)
    /// Renames the target's Window.
    case renameWindow(name: String)
    /// Puts the target's Window before or after another Window of its Session. The Session keeps its current Window.
    case moveWindow(to: WindowPlacement)
    /// Kills the target's Window. With `expectedPaneIDs`, only while its Panes are the ones the user reviewed. A Topic
    /// record remembers what is left.
    case killWindow
    /// Kills the target's whole Session, with the same rules as `killWindow`.
    case killSession
    /// Pins or unpins the target's open or Snoozed Topic. A Topic that already has that Pin does not change.
    case pin
    case unpin
    /// Moves the card of the target's Topic, or of the target's Locked Session, among the cards with its Pin.
    case moveCard(CardMove)
    /// Snoozes every open Topic but the target's Topic until this time, in one write with the Zen record. It fails
    /// while Zen is on.
    case startZen(until: SnoozeDeadline)
    /// Gives each Topic that Zen Snoozed its earlier Snooze back, and removes the Zen record. With no Zen it changes
    /// nothing and succeeds.
    case endZen
    /// Marks the `scope` of the target Read or Unread: the Topic Unread of a Topic, and each Agent there that
    /// `change` applies to.
    case markRead(ReadChange, scope: ReadScope)
    /// Marks every Topic and every Agent Read.
    case markAllRead

    private enum CodingKeys: String, CodingKey {
        case list, show, create, settle, forget, move, rename, reopen, lock, unlock, snooze, unsnooze, tags
        case startFresh = "start_fresh"
        case moveSession = "move_session"
        case sortSessions = "sort_sessions"
        case addSession = "add_session"
        case removeFromTopic = "remove_from_topic"
        case removeAndKill = "remove_and_kill"
        case newWindow = "new_window"
        case newSession = "new_session"
        case renameSession = "rename_session"
        case renameWindow = "rename_window"
        case moveWindow = "move_window"
        case killWindow = "kill_window"
        case killSession = "kill_session"
        case pin, unpin
        case moveCard = "move_card"
        case startZen = "start_zen"
        case endZen = "end_zen"
        case markRead = "mark_read"
        case markAllRead = "mark_all_read"
    }

    private enum NewSessionCodingKeys: String, CodingKey {
        case sessionPath = "directory"
        case name
    }

    private enum AddSessionCodingKeys: String, CodingKey {
        case sessionPath = "directory"
        case name
        case workingCopy = "working_copy"
    }

    private enum TagsCodingKeys: String, CodingKey { case _0 = "change" }
    private enum MoveCardCodingKeys: String, CodingKey { case _0 = "move" }
    private enum MarkReadCodingKeys: String, CodingKey {
        case _0 = "change"
        case scope
    }
}

public struct EnvironmentRequest: Codable, Hashable, Sendable {
    /// No request JSON crosses a process today: the CLI runs the service in its own process, and the app builds each
    /// request from the muxify://topic URL. So it stayed 2 when `create` and `new_worktree` changed (ADR 0039). Raise
    /// it for a change that an older reader would misread once JSON crosses a process.
    public static let currentVersion = 2

    public var version: Int
    public var command: EnvironmentCommand
    /// Nil: the caller's Pane, when the command needs a target.
    public var target: EnvironmentTarget?
    public var caller: TopicCaller?
    /// Settle and Forget require these live Sessions to match the confirmation the user reviewed.
    public var expectedSessionIDs: [String]?
    /// Kill requires these Panes to be the ones that the target has, as the user reviewed them.
    public var expectedPaneIDs: Set<PaneID>?

    public init(_ command: EnvironmentCommand, target: EnvironmentTarget? = nil, caller: TopicCaller? = nil, expectedSessionIDs: [String]? = nil,
                expectedPaneIDs: Set<PaneID>? = nil) {
        version = Self.currentVersion
        self.command = command
        self.target = target
        self.caller = caller
        self.expectedSessionIDs = expectedSessionIDs
        self.expectedPaneIDs = expectedPaneIDs
    }

    private enum CodingKeys: String, CodingKey {
        case version, command, target, caller
        case expectedSessionIDs = "expected_session_ids"
        case expectedPaneIDs = "expected_pane_ids"
    }
}

/// An open Topic in a list.
public struct TopicSummary: Codable, Hashable, Sendable {
    public var id: String
    /// The title, else the slug, else "Untitled Topic".
    public var label: String
    /// A→Z.
    public var tags: [Tag]
    public var pinned: Bool

    public init(id: String, label: String, tags: [Tag] = [], pinned: Bool = false) {
        self.id = id
        self.label = label
        self.tags = tags
        self.pinned = pinned
    }

    public init(record: TopicRecord) {
        self.init(id: record.id, label: [record.title, record.slug].compactMap { $0 }.first { !$0.isEmpty } ?? "Untitled Topic",
                  tags: record.tags.sorted(), pinned: record.isPinned)
    }
}

/// What a request changed.
public struct TopicChange: Codable, Hashable, Sendable {
    public enum Shown: Codable, Hashable, Sendable {
        /// The host's client now shows this Window.
        case window(WindowID)
        /// An open Topic with no Session, which a host shows in place of a Window.
        case emptyTopic(id: String)

        private enum CodingKeys: String, CodingKey {
            case window
            case emptyTopic = "empty_topic"
        }

        private enum WindowCodingKeys: String, CodingKey { case _0 = "id" }
    }

    /// The Topic whose record the request wrote; nil when it changed only tmux.
    public var topicID: String?
    public var created: Bool
    public var shown: Shown?
    /// What the request made in tmux, so the next request can name it. Nil when it made nothing.
    public var session: SessionID?
    /// The full tmux name of `session`.
    public var sessionName: String?
    public var window: WindowID?
    /// The first Pane of `window`.
    public var pane: PaneID?
    /// The Agent Panes that a Kill stopped.
    public var stopped: [PaneID]?

    public init(topicID: String?, created: Bool = false, shown: Shown? = nil, session: SessionID? = nil, sessionName: String? = nil,
                window: WindowID? = nil, pane: PaneID? = nil, stopped: [PaneID]? = nil) {
        self.topicID = topicID
        self.created = created
        self.shown = shown
        self.session = session
        self.sessionName = sessionName
        self.window = window
        self.pane = pane
        self.stopped = stopped
    }

    private enum CodingKeys: String, CodingKey {
        case created, shown, session, window, pane, stopped
        case topicID = "topic_id"
        case sessionName = "session_name"
    }
}

/// What a Snooze or an Unsnooze changed.
public struct TopicSnoozeChange: Codable, Hashable, Sendable {
    /// Each Topic that the request named, once, in the order it named them.
    public var topicIDs: [String]
    /// The Topics of `topicIDs` that were Snoozed until later. An Unsnooze shortens none.
    public var shortened: [String]

    public init(topicIDs: [String], shortened: [String] = []) {
        self.topicIDs = topicIDs
        self.shortened = shortened
    }

    private enum CodingKeys: String, CodingKey {
        case shortened
        case topicIDs = "topic_ids"
    }
}

/// A failure is data, not a thrown error, so every transport can send it.
public struct TopicFailure: Error, Codable, Hashable, Sendable, CustomStringConvertible {
    /// An open set: a newer writer may send a kind that an older reader does not know.
    public struct Kind: RawRepresentable, Codable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
        public func encode(to encoder: Encoder) throws {
            var value = encoder.singleValueContainer()
            try value.encode(rawValue)
        }

        public static let topicUnavailable = Kind(rawValue: "topic_unavailable")
        public static let topicMembershipChanged = Kind(rawValue: "topic_membership_changed")
        public static let topicAmbiguous = Kind(rawValue: "topic_ambiguous")
        public static let sourceHasNoTopic = Kind(rawValue: "source_has_no_topic")
        public static let sourceUnavailable = Kind(rawValue: "source_unavailable")
        public static let sessionInTopic = Kind(rawValue: "session_in_topic")
        public static let noTarget = Kind(rawValue: "no_target")
        public static let unsupported = Kind(rawValue: "unsupported")
        public static let sessionPathUnavailable = Kind(rawValue: "session_path_unavailable")
        public static let duplicateSession = Kind(rawValue: "duplicate_session")
        public static let tmuxFailed = Kind(rawValue: "tmux_failed")
        public static let gitFailed = Kind(rawValue: "git_failed")
        public static let storeBusy = Kind(rawValue: "store_busy")
        public static let storeFailed = Kind(rawValue: "store_failed")
        public static let tagUndefined = Kind(rawValue: "tag_undefined")
        public static let branchUnavailable = Kind(rawValue: "branch_unavailable")
        public static let branchCheckedOut = Kind(rawValue: "branch_checked_out")
        public static let chooseSession = Kind(rawValue: "choose_session")
        public static let topicEmpty = Kind(rawValue: "topic_empty")
        public static let topicsUnavailable = Kind(rawValue: "topics_unavailable")
        public static let sessionNameInvalid = Kind(rawValue: "session_name_invalid")
        public static let panesChanged = Kind(rawValue: "panes_changed")
        public static let cardAtEnd = Kind(rawValue: "card_at_end")
        public static let sessionAtEnd = Kind(rawValue: "session_at_end")
        public static let cardHidden = Kind(rawValue: "card_hidden")
        public static let zenOn = Kind(rawValue: "zen_on")
        public static let windowNotInSession = Kind(rawValue: "window_not_in_session")
    }

    /// How far the request got before it failed.
    public enum Phase: String, Codable, Hashable, Sendable {
        case nothingChanged = "nothing_changed"
        /// The record was written, and some tmux changes may have run.
        case recordSaved = "record_saved"
        /// No record was written, but some tmux changes may have run.
        case changesStarted = "changes_started"
        /// Everything changed, but the host's client could not show the result.
        case selectionFailed = "selection_failed"

        /// What the user can expect to find changed. Every host shows it after the failure's message.
        public var summary: String {
            switch self {
            case .nothingChanged: return "No changes were made."
            case .recordSaved: return "The Topic record was saved. Some Session changes may have occurred."
            case .changesStarted: return "Some Session changes may have occurred."
            case .selectionFailed: return "The Topic changed, but Muxify could not select it."
            }
        }
    }

    public var kind: Kind
    public var phase: Phase
    public var message: String

    public init(kind: Kind, phase: Phase, message: String) {
        self.kind = kind
        self.phase = phase
        self.message = message
    }

    public var description: String { message }
}

/// What a Mark Read or Mark Unread changed.
public struct TopicReadChange: Codable, Hashable, Sendable {
    /// The Topics whose Topic Unread changed.
    public var topicIDs: [String]
    /// The Agent Panes whose Unread changed.
    public var paneIDs: [PaneID]

    public init(topicIDs: [String] = [], paneIDs: [PaneID] = []) {
        self.topicIDs = topicIDs
        self.paneIDs = paneIDs
    }

    private enum CodingKeys: String, CodingKey {
        case topicIDs = "topic_ids"
        case paneIDs = "pane_ids"
    }
}

public enum EnvironmentResponse: Codable, Hashable, Sendable {
    case topics([TopicSummary])
    case topic(TopicDetail)
    case changed(TopicChange)
    case snoozeChanged(TopicSnoozeChange)
    case readChanged(TopicReadChange)
    case failed(TopicFailure)

    private enum CodingKeys: String, CodingKey {
        case topics, topic, changed, failed
        case snoozeChanged = "snooze_changed"
        case readChanged = "read_changed"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let topics = try values.decodeIfPresent([TopicSummary].self, forKey: .topics) { self = .topics(topics) }
        else if let topic = try values.decodeIfPresent(TopicDetail.self, forKey: .topic) { self = .topic(topic) }
        else if let change = try values.decodeIfPresent(TopicChange.self, forKey: .changed) { self = .changed(change) }
        else if let change = try values.decodeIfPresent(TopicSnoozeChange.self, forKey: .snoozeChanged) { self = .snoozeChanged(change) }
        else if let change = try values.decodeIfPresent(TopicReadChange.self, forKey: .readChanged) { self = .readChanged(change) }
        else { self = .failed(try values.decode(TopicFailure.self, forKey: .failed)) }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .topics(let topics): try values.encode(topics, forKey: .topics)
        case .topic(let topic): try values.encode(topic, forKey: .topic)
        case .changed(let change): try values.encode(change, forKey: .changed)
        case .snoozeChanged(let change): try values.encode(change, forKey: .snoozeChanged)
        case .readChanged(let change): try values.encode(change, forKey: .readChanged)
        case .failed(let failure): try values.encode(failure, forKey: .failed)
        }
    }
}
