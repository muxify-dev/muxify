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
        config.sessionPaths = sessionPaths(in: cached ?? SessionPathDiscovery.output(for: config.sessionRoots, within: folders), config)
        return config
    }

    /// The Config with the SessionPaths of the discovery cache, and whether the cache had them. Without them it
    /// finds the SessionPaths and saves them, so only the first answer on a machine waits for the discovery.
    static func loadCached(_ configFile: URL, cache: SessionPathCache) throws -> (config: Config, fromCache: Bool) {
        var config = try read(configFile)
        let arguments = SessionPathDiscovery.arguments(for: config.sessionRoots)
        let cached = config.sessionRoots.isEmpty ? nil : cache.output(for: arguments)
        config.sessionPaths = sessionPaths(in: cached ?? discover(config, into: cache), config)
        return (config, cached != nil)
    }

    /// Finds every SessionPath of the Config and saves the output in `cache`. Nil when the Config has no
    /// `sessions.paths` or the discovery fails, which saves nothing.
    @discardableResult
    static func discover(_ config: Config, into cache: SessionPathCache) -> String? {
        guard !config.sessionRoots.isEmpty, let output = SessionPathDiscovery.output(for: config.sessionRoots) else { return nil }
        cache.save(output, for: SessionPathDiscovery.arguments(for: config.sessionRoots))
        return output
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

    private static func sessionPaths(in output: String?, _ config: Config) -> [SessionPath] {
        output.map { SessionPathDiscovery.sessionPaths(in: $0, roots: config.sessionRoots, aliases: config.sessionAliases) } ?? []
    }
}
