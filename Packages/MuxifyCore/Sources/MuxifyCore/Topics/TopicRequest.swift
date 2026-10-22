import Foundation

// The values a Topic request and its response are made of. They are a versioned contract: the CLI, the
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
public enum TopicTarget: Codable, Hashable, Sendable {
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
    /// A new Worktree on the Topic's branch, from the HEAD of the Worktree at this path, or from the commit that
    /// the ref `base` names there.
    case newWorktree(from: String, base: String? = nil)

    private enum CodingKeys: String, CodingKey {
        case directory, worktree
        case newWorktree = "new_worktree"
    }
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

/// Where `moveSession` puts its target Session: before or after another Session of the same Topic.
public enum TopicSessionPlacement: Codable, Hashable, Sendable {
    case before(SessionID)
    case after(SessionID)

    public var anchor: SessionID {
        switch self {
        case .before(let id), .after(let id): return id
        }
    }

    private enum BeforeCodingKeys: String, CodingKey { case _0 = "session" }
    private enum AfterCodingKeys: String, CodingKey { case _0 = "session" }
}

public enum TopicCommand: Codable, Hashable, Sendable {
    /// The open Topics.
    case list
    /// The target's open Topic, with its live Sessions, Windows, Panes and Agents. It changes nothing.
    case show
    /// A new Topic. With a SessionPath, it starts a Session there. Without one, it uses the target's SessionPath, and
    /// with no target it has no Session.
    case create(title: String, sessionPath: String?, tags: [Tag]? = nil)
    /// Moves the target Pane into a new Topic, with a Session in `sessionPath` or in the Pane's SessionPath.
    case extract(sessionPath: String?, title: String? = nil)
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
    /// Puts the target Session before or after another Session of its Topic. From then on the Topic keeps its
    /// Sessions in the order the user gave them.
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

    private enum CodingKeys: String, CodingKey {
        case list, show, create, extract, settle, forget, move, rename, reopen, lock, unlock, snooze, unsnooze, tags
        case startFresh = "start_fresh"
        case moveSession = "move_session"
        case sortSessions = "sort_sessions"
        case addSession = "add_session"
        case removeFromTopic = "remove_from_topic"
        case removeAndKill = "remove_and_kill"
    }

    private enum AddSessionCodingKeys: String, CodingKey {
        case sessionPath = "directory"
        case name
        case workingCopy = "working_copy"
    }

    private enum TagsCodingKeys: String, CodingKey { case _0 = "change" }
}

public struct TopicRequest: Codable, Hashable, Sendable {
    /// Raised only for a change that an older reader would misread.
    public static let currentVersion = 2

    public var version: Int
    public var command: TopicCommand
    /// Nil: the caller's Pane, when the command needs a target.
    public var target: TopicTarget?
    public var caller: TopicCaller?
    /// Settle and Forget require these live Sessions to match the confirmation the user reviewed.
    public var expectedSessionIDs: [String]?

    public init(_ command: TopicCommand, target: TopicTarget? = nil, caller: TopicCaller? = nil, expectedSessionIDs: [String]? = nil) {
        version = Self.currentVersion
        self.command = command
        self.target = target
        self.caller = caller
        self.expectedSessionIDs = expectedSessionIDs
    }

    private enum CodingKeys: String, CodingKey {
        case version, command, target, caller
        case expectedSessionIDs = "expected_session_ids"
    }
}

/// An open Topic in a list.
public struct TopicSummary: Codable, Hashable, Sendable {
    public var id: String
    /// The title, else the slug, else "Untitled Topic".
    public var label: String
    /// A→Z.
    public var tags: [Tag]

    public init(id: String, label: String, tags: [Tag] = []) {
        self.id = id
        self.label = label
        self.tags = tags
    }

    public init(record: TopicRecord) {
        self.init(id: record.id, label: [record.title, record.slug].compactMap { $0 }.first { !$0.isEmpty } ?? "Untitled Topic",
                  tags: record.tags.sorted())
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

    public init(topicID: String?, created: Bool = false, shown: Shown? = nil) {
        self.topicID = topicID
        self.created = created
        self.shown = shown
    }

    private enum CodingKeys: String, CodingKey {
        case created, shown
        case topicID = "topic_id"
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

public enum TopicResponse: Codable, Hashable, Sendable {
    case topics([TopicSummary])
    case topic(TopicDetail)
    case changed(TopicChange)
    case snoozeChanged(TopicSnoozeChange)
    case failed(TopicFailure)

    private enum CodingKeys: String, CodingKey {
        case topics, topic, changed, failed
        case snoozeChanged = "snooze_changed"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let topics = try values.decodeIfPresent([TopicSummary].self, forKey: .topics) { self = .topics(topics) }
        else if let topic = try values.decodeIfPresent(TopicDetail.self, forKey: .topic) { self = .topic(topic) }
        else if let change = try values.decodeIfPresent(TopicChange.self, forKey: .changed) { self = .changed(change) }
        else if let change = try values.decodeIfPresent(TopicSnoozeChange.self, forKey: .snoozeChanged) { self = .snoozeChanged(change) }
        else { self = .failed(try values.decode(TopicFailure.self, forKey: .failed)) }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .topics(let topics): try values.encode(topics, forKey: .topics)
        case .topic(let topic): try values.encode(topic, forKey: .topic)
        case .changed(let change): try values.encode(change, forKey: .changed)
        case .snoozeChanged(let change): try values.encode(change, forKey: .snoozeChanged)
        case .failed(let failure): try values.encode(failure, forKey: .failed)
        }
    }
}
