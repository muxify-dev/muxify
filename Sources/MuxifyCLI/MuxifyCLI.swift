import Darwin
import Foundation

/// The whole `muxify` command. It lives in the library, not in the executable, so that
/// Xcode can build the tests against it: Xcode cannot give a test bundle the module of
/// an executable package target.
public enum CommandLineTool {
    public static func run() async -> Never {
        let arguments = Array(CommandLine.arguments.dropFirst())
        do {
            let command = try CLICommand(arguments: arguments)
            exit(try await command.execute())
        } catch {
            let status = (error as? CLIError)?.exitCode ?? 1
            let prefix = error.localizedDescription == CLICommand.usage ? "" : "muxify: "
            FileHandle.standardError.write(Data("\(prefix)\(error.localizedDescription)\n".utf8))
            exit(status)
        }
    }
}
