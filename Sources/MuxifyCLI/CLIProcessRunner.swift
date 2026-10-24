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
        // Resolve tools from PATH, just as the original shell CLI did.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + arguments
        let output = Pipe()
        process.standardOutput = output
        if quiet { process.standardError = FileHandle.nullDevice }
        let exit = try process.start()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        exit.wait()
        return CLICommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}
