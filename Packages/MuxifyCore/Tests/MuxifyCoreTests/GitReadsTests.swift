#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import XCTest
@testable import MuxifyCore

/// A temporary repository with a private HOME, so the user's git config can't change what git prints: `master` with
/// one commit and a tag, `feature` one commit ahead, a stash, a staged and unstaged change, and a new file.
final class GitTestRepository {
    let directory: URL
    let environment: [String: String]
    var path: String { directory.appendingPathComponent("repo").path }
    var reader: GitReader { GitReader(scripts: Scripts(environment: environment)) }

    /// Runs the scripts with the private HOME, as the app's `LocalScripts` runs them with the user's.
    struct Scripts: ScriptRunning {
        let environment: [String: String]

        func runScript(_ script: String, arguments: [String], timeout: TimeInterval) throws -> String {
            try CommandRunner().run(CommandInvocation(executable: "/bin/sh", arguments: ["-c", script, "muxify"] + arguments),
                                    timeout: timeout, environment: environment)
        }
    }

    init() throws {
        let made = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("muxify-git-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        // The physical path, as git prints it: /tmp and /var are links on macOS.
        guard let real = realpath(made.path, nil) else { throw CocoaError(.fileNoSuchFile) }
        directory = URL(fileURLWithPath: String(cString: real))
        free(real)
        environment = [
            "HOME": directory.path, "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_AUTHOR_NAME": "Yauhen Karatkou", "GIT_AUTHOR_EMAIL": "y@example.com",
            "GIT_COMMITTER_NAME": "Yauhen Karatkou", "GIT_COMMITTER_EMAIL": "y@example.com",
        ]
        try run("""
        cd "$1"
        git init -q -b master repo && cd repo
        printf 'let a = 1\\n' > a.swift
        git add a.swift && git commit -q -m First -m 'The body.'
        git tag v1
        git checkout -q -b feature
        printf 'let b = 2\\n' > b.swift
        git add b.swift && git commit -q -m 'Add b'
        git checkout -q master
        printf 'stashed\\n' >> a.swift && git stash push -q -m wip
        printf 'let a = 2\\n' > a.swift && git add a.swift && printf '// more\\n' >> a.swift
        printf 'hello\\nworld\\n' > c.txt
        """, directory.path)
    }

    /// Runs a script in the repository, its folder as `$1`.
    @discardableResult
    func run(_ script: String, _ arguments: String...) throws -> String {
        try Scripts(environment: environment).runScript(script, arguments: arguments.isEmpty ? [path] : arguments, timeout: 30)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Each of the Git View's reads against a temporary repository returns what the Git View showed from its script.
final class GitReadsTests: XCTestCase {
    private var repository: GitTestRepository!

    override func setUpWithError() throws {
        repository = try GitTestRepository()
    }

    override func tearDown() {
        repository?.remove()
    }

    private func read(_ read: GitRead) throws -> GitAnswer {
        try repository.reader.run(read)
    }

    func testStatusListsTheChangesWithTheirStagedAndUnstagedCountsTheBranchesAndTheStashes() throws {
        let snapshot = try XCTUnwrap(read(.status(folder: repository.path)).snapshot)
        XCTAssertEqual(snapshot.root, repository.path)
        XCTAssertEqual(snapshot.repositoryName, "repo")
        XCTAssertEqual(snapshot.head, "master")
        XCTAssertFalse(snapshot.isDetached)
        XCTAssertEqual(snapshot.changes.map(\.status), ["MM", "??"])
        let changed = try XCTUnwrap(snapshot.changes.first { $0.path == "a.swift" })
        XCTAssertEqual(changed.groups, [.unstaged, .staged])
        XCTAssertEqual(changed.additions, 2, "the staged line and the unstaged line together")
        XCTAssertEqual(changed.deletions, 1)
        let new = try XCTUnwrap(snapshot.changes.first { $0.path == "c.txt" })
        XCTAssertEqual(new.additions, 2, "an untracked file counts its lines")
        XCTAssertEqual(new.deletions, 0)
        XCTAssertEqual(snapshot.branches.map(\.name), ["master", "feature"], "the current branch first")
        XCTAssertEqual(snapshot.branches.first?.isHead, true)
        XCTAssertEqual(snapshot.branches.last.map { ($0.ahead, $0.behind) }?.0, 1, "feature is a commit ahead of HEAD")
        XCTAssertEqual(snapshot.commits.map(\.subject), ["First"])
        XCTAssertEqual(snapshot.commits.first?.tags, ["v1"])
        XCTAssertEqual(snapshot.graph.count, 1)
        XCTAssertEqual(snapshot.stashes.map(\.message), ["On master: wip"])
        XCTAssertEqual(snapshot.stashes.first?.ref, "stash@{0}")
        XCTAssertEqual(snapshot.mainBranch, "master")

        // The snapshot crosses the wire whole.
        let wire = try JSONDecoder().decode(GitSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(wire, snapshot)
    }

    func testAFolderInNoRepositoryFailsWithTheGitViewsMessage() throws {
        XCTAssertThrowsError(try read(.status(folder: repository.directory.path))) { error in
            XCTAssertEqual(GitReader.message(for: error), "Not a git repository: \(repository.directory.path)")
        }
        XCTAssertThrowsError(try read(.status(folder: repository.directory.path + "/gone"))) { error in
            XCTAssertEqual(GitReader.message(for: error), "No such folder: \(repository.directory.path)/gone")
        }
    }

    func testTheLogDiffFileContentCommitAndStashReadAsTheGitViewShowedThem() throws {
        let log = try XCTUnwrap(read(.log(root: repository.path, branch: "feature")).log)
        XCTAssertEqual(log.commits.map(\.subject), ["Add b", "First"])
        XCTAssertEqual(log.graph.count, 2)

        let diff = try XCTUnwrap(read(.change(root: repository.path, path: "a.swift", from: nil, context: 3,
                                              groups: [.unstaged, .staged])).text)
        let parts = GitReads.parseParts(diff)
        XCTAssertEqual(parts.map(\.group), [.unstaged, .staged])
        XCTAssertTrue(parts[0].patch.contains("+// more"), parts[0].patch)
        XCTAssertTrue(parts[1].patch.contains("+let a = 2"), parts[1].patch)
        XCTAssertTrue(parts[1].patch.contains("-let a = 1"), parts[1].patch)

        let untracked = try XCTUnwrap(read(.change(root: repository.path, path: "c.txt", from: nil, context: 3, groups: [.untracked])).text)
        XCTAssertTrue(GitReads.parseParts(untracked).first?.patch.contains("+world") == true, untracked)

        // The whole file: every line is context or a change.
        try repository.run("cd \"$1\" && seq 1 40 > long.txt && git add long.txt && git commit -q -m Long && sed -i.bak 's/^20$/twenty/' long.txt && rm long.txt.bak")
        let whole = try XCTUnwrap(read(.change(root: repository.path, path: "long.txt", from: nil, context: 100_000, groups: [.unstaged])).text)
        let lines = GitReads.parseParts(whole).first?.patch.split(separator: "\n") ?? []
        XCTAssertTrue(lines.contains(" 1") && lines.contains(" 40") && lines.contains("+twenty"), "the file content is not whole: \(whole)")
        let near = try XCTUnwrap(read(.change(root: repository.path, path: "long.txt", from: nil, context: 3, groups: [.unstaged])).text)
        XCTAssertFalse(near.split(separator: "\n").contains(" 1"))

        let first = try repository.run("cd \"$1\" && git rev-list --max-parents=0 HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
        let commit = GitReads.parseCommitDetail(try XCTUnwrap(read(.commit(root: repository.path, sha: first)).text))
        XCTAssertEqual(commit.detail?.title, "First")
        XCTAssertEqual(commit.detail?.body, "The body.")
        XCTAssertEqual(commit.detail?.sha, first)
        XCTAssertTrue(commit.patch.contains("+let a = 1"), commit.patch)

        let stash = try XCTUnwrap(read(.status(folder: repository.path)).snapshot?.stashes.first)
        let patch = try XCTUnwrap(read(.stash(root: repository.path, sha: stash.sha)).text)
        XCTAssertTrue(patch.contains("+stashed"), patch)

        let range = try XCTUnwrap(read(.range(root: repository.path, from: "master", to: "feature")).text)
        XCTAssertTrue(range.contains("+++ b/b.swift"), range)
    }

    func testTheLinksReadTheUpstreamOfABranchAndTheOriginRemote() throws {
        try repository.run("""
        cd "$1"
        git remote add origin git@github.com:me/repo.git
        git config branch.feature.remote origin
        git config branch.feature.merge refs/heads/topic/feature
        git config url.https://github.com/.insteadOf git@github.com:
        """)
        XCTAssertEqual(try read(.upstream(root: repository.path, branch: "feature")).remote,
                       GitRemote(url: "https://github.com/me/repo.git", branch: "topic/feature"))
        XCTAssertEqual(try read(.origin(root: repository.path)).remote, GitRemote(url: "https://github.com/me/repo.git\n"))
        XCTAssertThrowsError(try read(.upstream(root: repository.path, branch: "master"))) { error in
            XCTAssertEqual(GitReader.message(for: error), GitHosting.Failure.noUpstream.message)
        }
    }

    /// The probe reads the same while nothing changes, even a file whose time changed and whose index entry
    /// `git status` would otherwise rewrite, and reads otherwise after a commit.
    func testTheProbeIsStableUntilTheRepositoryChangesAndNeverWritesTheIndex() throws {
        try repository.run("""
        cd "$1" && printf 'd\\n' > d.txt && git add d.txt && git commit -q -m d && touch -t 202001010000 d.txt
        """)
        let index = { try FileManager.default.attributesOfItem(atPath: self.repository.path + "/.git/index")[.modificationDate] as? Date }
        let first = repository.reader.probe(repository.path)
        XCTAssertEqual(first.head, .repository(head: "master"))
        XCTAssertEqual(first.root, repository.path)
        XCTAssertEqual(first.gitDirectory, repository.path + "/.git")
        XCTAssertEqual(first.commonDirectory, repository.path + "/.git")
        let fingerprint = try XCTUnwrap(first.fingerprint)
        XCTAssertTrue(fingerprint.contains("refs/heads/master"), fingerprint)
        let indexTime = try index()
        XCTAssertEqual(repository.reader.probe(repository.path), first, "nothing changed, yet the probe read otherwise")
        XCTAssertEqual(try index(), indexTime, "the probe wrote the index")
        try repository.run("cd \"$1\" && git add c.txt && git commit -q -m Second")
        XCTAssertNotEqual(repository.reader.probe(repository.path).fingerprint, fingerprint, "a commit left the probe the same")
        // A folder in no repository says so; one that is gone knows nothing.
        XCTAssertEqual(repository.reader.probe(repository.directory.path), RepositoryProbe(head: .notRepository))
        XCTAssertEqual(repository.reader.probe(repository.directory.path + "/gone"), RepositoryProbe(head: .unknown))
    }

    func testTheGitRequestsAndTheRepositorySubscriptionArePinned() throws {
        func text(_ line: Data) -> String { String(decoding: line, as: UTF8.self) }
        XCTAssertEqual(text(try ProtocolLine.request(id: 2, HostRequest.git(.status(folder: "/r")))),
                       #"{"id":2,"kind":"request","request":{"git":{"status":{"folder":"/r"}}}}"# + "\n")
        XCTAssertEqual(text(try ProtocolLine.request(id: 3, HostRequest.git(.change(root: "/r", path: "a", from: nil, context: 3,
                                                                                   groups: [.unstaged, .staged])))),
                       #"{"id":3,"kind":"request","request":{"git":{"change":{"context":3,"groups":["unstaged","staged"],"path":"a","root":"/r"}}}}"# + "\n")
        XCTAssertEqual(text(try ProtocolLine.request(id: 4, HostRequest.git(.upstream(root: "/r", branch: "f")))),
                       #"{"id":4,"kind":"request","request":{"git":{"upstream":{"branch":"f","root":"/r"}}}}"# + "\n")
        XCTAssertEqual(text(try ProtocolLine.request(id: 5, HostRequest.subscribe(.repository(RepositorySubscription(path: "/r"))))),
                       #"{"id":5,"kind":"request","request":{"subscribe":{"repository":{"path":"/r"}}}}"# + "\n")
        XCTAssertEqual(text(try ProtocolLine.item(id: 5, RepositoryEvent(head: "main", repository: true, changed: true))),
                       #"{"id":5,"item":{"changed":true,"head":"main","repository":true},"kind":"item"}"# + "\n")
        XCTAssertEqual(text(try ProtocolLine.ok(id: 4, GitRemote(url: "u", branch: "b"))), #"{"end":{"ok":{"branch":"b","url":"u"}},"id":4,"kind":"end"}"# + "\n")
        let change = GitChange(index: "R", worktree: " ", path: "new", originalPath: "old", additions: 1, deletions: 0)
        XCTAssertEqual(text(try JSONEncoder.sorted.encode(change)),
                       #"{"additions":1,"deletions":0,"original_path":"old","path":"new","status":"R "}"#)
        XCTAssertEqual(text(try JSONEncoder.sorted.encode(GitOperation.rebase(branch: "f", step: 2, steps: 5))),
                       #"{"branch":"f","kind":"rebase","step":2,"steps":5}"#)
        for operation in [GitOperation.merge(["a", "b"]), .applying(step: nil, steps: 3), .cherryPick("c"), .revert("d"), .bisect] {
            XCTAssertEqual(try JSONDecoder().decode(GitOperation.self, from: JSONEncoder().encode(operation)), operation)
        }
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }
}

/// The Host Server's `repository` watch: the git directory's watch (inotify on Linux) and the probe.
final class RepositoryWatchTests: XCTestCase {
    private var repository: GitTestRepository!

    override func setUpWithError() throws {
        repository = try GitTestRepository()
    }

    override func tearDown() {
        repository?.remove()
    }

    /// The probe runs once a minute here, so only the git directory's watch can see a commit and a checkout in time.
    func testTheGitDirectoryWatchSeesACommitAndACheckoutLongBeforeTheProbe() throws {
        let events = Events()
        let watch = RepositoryWatch(path: repository.path, reader: repository.reader, probeInterval: 60) { events.add($0) }
        watch.start()
        defer { watch.stop() }
        try events.wait("no first event") { $0.count == 1 }
        XCTAssertEqual(events.all.first, RepositoryEvent(head: "master", repository: true, changed: false))
        XCTAssertTrue(watch.watchesGitDirectory, "the git directory has no watch on this system")

        try repository.run("cd \"$1\" && git add c.txt && git commit -q -m Watched")
        try events.wait("the watch did not see a commit", seconds: 3) { $0.count >= 2 }
        XCTAssertEqual(events.all.last, RepositoryEvent(head: "master", repository: true, changed: true))

        let seen = events.all.count
        try repository.run("cd \"$1\" && git checkout -q -b watched")
        try events.wait("the watch did not see a checkout", seconds: 3) { $0.last?.head == "watched" && $0.count > seen }
        XCTAssertEqual(events.all.last, RepositoryEvent(head: "watched", repository: true, changed: true))
    }

    func testTheProbeSeesAnEditInTheWorkingTreeAndAFolderInNoRepositoryIsOneEvent() throws {
        let events = Events()
        let watch = RepositoryWatch(path: repository.path, reader: repository.reader, probeInterval: 0.2) { events.add($0) }
        watch.start()
        defer { watch.stop() }
        try events.wait("no first event") { $0.count == 1 }
        try "edited\n".write(toFile: repository.path + "/c.txt", atomically: false, encoding: .utf8)
        try "new\n".write(toFile: repository.path + "/d.txt", atomically: false, encoding: .utf8)
        try events.wait("the probe did not see an edit in the working tree", seconds: 3) { $0.count >= 2 }
        XCTAssertEqual(events.all.last?.changed, true)

        let outside = Events()
        let none = RepositoryWatch(path: repository.directory.path, reader: repository.reader, probeInterval: 0.1) { outside.add($0) }
        none.start()
        defer { none.stop() }
        try outside.wait("no first event in no repository") { $0.count == 1 }
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertEqual(outside.all, [RepositoryEvent(head: nil, repository: false, changed: false)])
        XCTAssertFalse(none.watchesGitDirectory)
    }
}

/// The events a watch or a subscription sent, from any thread.
final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [RepositoryEvent] = []

    func add(_ event: RepositoryEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    var all: [RepositoryEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    func wait(_ message: String, seconds: TimeInterval = 5, until done: ([RepositoryEvent]) -> Bool) throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(all) {
            guard Date() < deadline else { return XCTFail("\(message): \(all)") }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }
}

/// The Git View's reads and the `repository` subscription through a pair of pipes: a protocol client and `HostServer`
/// in this process, against a temporary repository.
final class HostServerGitTests: XCTestCase {
    private var repository: GitTestRepository!
    private var directory: URL!
    private var servers: [ProtocolServer] = []
    private var clients: [ProtocolClient] = []
    private var consumers: [Task<Void, Never>] = []

    override class func setUp() {
        super.setUp()
        signal(SIGPIPE, SIG_IGN)
    }

    override func setUpWithError() throws {
        repository = try GitTestRepository()
        directory = repository.directory
    }

    override func tearDown() async throws {
        consumers.forEach { $0.cancel() }
        clients.forEach { $0.close() }
        for server in servers { _ = await server.wait() }
        repository?.remove()
    }

    private func connect() async throws -> ProtocolClient {
        let up = Pipe(), down = Pipe()
        // No tmux runs: these requests never reach it.
        let context = HostServerContext(paths: MuxifyPaths(environment: ["XDG_STATE_HOME": directory.appendingPathComponent("state").path],
                                                           home: "/nonexistent"),
                                        tmux: TmuxServer(socketPath: directory.appendingPathComponent("no-tmux").path, configPath: "/dev/null"),
                                        git: repository.reader)
        let server = HostServer.make(input: up.fileHandleForReading, output: down.fileHandleForWriting, build: "server", context: context)
        server.start()
        servers.append(server)
        let client = ProtocolClient(input: down.fileHandleForReading, output: up.fileHandleForWriting, build: "client", helloTimeout: 5)
        clients.append(client)
        try await client.connect()
        return client
    }

    func testRepositoryPushesAfterACommitAStageAndAWorkingTreeEdit() async throws {
        let client = try await connect()
        let events = Events()
        let stream = client.subscribe(HostRequest.subscribe(.repository(RepositorySubscription(path: repository.path))), as: RepositoryEvent.self)
        consumers.append(Task {
            do { for try await event in stream { events.add(event) } } catch {}
        })
        try events.wait("no first event") { $0.count == 1 }
        XCTAssertEqual(events.all, [RepositoryEvent(head: "master", repository: true, changed: false)], "the first event is the whole state")

        for (what, script) in [("a commit", "git commit -q -m Staged"), ("a stage", "git add c.txt"),
                               ("a working-tree edit", "printf 'edit\\n' >> c.txt")] {
            let seen = events.all.count
            try repository.run("cd \"$1\" && " + script)
            // The edit is seen by the 2 s probe; the commit and the stage by the git directory's watch too.
            try events.wait("repository pushed nothing after \(what)", seconds: 6) { $0.count > seen }
            XCTAssertEqual(events.all.last?.changed, true, what)
            XCTAssertEqual(events.all.last?.head, "master", what)
        }
    }

    func testADiffLargerThan64KiBArrivesAsChunks() async throws {
        let client = try await connect()
        try repository.run("cd \"$1\" && i=0; while [ $i -lt 4000 ]; do printf 'line %05d of a long new file\\n' $i; i=$((i + 1)); done > big.txt")
        let read = GitRead.change(root: repository.path, path: "big.txt", from: nil, context: 3, groups: [.untracked])
        var chunks: [Data] = []
        for try await chunk in client.stream(HostRequest.git(read)) { chunks.append(chunk) }
        let text = String(decoding: chunks.reduce(Data(), +), as: UTF8.self)
        XCTAssertGreaterThan(text.utf8.count, HostProtocol.maxChunkBytes)
        XCTAssertGreaterThan(chunks.count, 1, "a large diff came as one item")
        XCTAssertTrue(chunks.allSatisfy { $0.count <= HostProtocol.maxChunkBytes })
        XCTAssertEqual(text, try repository.reader.run(read).text, "the chunks are not the diff the Mac reads locally")
    }

    func testTheReadsOverTheWireAnswerWhatTheyAnswerLocally() async throws {
        let client = try await connect()
        let status = GitRead.status(folder: repository.path)
        let snapshot = try await client.call(HostRequest.git(status), as: GitSnapshot.self)
        XCTAssertEqual(snapshot, try repository.reader.run(status).snapshot)
        let log = GitRead.log(root: repository.path, branch: "feature")
        let history = try await client.call(HostRequest.git(log), as: GitLog.self)
        XCTAssertEqual(history, try repository.reader.run(log).log)
        do {
            _ = try await client.call(HostRequest.git(.status(folder: directory.path)), as: GitSnapshot.self)
            XCTFail("a folder in no repository answered a snapshot")
        } catch let error as ProtocolError {
            XCTAssertEqual(error, ProtocolError(.failed, "Not a git repository: \(directory.path)"))
        }
    }
}
