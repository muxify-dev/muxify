import Foundation

enum TopicPaneRequest {
    case currentClient
    case window(String)
    case pane(String)
}

struct TopicPaneIdentity {
    public let paneID: String
    public let windowID: String
    public let sessionID: String
    public let paneCount: Int

    public init(output: String) throws {
        let fields = output.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count == 4, fields[0].hasPrefix("%"), fields[1].hasPrefix("@"),
              fields[2].hasPrefix("$"), let paneCount = Int(fields[3]), paneCount > 0 else {
            throw TopicEditFailure.invalidTmuxResponse
        }
        paneID = fields[0]
        windowID = fields[1]
        sessionID = fields[2]
        self.paneCount = paneCount
    }

    public func source(in snapshot: TmuxSnapshot) throws -> TopicPaneSource {
        guard let window = snapshot.windows.first(where: {
            $0.id == windowID && $0.sessionID == sessionID && $0.paneCount == paneCount
        }), snapshot.panes.contains(where: { $0.id == paneID && $0.windowID == windowID }) else {
            throw TopicEditFailure.sourceUnavailable
        }
        let path = snapshot.panes.first { $0.id == paneID }?.path
        return TopicPaneSource(paneID: paneID, window: window, directory: path.flatMap { $0.isEmpty ? nil : $0 })
    }
}
