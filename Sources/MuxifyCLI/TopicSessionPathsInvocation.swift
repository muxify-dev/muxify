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
        print(try Self.render(choices, visits: (try? VisitStore(paths: paths).times()) ?? [:], output: output))
    }

    /// `visits` are this machine's: each row's `last_visit` is the visit to its folder.
    static func render(_ choices: TopicSessionPathChoices, visits: [VisitKey: Date] = [:], output: RequestInvocation.Output) throws -> String {
        let response = TopicSessionPathsAnswer(choices, visits: visits)
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
}
