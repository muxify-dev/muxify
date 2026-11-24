import Foundation
import MuxifyCore

struct GoToInvocation: Equatable {
    var ask: GoToRequest
    var output: RequestInvocation.Output
    var environment: [String: String]
    var now: Date

    init(_ ask: GoToRequest, parsed: ParsedArguments) {
        self.ask = ask
        output = parsed.output
        environment = parsed.environment
        now = parsed.now
    }

    private var home: String { environment["HOME"] ?? NSHomeDirectory() }

    func run(executable: URL) async throws {
        let paths = MuxifyPaths(environment: environment, home: home)
        let (config, fromCache) = try ConfigSessions.loadCached(paths.configFile, cache: SessionPathCache(file: paths.sessionPathCache(remote: nil)))
        let answer: GoToAnswer
        switch EnvironmentService(paths: paths, sessionPaths: config.sessionPaths, topics: config.topics, notifications: config.notifications)
            .goTo(ask, palette: config.goToPalette, offersTopics: config.sidebar.board, home: home, now: now) {
        case .success(let list): answer = list
        case .failure(let failure): throw CLIError(failure)
        }
        for warning in SessionPathDiscovery.warnings(in: config.sessionPaths) {
            FileHandle.standardError.write(Data((warning + "\n").utf8))
        }
        print(try Self.render(answer, output: output))
        fflush(stdout)
        if fromCache { SessionPathsInvocation.startRefresh(executable, environment: environment) }
    }

    static func render(_ answer: GoToAnswer, output: RequestInvocation.Output) throws -> String {
        switch output {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return String(decoding: try encoder.encode(answer), as: UTF8.self)
        case .text:
            return answer.rows.map { [$0.kind, $0.title.text, $0.detail.text, $0.trailing].map(\.oneLineField).joined(separator: "\t") }
                .joined(separator: "\n")
        }
    }
}
