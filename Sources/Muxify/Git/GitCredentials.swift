import Foundation

/// A question that a network command, such as `git fetch`, asks in its terminal: one of lazygit's credential
/// prompts, or ssh's about a host it doesn't know. The Git View asks it in a Git View prompt.
struct GitCredentialPrompt: Equatable {
    enum Kind: Equatable {
        case password, username, passphrase, pin, token, hostKey
    }

    let kind: Kind
    /// The question as the command asked it, such as "Password for 'https://example.com':".
    let question: String
    /// What the command said just before, such as the host and fingerprint ssh doesn't know.
    var context: [String] = []

    /// A password, passphrase, PIN or token, whose answer the prompt hides.
    var isSecret: Bool { kind != .username && kind != .hostKey }

    /// lazygit's prompts (`getCheckForCredentialRequestFunc` in `cmd_obj_runner.go`), then ssh's unknown-host question.
    private static let patterns: [(NSRegularExpression, Kind)] = [
        (#"Password:"#, .password),
        (#".+'s password:"#, .password),
        (#"Password\s*for\s*'.+':"#, .password),
        (#"Username\s*for\s*'.+':"#, .username),
        (#"Enter\s*passphrase\s*for\s*key\s*'.+':"#, .passphrase),
        (#"Enter\s*PIN\s*for\s*.+\s*key\s*.+:"#, .pin),
        (#"Enter\s*PIN\s*for\s*'.+':"#, .pin),
        (#".*2FA Token.*"#, .token),
        (#"Are you sure you want to continue connecting \(yes/no(/\[fingerprint\])?\)\?"#, .hostKey),
    ].map { (try! NSRegularExpression(pattern: $0), $1) }

    /// The prompt that `line`, the text since the last line break, asks, if it is one.
    static func match(_ line: String) -> GitCredentialPrompt? {
        firstMatch(line).map { GitCredentialPrompt(kind: $0.kind, question: line.trimmingCharacters(in: .whitespaces)) }
    }

    /// What `line` says after the prompt it asks, such as git's next message when the answer wasn't echoed, or nil
    /// when it asks none.
    static func remainder(_ line: String) -> String? {
        firstMatch(line).map { String(line[$0.end...]) }
    }

    private static func firstMatch(_ line: String) -> (kind: Kind, end: String.Index)? {
        let range = NSRange(line.startIndex..., in: line)
        for (pattern, kind) in patterns {
            if let match = pattern.firstMatch(in: line, range: range), let found = Range(match.range, in: line) {
                return (kind, found.upperBound)
            }
        }
        return nil
    }
}

/// What a command under a pty wrote, as the Git View shows it.
enum GitTerminalOutput {
    private static let escape = try! NSRegularExpression(pattern: "\u{1B}(\\[[0-9;?]*[ -/]*[@-~]|[@-Z\\\\-_])")
    private static let progress = try! NSRegularExpression(pattern: #"^(remote: )?[A-Za-z][A-Za-z ]*: +\d+% \(\d+/\d+\)"#)

    /// git's message without its progress: the lines that `\r` overwrote, those of a counter that finished at once,
    /// terminal escapes, and the prompts that were answered.
    static func message(_ output: String) -> String {
        let plain = escape.stringByReplacingMatches(in: output, range: NSRange(output.startIndex..., in: output), withTemplate: "")
        return plain.components(separatedBy: "\n")
            .map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
            .map { GitCredentialPrompt.remainder($0)?.trimmingCharacters(in: .whitespaces) ?? $0 }
            .filter { line in
                !line.contains("\r")
                    && progress.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) == nil
                    && !line.trimmingCharacters(in: .whitespaces).isEmpty
            }
            .joined(separator: "\n")
    }
}
