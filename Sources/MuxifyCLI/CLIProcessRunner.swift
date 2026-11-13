import Foundation
import MuxifyCore

struct CLICommandResult {
    let status: Int32
    let output: String
}

protocol CLICommandRunning {
    func run(_ command: String, arguments: [String], quiet: Bool) throws -> CLICommandResult
}

struct CLIProcessRunner: CLICommandRunning {
    func run(_ command: String, arguments: [String], quiet: Bool) throws -> CLICommandResult {
        let process = Process()
        // A tmux of another release than the server's can fail on it, so tmux runs the Server binary.
        if command == "tmux", let tmux = TmuxServer.ofClient().binary {
            process.executableURL = URL(fileURLWithPath: tmux)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [command] + arguments
        }
        let output = Pipe()
        process.standardOutput = output
        if quiet { process.standardError = FileHandle.nullDevice }
        let exit = try process.start()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return CLICommandResult(status: exit.wait().status, output: String(decoding: data, as: UTF8.self))
    }
}
