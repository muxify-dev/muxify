import Foundation

enum BrowserAvailability: String {
    case local, remote, no

    var exitCode: Int32 { self == .no ? 1 : 0 }

    /// Muxify shows every Window of a tmux server that one of its Clients is attached to, and it opens
    /// `@muxify_open` on any of them. So the answer is about the server: a `@muxify_client_*` marker whose
    /// Client is attached now. A marker left by a crash names a Client that is gone, so it never matches.
    static func check(pane: String?, using runner: any CLICommandRunning) throws -> Self {
        guard let pane, !pane.isEmpty else { return .no }
        // tmux writes its own reason to stderr, so a sandbox or a missing tmux is not a silent "no".
        func tmux(_ arguments: [String]) throws -> String {
            let result = try runner.run("tmux", arguments: arguments, quiet: false)
            guard result.status == 0 else {
                throw CLIError("cannot read tmux: tmux \(arguments[0]) exited with status \(result.status)", exitCode: 2)
            }
            return result.output
        }
        let attached = Set(try tmux(["list-clients", "-F", "#{client_control_mode} #{client_pid} #{client_tty}"])
            .split(separator: "\n").filter { $0.hasPrefix("0 ") }.map { String($0.dropFirst(2)) })
        let options = try tmux(["show-options", "-s"]).split(separator: "\n")
            .compactMap { $0.split(separator: " ").first }.filter { $0.hasPrefix("@muxify_client_") }
        let kinds = try options.compactMap { option -> Self? in
            let fields = try tmux(["show-options", "-sqv", String(option)])
                .trimmingCharacters(in: .newlines).components(separatedBy: "␟")
            guard fields.count >= 3, attached.contains("\(fields[0]) \(fields[1])") else { return nil }
            return Self(rawValue: fields[fields.count - 1]).flatMap { $0 == .no ? nil : $0 }
        }
        return kinds.contains(.local) ? .local : kinds.contains(.remote) ? .remote : .no
    }
}
