import Foundation
import MuxifyCore

enum ConfigSessions {
    /// The Config, with its SessionPaths in the layouts git reports. With no Config to fall back on, as the app has,
    /// a syntax error stops the command: a plan with no SessionPaths would record wrong locations. A value that
    /// cannot apply only skips itself, so the command goes on and says so on stderr, one line each. `within` limits
    /// the SessionPaths to those that hold one of the folders; nil finds them all.
    static func load(_ configFile: URL, within folders: [String]? = nil) async throws -> Config {
        let config: Config
        switch Config.load(path: configFile.path, read: { try? String(contentsOfFile: $0, encoding: .utf8) }) {
        case .success(let loaded): config = loaded
        case .failure(let error): throw CLIError(error.problem.description)
        }
        for problem in config.problems {
            FileHandle.standardError.write(Data("muxify: \(problem.description)\n".utf8))
        }
        var discovered = config
        discovered.sessionPaths = SessionPathDiscovery.discover(config.sessionRoots, aliases: config.sessionAliases, within: folders)
        return discovered
    }
}
