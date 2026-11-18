import Foundation
import MuxifyCore

enum ConfigSessions {
    /// The Config, with its SessionPaths in the layouts git reports. With no Config to fall back on, as the app has,
    /// a syntax error stops the command: a plan with no SessionPaths would record wrong locations. A value that
    /// cannot apply only skips itself, so the command goes on and says so on stderr, one line each. `within` limits
    /// the SessionPaths to those that hold one of the folders; nil finds them all.
    static func load(_ configFile: URL, within folders: [String]? = nil, cache: SessionPathCache? = nil) async throws -> Config {
        var config = try read(configFile)
        let cached = folders == nil && !config.sessionRoots.isEmpty
            ? cache?.output(for: SessionPathDiscovery.arguments(for: config.sessionRoots)) : nil
        config.sessionPaths = config.sessionPaths(inDiscovery: cached ?? SessionPathDiscovery.output(for: config.sessionRoots, within: folders))
        return config
    }

    /// The Config with the SessionPaths of the discovery cache, and whether the cache had them. Without them it
    /// finds the SessionPaths and saves them, so only the first answer on a machine waits for the discovery.
    static func loadCached(_ configFile: URL, cache: SessionPathCache) throws -> (config: Config, fromCache: Bool) {
        var config = try read(configFile)
        let found = cache.sessionPaths(of: config)
        config.sessionPaths = found.sessionPaths
        return (config, found.fromCache)
    }

    static func read(_ configFile: URL) throws -> Config {
        let config: Config
        switch Config.load(path: configFile.path, read: { try? String(contentsOfFile: $0, encoding: .utf8) }) {
        case .success(let loaded): config = loaded
        case .failure(let error): throw CLIError(error.problem.description)
        }
        for problem in config.problems {
            FileHandle.standardError.write(Data("muxify: \(problem.description)\n".utf8))
        }
        return config
    }
}
