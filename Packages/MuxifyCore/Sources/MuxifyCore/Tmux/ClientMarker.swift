import Foundation

/// An App Window's Client marker: the server option `@muxify_client_<nonce>` that its attach writes, whose value is
/// `<pid>␟<tty>␟<home>␟<host name>␟<local|remote>`. It tells the App Window's own Client from every other Client of
/// the server. A Host Server learns the nonce from its Mac's `hello`.
public enum ClientMarker {
    public static func option(nonce: String) -> String { "@muxify_client_\(nonce)" }

    /// The Client that the marker's value names, when it is attached among `clients`.
    public static func client(_ value: String, in clients: [TmuxClient]) -> ViewCommandExecutor.Client? {
        guard let named = named(by: value),
              clients.contains(where: { $0.pid == named.pid && $0.tty == named.tty && !$0.isControl }) else { return nil }
        return named
    }

    /// The pid and tty that the marker's value names, attached or not.
    public static func named(by value: String) -> ViewCommandExecutor.Client? {
        let fields = value.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: Tmux.separator)
        guard fields.count >= 2, let pid = Int(fields[0]), pid > 0, !fields[1].isEmpty else { return nil }
        return ViewCommandExecutor.Client(tty: fields[1], pid: pid)
    }
}
