import Foundation

struct TopicEdit: Sendable {
    public enum Selection: Equatable, Sendable {
        case unchanged
        case sessionID(String)
        case sessionName(String)
        case paneID(String)
        /// An open Topic with no Session: the terminal area offers to add a SessionPath to it.
        case emptyTopic(String)
        /// The Window that the plan's `tmuxMaking` command made, once tmux has printed its id.
        case made
    }

    public let record: TopicRecord?
    /// The Topic that a moved Session left, without that Session. The write that saves `record` saves it too.
    public var leftTopic: TopicRecord? = nil
    public var newWorktree: TopicPlan.NewWorktree? = nil
    public let commands: [TopicPlan.Command]
    public let selection: Selection
    enum Completion: Sendable {
        case save(TopicRecord)
        case forget(String)
        var topicID: String {
            switch self { case .save(let record): return record.id; case .forget(let id): return id }
        }
    }
    var completion: Completion?

    public init(record: TopicRecord?, newWorktree: TopicPlan.NewWorktree? = nil, commands: [TopicPlan.Command], selection: Selection, completion: Completion? = nil) {
        precondition(commands.filter { if case .tmuxMaking = $0 { true } else { false } }.count <= 1, "a plan makes one tmux object")
        self.record = record
        self.newWorktree = newWorktree
        self.commands = commands
        self.selection = selection
        self.completion = completion
    }
}

enum TopicEditFailure: Error, CustomStringConvertible {
    case destinationUnavailable, sourceUnavailable, invalidSessionPath
    case invalidTmuxResponse, sessionUnavailable

    public var description: String {
        switch self {
        case .destinationUnavailable: return "The Topic is no longer open."
        case .sourceUnavailable: return "The source Pane or Window is no longer available."
        case .invalidSessionPath: return "The Session needs a directory and a name that tmux accepts."
        case .invalidTmuxResponse: return "tmux did not return the expected Pane or Window identity."
        case .sessionUnavailable: return "The Session is no longer in the Topic."
        }
    }
}

private enum TopicEditSessions {
    public static func validate(_ sessionPath: SessionPath) throws {
        guard !sessionPath.folder.path.isEmpty, !sessionPath.name.isEmpty,
              !sessionPath.name.contains("."), !sessionPath.name.contains(":"),
              !sessionPath.name.contains("\n"), !sessionPath.name.contains("\0") else {
            throw TopicEditFailure.invalidSessionPath
        }
    }

    public static func sessions(in windows: [TmuxWindow], topic: TopicRecord) -> [TmuxWindow] {
        var ids: Set<String> = []
        return windows.filter { $0.topicID == topic.id && ids.insert($0.sessionID).inserted }
    }
}

struct TopicRenamePlan {
    public let edit: TopicEdit

    public init(topic: TopicRecord, title: String, records: [TopicRecord], windows: [TmuxWindow], sessionPaths: [SessionPath]) throws {
        let members = TopicEditSessions.sessions(in: windows, topic: topic)
        var names = Set(windows.map(\.sessionName))
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = TopicNaming.slug(title: title, records: records, excludingTopicID: topic.id)
        var record = topic
        record.title = title.isEmpty ? nil : title
        record.slug = slug
        var commands: [TopicPlan.Command] = []
        for window in members {
            names.remove(window.sessionName)
            let name = SessionNaming.available(topic.baseName(of: window), topic: slug, taken: names)
            names.insert(name)
            commands.append(.tmux(["rename-session", "-t", window.sessionID, name]))
            if let index = record.sessions.firstIndex(where: { $0["id"]?.string == window.sessionRecordID }),
               var fields = record.sessions[index].object {
                fields["name"] = .string(name)
                fields["base_name"] = .string(SessionNaming.base(of: name, topic: record))
                record.sessions[index] = .object(fields)
            }
        }
        let live = Set(members.map(\.sessionRecordID))
        for index in record.sessions.indices where !live.contains(record.sessions[index]["id"]?.string ?? "") {
            guard var fields = record.sessions[index].object, let base = fields["base_name"]?.string else { continue }
            let name = SessionNaming.available(base, topic: slug, taken: names)
            names.insert(name)
            fields["name"] = .string(name)
            fields["base_name"] = .string(SessionNaming.base(of: name, topic: record))
            record.sessions[index] = .object(fields)
        }
        edit = TopicEdit(record: record, commands: commands, selection: .unchanged)
    }
}

/// A change to the order of a Topic's Sessions. It writes only the record: tmux has no order of Sessions.
struct TopicSessionOrderPlan {
    public let edit: TopicEdit

    /// Moves a live Session before or after another one, or one place up or down, as the Topic lists them now, and
    /// keeps that order.
    public init(moving sessionID: String, to placement: TopicSessionPlacement, topic: TopicRecord, windows: [TmuxWindow],
                order: SessionOrder) throws {
        let key = { (window: TmuxWindow) in TopicSessionKey(of: window) }
        let shown = TopicSessionOrder.ordered(TopicEditSessions.sessions(in: windows, topic: topic), record: topic, order: order, key: key)
        guard let from = shown.firstIndex(where: { $0.sessionID == sessionID }) else { throw TopicEditFailure.sessionUnavailable }
        let moved = shown[from]
        var ordered = shown
        ordered.remove(at: from)
        let to: Int
        switch placement {
        case .before(let anchor), .after(let anchor):
            guard anchor.rawValue != sessionID else {
                guard shown.contains(where: { $0.sessionID == anchor.rawValue }) else { throw TopicEditFailure.sessionUnavailable }
                edit = TopicEdit(record: nil, commands: [], selection: .unchanged)
                return
            }
            guard let index = ordered.firstIndex(where: { $0.sessionID == anchor.rawValue }) else { throw TopicEditFailure.sessionUnavailable }
            if case .before = placement { to = index } else { to = index + 1 }
        case .up, .down:
            to = placement == .up ? from - 1 : from + 1
            guard (0...ordered.count).contains(to) else {
                throw TopicRequestError.sessionAtEnd(session: moved.sessionName, topic: TopicSummary(record: topic).label, up: placement == .up)
            }
        }
        ordered.insert(moved, at: to)
        let live = ordered.map(\.sessionRecordID)
        var record = topic
        record.sessions = ordered.map { window in topic.session(of: window) ?? .object([
            "id": .string(window.sessionRecordID), "name": .string(window.sessionName),
            "base_name": .string(topic.baseName(of: window)), "directory": .string(window.sessionPath)]) }
            + topic.sessions.filter { !live.contains($0["id"]?.string ?? "") }
        record.hasManualSessionOrder = true
        edit = TopicEdit(record: record, commands: [], selection: .unchanged)
    }

    /// Lets the Topic list its Sessions by creation again.
    public init(sortingByCreation topic: TopicRecord) {
        var record = topic
        record.hasManualSessionOrder = false
        edit = TopicEdit(record: record, commands: [], selection: .unchanged)
    }
}

struct TopicSessionPlan {
    public let edit: TopicEdit

    public init(topic: TopicRecord, sessionPath: SessionPath, workingCopy: TopicWorkingCopy, windows: [TmuxWindow], sessionPaths: [SessionPath],
                order: SessionOrder = .oldestFirst, baseName: String? = nil) throws {
        try TopicEditSessions.validate(sessionPath)
        if let baseName { try SessionNaming.validate(baseName) }
        let slug = topic.slug ?? TopicNaming.slugify(topic.title ?? "topic")
        let name = SessionNaming.available(baseName ?? sessionPath.name, topic: slug, taken: Set(windows.map(\.sessionName)))
        var record = topic
        let start = workingCopy.sessionStart(in: sessionPath, slug: slug)
        let id = UUID().uuidString.lowercased()
        var session = start.worktreeFields
        session["id"] = .string(id)
        session["name"] = .string(name)
        session["base_name"] = .string(SessionNaming.base(of: name, topic: record))
        session["directory"] = .string(start.directory)
        record.recordingNewSession(session, order: order)
        edit = TopicEdit(record: record, newWorktree: start.newWorktree, commands: [
            .tmuxMaking(["new-session", "-d", "-s", name, "-c", start.directory]),
            .tmux(["set-option", "-t", "=" + name + ":", "@muxify_topic", topic.id]),
            .tmux(["set-option", "-t", "=" + name + ":", "@muxify_session_id", id]),
        ], selection: .sessionName(name))
    }
}

struct TopicPaneSource {
    public let paneID: String
    public let window: TmuxWindow
    var directory: String? = nil
}
