import Foundation
import Darwin
import MuxifyCore

struct TopicTitleSuggester {
    enum Source {
        case topic(TopicRecord, TmuxSnapshot, [SessionPath])
        case newTopic(TmuxPane?, SessionPath?)
    }

    typealias Conversation = AgentConversation

    enum CommandOutcome: Equatable {
        case completed(status: Int32, stdout: String, stderr: String)
        case timedOut(stderr: String)
        case launchFailed(String)
    }

    struct CommandFailure: Equatable {
        let command: String
        let detail: String
    }

    enum Failure: Error, Equatable, CustomStringConvertible {
        case invalidConversationID(AgentKind, String)
        case noConversationText
        case promptMetadataTooLong
        case commandsFailed([CommandFailure])

        var description: String {
            switch self {
            case .invalidConversationID(let kind, _):
                return "The \(kind.displayName) conversation id is not safe to read."
            case .noConversationText:
                return "No user messages were found in the Topic's Agent conversations."
            case .promptMetadataTooLong:
                return "The Session names and prompt instructions exceed 8,000 characters."
            case .commandsFailed(let failures):
                return failures.map { "\($0.command): \($0.detail)" }.joined(separator: "\n")
            }
        }
    }

    typealias TranscriptLoader = (Conversation) throws -> [String]
    typealias ModelCall = (_ command: String, _ prompt: String, _ timeout: TimeInterval) -> CommandOutcome

    private static let instruction = "Give a short title for this work, at most 5 words. Return plain text on one line."
    private let commands: [String]
    private let commandTimeout: TimeInterval
    private let transcriptRoots: TranscriptRoots
    private let transcriptLoader: TranscriptLoader?
    private let modelCall: ModelCall

    init(commands: [String], commandTimeout: TimeInterval = 30,
         homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         transcriptLoader: TranscriptLoader? = nil, modelCall: ModelCall? = nil) {
        self.commands = commands
        self.commandTimeout = commandTimeout
        transcriptRoots = TranscriptRoots(environment: environment, home: homeDirectory)
        self.transcriptLoader = transcriptLoader
        self.modelCall = modelCall ?? Self.runCommand
    }

    func suggest(for source: Source) throws -> String {
        let request = requestContext(for: source)
        var excerpts: [ConversationExcerpt] = []
        for conversation in request.conversations {
            guard conversation.hasSafeID else { throw Failure.invalidConversationID(conversation.kind, conversation.id) }
            let messages = try transcriptLoader?(conversation) ?? loadTranscript(conversation)
            let excerpt = ConversationExcerpt(conversation: conversation, messages: messages)
            if !excerpt.messages.isEmpty { excerpts.append(excerpt) }
        }
        guard !excerpts.isEmpty else { throw Failure.noConversationText }
        let prompt = try makePrompt(baseNames: request.baseNames, excerpts: &excerpts)
        var failures: [CommandFailure] = []
        for command in commands {
            switch modelCall(command, prompt, commandTimeout) {
            case .completed(let status, let stdout, let stderr):
                if status != 0 {
                    let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    failures.append(CommandFailure(command: command,
                        detail: "exited with \(status)" + (detail.isEmpty ? "" : ": \(detail)")))
                } else if let title = Self.normalizedTitle(stdout) {
                    return title
                } else {
                    let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    failures.append(CommandFailure(command: command,
                        detail: "returned no title" + (detail.isEmpty ? "" : ": \(detail)")))
                }
            case .timedOut(let stderr):
                let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                failures.append(CommandFailure(command: command,
                    detail: "timed out" + (detail.isEmpty ? "" : ": \(detail)")))
            case .launchFailed(let error):
                failures.append(CommandFailure(command: command, detail: "could not start: \(error)"))
            }
        }
        throw Failure.commandsFailed(failures)
    }

    private struct RequestContext {
        let baseNames: [String]
        let conversations: [Conversation]
    }

    private struct ConversationExcerpt {
        let conversation: Conversation
        var messages: [String]

        init(conversation: Conversation, messages: [String]) {
            self.conversation = conversation
            var first: [(Int, String)] = []
            var last: [(Int, String)] = []
            for (index, raw) in messages.enumerated() {
                let text = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
                guard !text.isEmpty else { continue }
                if first.count < 3 { first.append((index, text)) }
                last.append((index, text))
                if last.count > 3 { last.removeFirst() }
            }
            var retained = first
            for item in last where !retained.contains(where: { $0.0 == item.0 }) { retained.append(item) }
            self.messages = retained.sorted { $0.0 < $1.0 }.map(\.1)
        }

        var characterCount: Int { messages.reduce(0) { $0 + $1.count } }
    }

    private func requestContext(for source: Source) -> RequestContext {
        switch source {
        case .newTopic(let pane, let sessionPath):
            let conversations = pane.flatMap(AgentConversation.init(in:)).map { [$0] } ?? []
            return RequestContext(baseNames: sessionPath.map { [$0.name] } ?? [], conversations: conversations)
        case .topic(let topic, let snapshot, _):
            let windows = snapshot.windows.filter { $0.topicID == topic.id }
            let conversations = topic.agentConversations(in: snapshot)

            var names: [String] = []
            func append(_ name: String?) {
                guard let name, !names.contains(name) else { return }
                names.append(name)
            }
            for window in windows { append(topic.baseName(of: window)) }
            for session in topic.sessions {
                append(session["base_name"]?.string)
            }
            return RequestContext(baseNames: names, conversations: conversations)
        }
    }

    private func makePrompt(baseNames: [String], excerpts: inout [ConversationExcerpt]) throws -> String {
        func render() -> String {
            var lines = [Self.instruction, "", "Sessions:"]
            lines += baseNames.isEmpty ? ["- (none)"] : baseNames.map { "- \($0)" }
            lines += ["", "Conversation excerpts:"]
            for (index, excerpt) in excerpts.enumerated() {
                lines.append("[\(excerpt.conversation.kind.displayName) \(index + 1)]")
                lines += excerpt.messages.map { "- \($0)" }
            }
            return lines.joined(separator: "\n")
        }

        let metadata = render()
        if excerpts.allSatisfy({ $0.messages.isEmpty }), metadata.count > 8_000 {
            throw Failure.promptMetadataTooLong
        }
        var prompt = metadata
        while prompt.count > 8_000 {
            guard let index = excerpts.indices.filter({ !excerpts[$0].messages.isEmpty }).max(by: {
                if excerpts[$0].characterCount == excerpts[$1].characterCount { return $0 > $1 }
                return excerpts[$0].characterCount < excerpts[$1].characterCount
            }) else { throw Failure.promptMetadataTooLong }
            excerpts[index].messages.removeLast()
            prompt = render()
        }
        return prompt
    }

    static func normalizedTitle(_ output: String) -> String? {
        guard var title = output.split(whereSeparator: \Character.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }).first(where: { !$0.isEmpty }) else { return nil }
        if title.count >= 2, let first = title.first, let last = title.last,
           first == last, first == "\"" || first == "'" {
            title.removeFirst()
            title.removeLast()
            title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !title.isEmpty else { return nil }
        return String(title.prefix(60))
    }

    private func loadTranscript(_ conversation: Conversation) -> [String] {
        let entries: [Entry]
        if conversation.kind == .opencode {
            guard case .completed(0, let output, _) = Self.runCommand("opencode export " + Tmux.shellQuote(conversation.id), "", 30)
            else { return [] }
            entries = TranscriptReader.entries(in: Data(output.utf8), kind: .opencode)
        } else {
            entries = transcriptRoots.transcript(of: conversation)
                .flatMap { try? TranscriptReader.entries(inFile: $0, kind: conversation.kind) } ?? []
        }
        return entries.filter { $0.role == .user }.map(\.text)
    }

    private static func runCommand(_ command: String, _ input: String, _ timeout: TimeInterval) -> CommandOutcome {
        func failed(_ operation: String, _ code: Int32 = errno) -> CommandOutcome {
            .launchFailed("\(operation): \(String(cString: strerror(code)))")
        }
        func closeAll(_ descriptors: [Int32]) {
            for descriptor in descriptors where descriptor >= 0 { Darwin.close(descriptor) }
        }

        var inputPipe = [Int32](repeating: -1, count: 2)
        var outputPipe = [Int32](repeating: -1, count: 2)
        var errorPipe = [Int32](repeating: -1, count: 2)
        guard pipe(&inputPipe) == 0 else { return failed("stdin pipe") }
        guard pipe(&outputPipe) == 0 else {
            closeAll(inputPipe)
            return failed("stdout pipe")
        }
        guard pipe(&errorPipe) == 0 else {
            closeAll(inputPipe + outputPipe)
            return failed("stderr pipe")
        }
        let descriptors = inputPipe + outputPipe + errorPipe

        var actions: posix_spawn_file_actions_t? = nil
        let actionsResult = posix_spawn_file_actions_init(&actions)
        guard actionsResult == 0 else {
            closeAll(descriptors)
            return failed("spawn file actions", actionsResult)
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        let actionResults = [
            posix_spawn_file_actions_adddup2(&actions, inputPipe[0], STDIN_FILENO),
            posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDOUT_FILENO),
            posix_spawn_file_actions_adddup2(&actions, errorPipe[1], STDERR_FILENO),
        ] + descriptors.map { posix_spawn_file_actions_addclose(&actions, $0) }
        if let result = actionResults.first(where: { $0 != 0 }) {
            closeAll(descriptors)
            return failed("spawn file action", result)
        }

        var attributes: posix_spawnattr_t? = nil
        let attributesResult = posix_spawnattr_init(&attributes)
        guard attributesResult == 0 else {
            closeAll(descriptors)
            return failed("spawn attributes", attributesResult)
        }
        defer { posix_spawnattr_destroy(&attributes) }
        let groupResults = [
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)),
            posix_spawnattr_setpgroup(&attributes, 0),
        ]
        if let result = groupResults.first(where: { $0 != 0 }) {
            closeAll(descriptors)
            return failed("spawn process group", result)
        }

        let arguments = ["zsh", "-l", "-c", command]
        var argumentPointers = arguments.map { strdup($0) } + [nil]
        defer { for case let pointer? in argumentPointers { free(pointer) } }
        var pid: pid_t = 0
        let spawnResult = argumentPointers.withUnsafeMutableBufferPointer { buffer in
            posix_spawn(&pid, "/bin/zsh", &actions, &attributes, buffer.baseAddress!, environ)
        }
        guard spawnResult == 0 else {
            closeAll(descriptors)
            return failed("could not start", spawnResult)
        }

        closeAll([inputPipe[0], outputPipe[1], errorPipe[1]])
        let inputHandle = FileHandle(fileDescriptor: inputPipe[1], closeOnDealloc: true)
        let outputHandle = FileHandle(fileDescriptor: outputPipe[0], closeOnDealloc: true)
        let errorHandle = FileHandle(fileDescriptor: errorPipe[0], closeOnDealloc: true)
        let readGroup = DispatchGroup()
        var outputData = Data(), errorData = Data()
        readGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            outputData = outputHandle.readDataToEndOfFile()
            readGroup.leave()
        }
        readGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errorData = errorHandle.readDataToEndOfFile()
            readGroup.leave()
        }
        do {
            try inputHandle.write(contentsOf: Data(input.utf8))
            try inputHandle.close()
        } catch {
            kill(-pid, SIGKILL)
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            readGroup.wait()
            return .launchFailed(String(describing: error))
        }

        var status: Int32 = 0
        func wait(noHang: Bool) -> pid_t {
            var result: pid_t
            repeat { result = waitpid(pid, &status, noHang ? WNOHANG : 0) } while result == -1 && errno == EINTR
            return result
        }
        let timeoutNanoseconds = UInt64(max(0, timeout) * 1_000_000_000)
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        var waited = wait(noHang: true)
        while waited == 0, DispatchTime.now().uptimeNanoseconds < deadline {
            usleep(10_000)
            waited = wait(noHang: true)
        }
        var timedOut = waited == 0
        if waited > 0, readGroup.wait(timeout: DispatchTime(uptimeNanoseconds: deadline)) == .timedOut {
            timedOut = true
        }
        if timedOut {
            kill(-pid, SIGTERM)
            let grace = DispatchTime.now() + .seconds(1)
            while waited == 0, DispatchTime.now().uptimeNanoseconds < grace.uptimeNanoseconds {
                usleep(10_000)
                waited = wait(noHang: true)
            }
            if readGroup.wait(timeout: grace) == .timedOut { kill(-pid, SIGKILL) }
            if waited == 0 {
                kill(-pid, SIGKILL)
                waited = wait(noHang: false)
            }
        } else if waited == -1 {
            kill(-pid, SIGKILL)
            _ = wait(noHang: false)
        }
        readGroup.wait()
        let stderr = String(decoding: errorData, as: UTF8.self)
        if timedOut { return .timedOut(stderr: stderr) }
        if waited == -1 { return failed("wait for command") }
        let signal = status & 0x7f
        let exitStatus = signal == 0 ? (status >> 8) & 0xff : 128 + signal
        return .completed(status: exitStatus, stdout: String(decoding: outputData, as: UTF8.self), stderr: stderr)
    }
}
