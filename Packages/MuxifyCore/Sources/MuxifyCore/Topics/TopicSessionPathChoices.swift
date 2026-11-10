import Foundation

public struct TopicSessionPathChoices: Sendable {
    public let topic: TopicSummary
    public let rows: [Row]
    public let sessions: [Session]

    public struct Row: Sendable {
        public let row: SessionPathRow
        public let inThisTopic: Bool
    }

    public struct Session: Sendable {
        public let id: String
        public let name: String
        public let directory: String
        public let topic: TopicSummary?
    }

    init(topic: TopicRecord, records: [TopicRecord], windows: [TmuxWindow], sessionPaths: [SessionPath]) {
        let labels = TopicLabels(records)
        self.topic = TopicSummary(record: topic, labels: labels)
        var seen = Set<String>()
        let firstWindows = windows.filter { seen.insert($0.sessionID).inserted }
        let live = firstWindows.filter { $0.topicID == topic.id }.map { $0.sessionPath.isEmpty ? $0.path : $0.sessionPath }
        let remembered = topic.sessions.compactMap { $0["directory"]?.string }
        let folders = (live + remembered).filter { !$0.isEmpty }.map(Folder.local)
        rows = SessionPathRows.build(sessionPaths: sessionPaths, windows: windows, records: records, addingTo: topic).map {
            Row(row: $0, inThisTopic: folders.contains($0.choice.directory))
        }
        sessions = firstWindows.filter { $0.topicID != topic.id }.map { window in
            Session(id: window.sessionID, name: window.sessionName, directory: window.sessionPath,
                    topic: records.first { $0.id == window.topicID && $0.settledAt == nil }.map { TopicSummary(record: $0, labels: labels) })
        }
    }
}
