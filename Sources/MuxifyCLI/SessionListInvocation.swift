import Foundation
import MuxifyCore

/// The same inventory as the palette: running Sessions and unused exact-named launch paths.
struct SessionListInvocation: Equatable {
    var output: RequestInvocation.Output
    var paths: MuxifyPaths

    struct Entry: Encodable {
        var id: String?
        var name: String
        var label: String
        var directory: String
        var running: Bool
        var topic: TopicSummary?
    }

    func run() async throws {
        let config = try await ConfigSessions.load(paths.configFile)
        let records = try TopicStore(paths: paths).read().records
        let windows = TmuxServer.local.snapshot().windows
        var names = Set<String>()
        var rows: [Entry] = []
        for window in windows where names.insert(window.sessionName).inserted {
            rows.append(Entry(id: window.sessionID, name: window.sessionName, label: window.sessionName,
                directory: window.sessionPath, running: true,
                topic: records.first { $0.id == window.topicID && $0.settledAt == nil }.map(TopicSummary.init)))
        }
        for warning in SessionPathDiscovery.warnings(in: config.sessionPaths) {
            FileHandle.standardError.write(Data((warning + "\n").utf8))
        }
        for choice in SessionChoice.launches(in: config.sessionPaths) where names.insert(choice.name).inserted {
            rows.append(Entry(name: choice.name, label: choice.displayName, directory: choice.directory.path, running: false))
        }
        switch output {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            print(String(decoding: try encoder.encode(["sessions": rows]), as: UTF8.self))
        case .text:
            for row in rows { print([row.name, row.running ? "running" : "launchable", row.directory, row.topic?.label ?? ""].map(\.oneLineField).joined(separator: "\t")) }
        }
    }
}

extension String {
    var oneLineField: String { replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ") }
}
