import Foundation
import MuxifyCore

struct CLICommandResult {
    let status: Int32
    let output: String
    /// Only a quiet command collects its stderr. Otherwise stderr goes to the terminal.
    var errorOutput = ""
}

protocol CLICommandRunning {
    func run(_ command: String, arguments: [String], quiet: Bool) throws -> CLICommandResult
}

struct CLIProcessRunner: CLICommandRunning {
    func run(_ command: String, arguments: [String], quiet: Bool) throws -> CLICommandResult {
        let process = Process()
        // Resolve tools from PATH, just as the original shell CLI did.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        if quiet { process.standardError = errors }
        let exit = try process.start()
        // Read stderr beside stdout, so a full stderr pipe cannot stop the process.
        let errorData = CollectedData()
        let errorsRead = DispatchGroup()
        if quiet {
            DispatchQueue.global().async(group: errorsRead) { errorData.set(errors.fileHandleForReading.readDataToEndOfFile()) }
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        exit.wait()
        errorsRead.wait()
        return CLICommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self),
                                errorOutput: String(decoding: errorData.value, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private final class CollectedData: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        var value: Data { lock.lock(); defer { lock.unlock() }; return data }
        func set(_ value: Data) { lock.lock(); data = value; lock.unlock() }
    }
}

/// These verbs keep the caller's tmux socket. tmux's stderr goes into the error, as in the app's runner. The module serializes access to the runner.
final class CLITmuxTransport: TmuxRunning, @unchecked Sendable {
    let runner: any CLICommandRunning
    /// The status of the last tmux call when it failed. A failed verb exits with it, as tmux did.
    private(set) var failedStatus: Int32?

    init(runner: any CLICommandRunning) { self.runner = runner }

    func run(_ arguments: [String]) throws -> String {
        let result: CLICommandResult
        do { result = try runner.run("tmux", arguments: arguments, quiet: true) }
        catch { throw LaunchFailure(description: error.localizedDescription) }
        failedStatus = result.status == 0 ? nil : result.status
        guard result.status == 0 else { throw TmuxError.failed(status: result.status, stderr: result.errorOutput) }
        return result.output
    }

    func snapshot() throws -> TmuxSnapshot { try Tmux.readSnapshot(using: run) }

    private struct LaunchFailure: Error, CustomStringConvertible {
        let description: String
    }
}
