import Foundation
import MuxifyCore

/// One verb of the command line. `muxify --help` is generated from `CLIVerbs.all`, so a verb has no help text apart
/// from its own entry, and the options that its synopsis shows are the options that it reads.
struct CLIVerb {
    /// What `--` does on this verb's command line.
    enum AfterDashes {
        /// `--` is a usage error.
        case refused
        /// The words after `--` are operands, also when they look like options.
        case operands
        /// The words after `--` are a command to run, in `ParsedArguments.command`.
        case command
    }

    let path: CLIVerbPath
    /// What follows the words in the synopsis. A line break starts a line that is aligned under the first.
    let synopsis: String
    let options: [CLIOption]
    /// The target options that the reader takes, before `build` checks which of them the command accepts.
    var targets: [RequestInvocation.TargetOption] = []
    /// Snooze and Unsnooze act on each Topic of a repeated `--topic`.
    var repeatsTopic = false
    var afterDashes = AfterDashes.refused
    /// Old forms of this verb. Each fails with a message that names the new form, before `build` runs.
    var removed: [RemovedForm] = []
    /// The paragraph under the verb's name in `muxify --help`. An option line starts with two spaces.
    let help: String
    let build: (ParsedArguments) throws -> CLICommand

    var words: [String] { path.words }
}

/// An old form of a verb that now fails, with a message that names the new form (ADR 0039: no aliases).
struct RemovedForm {
    /// Options that only the old form has. The reader takes them, so the message can name them.
    var options: [CLIOption] = []
    let matches: (ParsedArguments) -> Bool
    let message: (ParsedArguments) -> String
}

/// An option that a verb reads. A value option takes the next word, also one that starts with `-`, such as
/// `--range -20..-1`. A builder checks the value.
struct CLIOption {
    let name: String
    let takesValue: Bool
    var aliases: [String] = []

    static func flag(_ name: String) -> CLIOption { CLIOption(name: name, takesValue: false) }
    static func value(_ name: String, aliases: [String] = []) -> CLIOption { CLIOption(name: name, takesValue: true, aliases: aliases) }
}

/// The words after a verb, read once against the verb's options. A builder asks for what it needs. A word that
/// the verb does not read, a value option given twice, or a value option at the end is a usage error.
struct ParsedArguments {
    let environment: [String: String]
    let now: Date
    /// The words that are not options, in order.
    private(set) var operands: [String] = []
    /// The words after `--` on a verb that runs a command. Nil without `--`.
    private(set) var command: [String]?
    private(set) var targets: RequestInvocation.TargetOptions
    private var given: [(name: String, value: String?)] = []

    init(_ arguments: ArraySlice<String>, for verb: CLIVerb, environment: [String: String], now: Date) throws {
        self.environment = environment
        self.now = now
        targets = RequestInvocation.TargetOptions(accepting: verb.targets, repeatsTopic: verb.repeatsTopic)
        var args = arguments
        while let word = args.popFirst() {
            if word == "--" {
                switch verb.afterDashes {
                case .refused: throw CLIError.usage
                case .operands: operands += args
                case .command: command = Array(args)
                }
                return
            }
            if try targets.take(word, from: &args) { continue }
            guard word.hasPrefix("-"), word.count > 1 else {
                operands.append(word)
                continue
            }
            let (spelling, attached) = word.hasPrefix("--") && word.contains("=")
                ? (String(word.prefix { $0 != "=" }), String(word.drop { $0 != "=" }.dropFirst()))
                : (word, nil)
            guard let option = (verb.options + verb.removed.flatMap(\.options)).first(where: { $0.name == spelling || $0.aliases.contains(spelling) }) else { throw CLIError.usage }
            if option.takesValue {
                guard let value = attached ?? args.popFirst() else { throw CLIError.usage }
                given.append((option.name, value))
            } else {
                guard attached == nil else { throw CLIError.usage }
                given.append((option.name, nil))
            }
        }
    }

    func flag(_ name: String) -> Bool { given.contains { $0.name == name } }

    /// The value of an option that the command line may give once.
    func value(_ name: String) throws -> String? {
        let values = self.values(name)
        guard values.count <= 1 else { throw CLIError.usage }
        return values.first
    }

    func values(_ name: String) -> [String] { given.filter { $0.name == name }.compactMap(\.value) }

    /// How many of these options the command line gives, each time counted.
    func count(of names: [String]) -> Int { given.filter { names.contains($0.name) }.count }

    var output: RequestInvocation.Output { flag("--json") ? .json : .text }
    var paths: MuxifyPaths { MuxifyPaths(environment: environment, home: environment["HOME"] ?? NSHomeDirectory()) }
}

extension CLIError {
    static var usage: CLIError { CLIError(CLIVerbs.usage, exitCode: 2) }
}
