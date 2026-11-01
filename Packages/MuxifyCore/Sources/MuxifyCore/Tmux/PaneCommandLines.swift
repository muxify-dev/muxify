import Foundation

/// The full command line of the program that runs in each Topic Pane, such as `npm run dev` where tmux says only
/// `node`. Topic memory records it, so Reopen can type it again.
public struct PaneCommandLines: Equatable, Sendable {
    private struct Entry: Equatable, Sendable {
        /// The Pane's `pane_current_command` when `line` was read. Another program in the Pane makes `line` stale.
        let command: String
        /// Empty when `ps` gave no line, so a Pane that has none does not run `ps` again on each read.
        let line: String
    }

    /// Runs on the Environment's machine. In each Pane's foreground process group, the leader's pid is the
    /// terminal's foreground group id, so one row of each terminal has `pid == tpgid`.
    public static let script = "ps -ww -A -o pid=,tpgid=,tty=,args="

    private var entries: [String: Entry] = [:]

    public init() {}

    /// The command line of the program in `pane`, when it runs one that is not a shell or an Agent.
    public subscript(pane: TmuxPane) -> String? {
        entries[pane.id].flatMap { $0.command == pane.command && !$0.line.isEmpty ? $0.line : nil }
    }

    /// The command lines for `snapshot`. They are kept while each program Pane of a Topic runs the program of the
    /// last read, so `ps` runs only when such a Pane starts another program. `ps` gives the output of `script`.
    public func updating(for snapshot: TmuxSnapshot, ps: () -> String?) -> PaneCommandLines {
        let topicWindows = Set(snapshot.windows.filter { $0.topicID != nil }.map(\.id))
        let panes = snapshot.panes.filter {
            topicWindows.contains($0.windowID) && !$0.tty.isEmpty && !Tmux.shellNames.contains($0.command) && !Agent.runs(in: $0)
        }
        var kept = PaneCommandLines()
        for pane in panes {
            guard let entry = entries[pane.id], entry.command == pane.command else { return Self.read(panes, ps()) }
            kept.entries[pane.id] = entry
        }
        return kept
    }

    private static func read(_ panes: [TmuxPane], _ output: String?) -> PaneCommandLines {
        var leaders: [String: String] = [:]
        for row in (output ?? "").split(separator: "\n") {
            let fields = row.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard fields.count == 4, fields[0] == fields[1] else { continue }
            leaders[String(fields[2])] = fields[3].trimmingCharacters(in: .whitespaces)
        }
        var lines = PaneCommandLines()
        for pane in panes {
            let tty = pane.tty.hasPrefix("/dev/") ? String(pane.tty.dropFirst(5)) : pane.tty
            lines.entries[pane.id] = Entry(command: pane.command, line: leaders[tty] ?? "")
        }
        return lines
    }
}
