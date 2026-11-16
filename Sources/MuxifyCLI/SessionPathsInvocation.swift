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
            guard let lock = RefreshLock(cache.file.appendingPathExtension("lock")) else { return }
            defer { lock.unlock() }
            ConfigSessions.discover(try ConfigSessions.read(paths.configFile), into: cache)
        }
    }

    static func render(_ rows: [RankedSessionPath], output: RequestInvocation.Output) throws -> String {
        let answers = rows.map { SessionPathAnswer($0.row, lastVisit: $0.lastVisit) }
        switch output {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return String(decoding: try encoder.encode(["rows": answers]), as: UTF8.self)
        case .text:
            return answers.map { [$0.name, $0.kind, $0.directory, $0.lastVisit ?? ""].map(\.oneLineField).joined(separator: "\t") }
                .joined(separator: "\n")
        }
    }

    /// Runs `muxify session-paths refresh` in a session of its own, with no terminal and with `/dev/null` for its
    /// input and output. It holds no pipe of this command, so `ssh host muxify session-paths` ends when the answer
    /// is out, and the end of the connection does not stop the refresh. A refresh that does not start costs only an
    /// older answer next time, so a failure here is not an error of the command.
    private static func startRefresh(_ executable: URL, environment: [String: String]) {
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
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
        let arguments = [executable.path] + CLIVerbPath.sessionPathsRefresh.words
        var argv = arguments.map { strdup($0) } + [nil]
        var envp = environment.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        _ = posix_spawn(&pid, executable.path, &actions, &attributes, &argv, &envp)
    }
}

/// One refresh at a time for a cache file: a second one that starts meanwhile has nothing to add, so it ends.
private struct RefreshLock {
    private let descriptor: Int32

    /// Nil when another process holds the lock, or the lock file cannot be made.
    init?(_ file: URL) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(file.path, O_RDWR | O_CREAT, 0o600)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        self.descriptor = descriptor
    }

    func unlock() { close(descriptor) }
}

/// A Session Path or Worktree row in the `--json` answers of `session-paths` and `topic session-paths`.
struct SessionPathAnswer: Encodable {
    struct Topic: Codable, Hashable, Sendable {
        let id: String
        let label: String
        init(_ summary: TopicSummary) { id = summary.id; label = summary.label }
    }

    struct Checkout: Codable, Hashable, Sendable {
        let path: String
        @EncodesNull var branch: String?
    }

    let kind: String
    let name: String
    let label: String
    let directory: String
    let worktree: Checkout?
    /// Only `topic session-paths` has it: whether a Session of that Topic uses this exact folder.
    let inThisTopic: Bool?
    let alsoIn: [Topic]
    /// ISO 8601, in UTC.
    let lastVisit: String?

    init(_ row: SessionPathRow, inThisTopic: Bool? = nil, lastVisit: Date?) {
        let choice = row.choice
        kind = choice.isWorktree ? "worktree" : "session_path"
        name = choice.name
        label = choice.displayName
        directory = choice.directory.path
        worktree = choice.worktree.map { Checkout(path: $0.folder.path, branch: $0.branch) }
        self.inThisTopic = inThisTopic
        alsoIn = row.alsoIn.map(Topic.init)
        self.lastVisit = lastVisit.map(Self.timestamp)
    }

    static func timestamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    private enum CodingKeys: String, CodingKey {
        case kind, name, label, directory, worktree
        case inThisTopic = "in_this_topic"
        case alsoIn = "also_in"
        case lastVisit = "last_visit"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(name, forKey: .name)
        try container.encode(label, forKey: .label)
        try container.encode(directory, forKey: .directory)
        try container.encode(worktree, forKey: .worktree)
        try container.encodeIfPresent(inThisTopic, forKey: .inThisTopic)
        try container.encode(alsoIn, forKey: .alsoIn)
        try container.encode(lastVisit, forKey: .lastVisit)
    }
}
