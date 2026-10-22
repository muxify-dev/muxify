import Foundation

public struct TopicMembershipPlan: Sendable {
    public enum Source {
        case window(TmuxWindow), pane(PaneID, TmuxWindow), session(TmuxWindow)

        public var window: TmuxWindow {
            switch self { case .window(let w), .pane(_, let w), .session(let w): return w }
        }

        public func resolved(in windows: [TmuxWindow]) throws -> Source {
            guard let current = windows.first(where: { $0.id == window.id }),
                  !Self.isSession(self) || current.sessionID == window.sessionID else {
                throw Failure.sourceUnavailable
            }
            switch self { case .window: return .window(current); case .pane(let id, _): return .pane(id, current); case .session: return .session(current) }
        }

        private static func isSession(_ source: Source) -> Bool { if case .session = source { return true }; return false }
    }

    public enum Failure: Error, CustomStringConvertible {
        case sourceUnavailable, destinationUnavailable, chooseSession
        public var description: String {
            switch self {
            case .sourceUnavailable: return "The source Window or Session is no longer open."
            case .destinationUnavailable: return "The destination Session is no longer available."
            case .chooseSession: return "Choose a destination Session; this Topic has several."
            }
        }
    }

    public let record: TopicRecord?
    public let commands: [TopicPlan.Command]
    private(set) var endedLockOf: String? = nil
    private(set) var leftTopic: TopicRecord? = nil

    init(removingSession window: TmuxWindow, records: [TopicRecord], sessionPaths: [SessionPath], windows: [TmuxWindow] = []) {
        let topic = Self.openTopic(of: window, records: records)
        record = topic?.forgetting(window)
        var taken = Set(windows.map(\.sessionName))
        commands = topic?.detachedCommands(for: window, taken: &taken) ?? []
    }

    init(source: Source, destination: TopicRecord?, records: [TopicRecord], windows: [TmuxWindow], sessionPaths: [SessionPath],
         clientTTY: String? = nil, order: SessionOrder = .oldestFirst,
          destinationSession: String? = nil, createSession: Bool = false, launchDirectory: String? = nil) throws {
        let window = source.window
        let sourceTopic = Self.openTopic(of: window, records: records)
        let base = sourceTopic?.baseName(of: window) ?? window.sessionName
        try SessionNaming.validate(base)
        var saved = destination
        var commands: [TopicPlan.Command] = []
        let taken = Set(windows.filter { $0.sessionID != window.sessionID || !Self.isSession(source) }.map(\.sessionName))

        switch source {
        case .session:
            if window.topicID == destination?.id { record = nil; self.commands = []; return }
            let name = SessionNaming.available(base, topic: destination?.slug, taken: taken)
            commands.append(.tmux(["rename-session", "-t", window.sessionID, name]))
            commands.append(.tmux(["set-option", "-t", window.sessionID, "@muxify_session_id", window.sessionRecordID]))
            if let destination { commands.append(.tmux(["set-option", "-t", window.sessionID, "@muxify_topic", destination.id])) }
            else { commands.append(.tmux(["set-option", "-u", "-t", window.sessionID, "@muxify_topic"])) }
            if window.lockOrder != nil { commands.append(.tmux(SessionLock.unsetOption(window.sessionID))); endedLockOf = window.sessionID }
            var fields = sourceTopic?.session(of: window)?.object ?? [:]
            fields["id"] = .string(window.sessionRecordID)
            fields["name"] = .string(name)
            fields["base_name"] = .string(SessionNaming.base(of: name, topic: destination))
            fields["directory"] = .string(window.sessionPath.isEmpty ? window.path : window.sessionPath)
            saved?.recordingNewSession(fields, order: order)
        case .window, .pane:
            let members = windows.filter { Self.openTopic(of: $0, records: records)?.id == destination?.id && $0.sessionID != window.sessionID }
            let ids = Set(members.map(\.sessionID))
            let existing: TmuxWindow?
            if let destinationSession {
                guard let chosen = members.first(where: { $0.sessionID == destinationSession }) else { throw Failure.destinationUnavailable }
                existing = chosen
            } else if createSession || destination == nil { existing = nil }
            else if ids.count > 1 { throw Failure.chooseSession }
            else { existing = members.first }
            let target: String
            if let existing { target = existing.sessionID + ":" }
            else {
                let name = SessionNaming.available(base, topic: destination?.slug, taken: taken)
                let id = UUID().uuidString.lowercased()
                let directory = launchDirectory ?? window.path
                target = "=" + name + ":"
                commands.append(.newTopicSession(name: name, directory: directory))
                commands.append(.tmux(["set-option", "-t", target, "@muxify_session_id", id]))
                if let destination { commands.append(.tmux(["set-option", "-t", target, "@muxify_topic", destination.id])) }
                saved?.recordingNewSession(["id": .string(id), "name": .string(name),
                    "base_name": .string(SessionNaming.base(of: name, topic: destination)), "directory": .string(directory)], order: order)
            }
            if let clientTTY { commands.append(.tmux(["switch-client", "-c", clientTTY, "-t", target])) }
            if case .pane(let pane, _) = source, window.paneCount > 1 {
                commands.append(.tmux(["break-pane", "-d", "-s", pane.rawValue, "-t", target]))
            } else { commands.append(.tmux(["move-window", "-d", "-s", window.sessionID + ":" + window.id, "-t", target])) }
            if existing == nil { commands.append(.removeTopicPlaceholder) }
            if let clientTTY {
                let moved: String
                if case .pane(let pane, _) = source { moved = pane.rawValue } else { moved = target + window.id }
                commands.append(.tmux(["switch-client", "-c", clientTTY, "-t", moved]))
            }
        }
        if Self.ends(source, windows: windows), let sourceTopic,
           let left = sourceTopic.forgetting(window) {
            if left.id == saved?.id { saved = saved?.forgetting(window) ?? saved }
            else { leftTopic = left }
        }
        // When leaving for No Topic, the source record is the only record to save.
        if saved == nil { saved = leftTopic; leftTopic = nil }
        record = saved
        self.commands = commands
    }

    init(source: Source, title: String, records: [TopicRecord], windows: [TmuxWindow], sessionPaths: [SessionPath],
          id: String = UUID().uuidString.lowercased(), now: Date = Date(), clientTTY: String? = nil, order: SessionOrder = .oldestFirst,
          launchDirectory: String? = nil) throws {
        let topic = TopicRecord(newTopic: id, title: title, slug: TopicNaming.slug(title: title, records: records), now: now)
        try self.init(source: source, destination: topic, records: records, windows: windows, sessionPaths: sessionPaths,
                       clientTTY: clientTTY, order: order, launchDirectory: launchDirectory)
    }

    private static func isSession(_ source: Source) -> Bool { if case .session = source { return true }; return false }
    static func ends(_ source: Source, windows: [TmuxWindow]) -> Bool {
        if case .pane = source, source.window.paneCount > 1 { return false }
        if case .session = source { return true }
        return !windows.contains { $0.sessionID == source.window.sessionID && $0.id != source.window.id }
    }

    static func openTopic(of window: TmuxWindow, records: [TopicRecord]) -> TopicRecord? {
        records.first { $0.id == window.topicID && $0.settledAt == nil }
    }
}
