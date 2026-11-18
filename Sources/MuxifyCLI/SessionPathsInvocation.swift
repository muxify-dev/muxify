#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation
import MuxifyCore

/// `session-paths`: this machine's Session Paths and Worktrees for a caller with no Topic, Window or Pane, such as
/// the phone, in the order Go to… gives them.
struct SessionPathsInvocation: Equatable {
    enum Action: Equatable {
        case list(query: String)
        /// Finds the Session Paths again and saves them in the discovery cache.
        case refresh
    }

    var action: Action
    var output: RequestInvocation.Output
    /// The environment of the command line. The refresh that `list` starts gets it, so it writes the same cache.
    var environment: [String: String]

    init(_ action: Action, parsed: ParsedArguments) {
        self.action = action
        output = parsed.output
        environment = parsed.environment
    }

    private var paths: MuxifyPaths { MuxifyPaths(environment: environment, home: home) }
    private var home: String { environment["HOME"] ?? NSHomeDirectory() }
    private var cache: SessionPathCache { SessionPathCache(file: paths.sessionPathCache(remote: nil)) }

    func run(executable: URL) async throws {
        switch action {
        case .list(let query):
            let (config, fromCache) = try ConfigSessions.loadCached(paths.configFile, cache: cache)
            let rows: [RankedSessionPath]
            switch EnvironmentService(paths: paths, sessionPaths: config.sessionPaths, topics: config.topics)
                .rankedSessionPaths(query: query, tiebreak: config.goToPalette.rules.tiebreak, home: home) {
            case .success(let ranked): rows = ranked
            case .failure(let failure): throw CLIError(failure)
            }
            for warning in SessionPathDiscovery.warnings(in: config.sessionPaths) {
                FileHandle.standardError.write(Data((warning + "\n").utf8))
            }
            print(try Self.render(rows, output: output))
            // The caller has its answer before the discovery starts: a slow `git worktree list` holds nothing.
            fflush(stdout)
            if fromCache { Self.startRefresh(executable, environment: environment) }
        case .refresh:
            cache.refresh(try ConfigSessions.read(paths.configFile))
        }
    }

    static func render(_ rows: [RankedSessionPath], output: RequestInvocation.Output) throws -> String {
        let answer = RankedSessionPathsAnswer(rows)
        switch output {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return String(decoding: try encoder.encode(answer), as: UTF8.self)
        case .text:
            return answer.rows.map { [$0.name, $0.kind, $0.directory, $0.lastVisit ?? ""].map(\.oneLineField).joined(separator: "\t") }
                .joined(separator: "\n")
        }
    }

    #if canImport(Darwin)
    private static let newSession = Int16(POSIX_SPAWN_SETSID)
    #else
    /// glibc declares POSIX_SPAWN_SETSID only under _GNU_SOURCE, which Swift's Glibc module does not set. glibc and
    /// musl both give it this value.
    private static let newSession: Int16 = 0x80
    #endif

    /// Runs `muxify session-paths refresh` in a session of its own, with no terminal and with `/dev/null` for its
    /// input and output. It holds no descriptor of this command, so `ssh host muxify session-paths` ends when the
    /// answer is out, and the end of the connection does not stop the refresh. A refresh that does not start costs
    /// only an older answer next time, so a failure here is not an error of the command.
    private static func startRefresh(_ executable: URL, environment: [String: String]) {
        // posix_spawn passes on each descriptor without FD_CLOEXEC, such as a pipe whose end tells a caller that this
        // command ended. This command exits next, so closing them all at the exec costs it nothing.
        for name in (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd")) ?? [] {
            if let descriptor = Int32(name), descriptor > STDERR_FILENO { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }
        }
        #if canImport(Darwin)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        #else
        var actions = posix_spawn_file_actions_t()
        var attributes = posix_spawnattr_t()
        #endif
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null", descriptor == STDIN_FILENO ? O_RDONLY : O_WRONLY, 0)
        }
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Self.newSession)
        let arguments = [executable.path] + CLIVerbPath.sessionPathsRefresh.words
        var argv = arguments.map { strdup($0) } + [nil]
        var envp = environment.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        _ = posix_spawn(&pid, executable.path, &actions, &attributes, &argv, &envp)
    }
}
