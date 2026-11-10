import Foundation
import MuxifyCore

struct TopicSessionPathsInvocation: Equatable {
    var target: EnvironmentTarget
    var output: RequestInvocation.Output
    var paths: MuxifyPaths

    init(parsed: ParsedArguments) throws {
        guard parsed.operands.isEmpty else { throw CLIError.usage }
        let caller = try parsed.targets.caller(environment: parsed.environment, needed: true, offered: [.topic, .window, .pane])
        guard let target = parsed.targets.chosen?.target ?? caller.map(EnvironmentTarget.pane) else { throw CLIError.usage }
        self.target = target
        output = parsed.output
        paths = parsed.paths
    }

    func run() async throws {
        let config = try await ConfigSessions.load(paths.configFile, cache: SessionPathCache(file: paths.sessionPathCache(remote: nil)))
        let choices: TopicSessionPathChoices
        switch EnvironmentService(paths: paths, sessionPaths: config.sessionPaths, topics: config.topics).sessionPathChoices(for: target) {
        case .success(let value): choices = value
        case .failure(let failure): throw CLIError(failure)
        }
        for warning in SessionPathDiscovery.warnings(in: config.sessionPaths) {
            FileHandle.standardError.write(Data((warning + "\n").utf8))
        }
        print(try Self.render(choices, output: output))
    }

    static func render(_ choices: TopicSessionPathChoices, output: RequestInvocation.Output) throws -> String {
        let response = Response(choices)
        switch output {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return String(decoding: try encoder.encode(response), as: UTF8.self)
        case .text:
            let rows = response.rows.map { [$0.name, $0.kind, $0.directory, response.topic.label] }
            let sessions = response.sessions.map { [$0.name, "running", $0.directory, $0.topic?.label ?? ""] }
            return (rows + sessions).map { $0.map(\.oneLineField).joined(separator: "\t") }.joined(separator: "\n")
        }
    }

    private struct Topic: Codable, Hashable, Sendable {
        let id: String
        let label: String
        init(_ summary: TopicSummary) { id = summary.id; label = summary.label }
    }

    private struct Checkout: Codable, Hashable, Sendable {
        let path: String
        @EncodesNull var branch: String?
    }

    private struct Row: Encodable {
        let kind: String
        let name: String
        let label: String
        let directory: String
        @EncodesNull var worktree: Checkout?
        let inThisTopic: Bool
        let alsoIn: [Topic]
        @EncodesNull var lastVisit: Double? = nil

        enum CodingKeys: String, CodingKey {
            case kind, name, label, directory, worktree
            case inThisTopic = "in_this_topic"
            case alsoIn = "also_in"
            case lastVisit = "last_visit"
        }
    }

    private struct Session: Encodable {
        let id: String
        let name: String
        let directory: String
        @EncodesNull var topic: Topic?
    }

    private struct Response: Encodable {
        let topic: Topic
        let rows: [Row]
        let sessions: [Session]

        init(_ choices: TopicSessionPathChoices) {
            topic = Topic(choices.topic)
            rows = choices.rows.map { value in
                let choice = value.row.choice
                return Row(kind: choice.isWorktree ? "worktree" : "session_path", name: choice.name,
                           label: choice.displayName, directory: choice.directory.path,
                           worktree: choice.worktree.map { Checkout(path: $0.folder.path, branch: $0.branch) },
                           inThisTopic: value.inThisTopic, alsoIn: value.row.alsoIn.map(Topic.init))
            }
            sessions = choices.sessions.map { Session(id: $0.id, name: $0.name, directory: $0.directory, topic: $0.topic.map(Topic.init)) }
        }
    }
}
