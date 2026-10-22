import Darwin
import Foundation
import MuxifyCore

/// `topic exec`: one child process per live Session of a Topic, each in its Session's folder, all at the same time.
/// It never types into a Pane, so an Agent or a shell in the Topic sees no input.
struct TopicExec {
    /// A live Session and the folder its command runs in: its Worktree, else its SessionPath.
    struct Target {
        var session: TopicDetail.Session
        var directory: String
    }

    enum Outcome: Equatable {
        case exited(Int32)
        case timedOut
        /// The command could not start in this Session, for example because its folder is gone.
        case notStarted(String)
    }

    struct Run {
        var target: Target
        var outcome: Outcome
        var stdout: Data
        var stderr: Data
    }

    let arguments: [String]
    let timeout: TimeInterval

    /// The Sessions of `topic` to run in. A `sessionPath` directory keeps only the Session in that folder, else the one
    /// Session of that SessionPath.
    static func sessions(of topic: TopicDetail, session: String?) throws -> [Target] {
        let all = topic.sessions.map { Target(session: $0, directory: $0.directory) }
        guard !all.isEmpty else { throw CLIError("the Topic \(topic.label) has no live Session") }
        guard let session else { return all }
        let matches = all.filter { $0.session.id == session || $0.session.name == session }
        switch matches.count {
        case 0: throw CLIError("no live Session of the Topic \(topic.label) matches \(session)")
        case 1: return matches
        default:
            throw CLIError("ambiguous Session selector \(session); use its tmux ID")
        }
    }

    /// Runs the command in every target, prints each Session's output, and throws when a run did not exit with 0.
    func run(_ targets: [Target], topic: TopicDetail, output: TopicInvocation.Output) throws {
        let runs = runAll(targets)
        switch output {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            print(String(decoding: try encoder.encode(Report(topic: topic, runs: runs)), as: UTF8.self))
        case .text:
            // A header before each Session's output, in the Topic's Session order, as `tail` heads each file.
            for run in runs {
                let header = Data("==> \(run.target.session.name.oneLineField) <==\n".utf8)
                FileHandle.standardOutput.write(header + Self.endingInNewline(run.stdout))
                if !run.stderr.isEmpty { FileHandle.standardError.write(header + Self.endingInNewline(run.stderr)) }
            }
        }
        let failures = runs.compactMap { run -> String? in
            switch run.outcome {
            case .exited(0): return nil
            case .exited(let status): return "\(run.target.session.name) exited with status \(status)"
            case .timedOut: return "\(run.target.session.name) did not exit in \(Self.seconds(timeout))"
            case .notStarted(let reason): return "\(run.target.session.name) did not start: \(reason)"
            }
        }
        if !failures.isEmpty { throw CLIError("topic exec: " + failures.joined(separator: "; ")) }
    }

    func runAll(_ targets: [Target]) -> [Run] {
        Self.atOnce(targets) { target in
            let child = Self.child(arguments, in: target.directory, timeout: timeout)
            return Run(target: target, outcome: child.outcome, stdout: child.stdout, stderr: child.stderr)
        }
    }

    /// `body` for every target, each on its own thread at the same time. The results are in target order.
    static func atOnce<T>(_ targets: [Target], _ body: @escaping (Target) -> T) -> [T] {
        var results = [T?](repeating: nil, count: targets.count)
        let lock = NSLock()
        let group = DispatchGroup()
        for (index, target) in targets.enumerated() {
            DispatchQueue.global(qos: .userInitiated).async(group: group) {
                let result = body(target)
                lock.lock()
                results[index] = result
                lock.unlock()
            }
        }
        group.wait()
        return results.compactMap { $0 }
    }

    /// Starts `arguments` in `directory` with no input, and waits until it exits or `timeout` stops it. An
    /// `environment` replaces the inherited one.
    static func child(_ arguments: [String], in directory: String, timeout: TimeInterval,
                      environment: [String: String]? = nil) -> (outcome: Outcome, stdout: Data, stderr: Data) {
        guard let executable = executable(arguments[0], directory: directory) else {
            return (.notStarted("\(arguments[0]): command not found"), Data(), Data())
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(arguments.dropFirst())
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do { try process.run() } catch {
            return (.notStarted(error.localizedDescription), Data(), Data())
        }

        // Each chunk is kept as it arrives, so output that came before a pipe is given up is not lost.
        var collected = [Data(), Data()]
        let lock = NSLock()
        let ended = DispatchSemaphore(value: 0)
        for (index, pipe) in [stdout, stderr].enumerated() {
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    ended.signal()
                    return
                }
                lock.lock()
                collected[index].append(data)
                lock.unlock()
            }
        }
        var expired = false
        let deadline = DispatchWorkItem {
            lock.lock()
            // A command that exits as the deadline comes did not time out.
            guard process.isRunning else { return lock.unlock() }
            expired = true
            lock.unlock()
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        process.waitUntilExit()
        deadline.cancel()
        // A process that the command started in the background can keep a pipe open after the command exits. Its
        // later output is not waited for.
        let grace = DispatchTime.now() + 1
        for _ in 0..<2 where ended.wait(timeout: grace) == .timedOut { break }
        for pipe in [stdout, stderr] {
            pipe.fileHandleForReading.readabilityHandler = nil
            try? pipe.fileHandleForReading.close()
        }

        lock.lock()
        defer { lock.unlock() }
        // A shell reports a command that a signal ended as 128 plus the signal number.
        let status = process.terminationReason == .uncaughtSignal ? 128 + process.terminationStatus : process.terminationStatus
        return (expired ? .timedOut : .exited(status), collected[0], collected[1])
    }

    /// The program to start, found as a shell finds it: a name with a slash is a path from the Session's folder, any
    /// other name is looked up in PATH.
    private static func executable(_ name: String, directory: String) -> String? {
        if name.contains("/") {
            return name.hasPrefix("/") ? name : (directory as NSString).appendingPathComponent(name)
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        // An empty PATH entry is the current folder, which for a run is the Session's folder.
        return path.split(separator: ":", omittingEmptySubsequences: false)
            .map { ($0.isEmpty ? directory : String($0)) + "/" + name }
            .first { candidate in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory) && !isDirectory.boolValue
                    && FileManager.default.isExecutableFile(atPath: candidate)
            }
    }

    private static func endingInNewline(_ data: Data) -> Data {
        data.isEmpty || data.last == UInt8(ascii: "\n") ? data : data + Data("\n".utf8)
    }

    private static func seconds(_ interval: TimeInterval) -> String {
        interval == interval.rounded() ? "\(Int(interval)) s" : "\(interval) s"
    }

    /// The `--json` line: the Topic, then each Session's run in the Topic's Session order.
    private struct Report: Encodable {
        struct Topic: Encodable {
            var id: String
            var label: String
        }

        struct Session: Encodable {
            var id: String
            var name: String
            var directory: String
            /// The exit status, or null when the command timed out or did not start.
            var status: Int32?
            var timedOut: Bool
            /// Why the command did not start, else null.
            var error: String?
            var stdout: String
            var stderr: String

            func encode(to encoder: Encoder) throws {
                var values = encoder.container(keyedBy: CodingKeys.self)
                try values.encode(id, forKey: .id)
                try values.encode(name, forKey: .name)
                try values.encode(directory, forKey: .directory)
                try values.encode(status, forKey: .status)
                try values.encode(timedOut, forKey: .timedOut)
                try values.encode(error, forKey: .error)
                try values.encode(stdout, forKey: .stdout)
                try values.encode(stderr, forKey: .stderr)
            }

            private enum CodingKeys: String, CodingKey {
                case id, name, directory, status, error, stdout, stderr
                case timedOut = "timed_out"
            }
        }

        var topic: Topic
        var sessions: [Session]

        init(topic: TopicDetail, runs: [Run]) {
            self.topic = Topic(id: topic.id, label: topic.label)
            sessions = runs.map { run in
                var status: Int32?
                var error: String?
                if case .exited(let code) = run.outcome { status = code }
                if case .notStarted(let reason) = run.outcome { error = reason }
                return Session(id: run.target.session.id, name: run.target.session.name, directory: run.target.directory,
                               status: status, timedOut: run.outcome == .timedOut, error: error,
                               stdout: String(decoding: run.stdout, as: UTF8.self),
                               stderr: String(decoding: run.stderr, as: UTF8.self))
            }
        }
    }
}
