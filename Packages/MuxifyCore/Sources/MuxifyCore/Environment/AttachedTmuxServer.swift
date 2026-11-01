import Foundation

/// Binds a copied watch to the server reached by the Terminal's SSH connection.
public struct AttachedTmuxServer: TmuxRunning {
    private let server: TmuxServer
    private let serverID: String
    private let clientPID: Int
    private let clientTTY: String
    private let home: String
    private let host: String

    public init(server: TmuxServer, marker: String) throws {
        let fields = try server.run(["show-option", "-sqv", marker])
            .trimmingCharacters(in: .newlines).components(separatedBy: Tmux.separator)
        let snapshot = try server.snapshot()
        guard fields.count == 5, fields[4] == "remote", let pid = Int(fields[0]),
              let serverID = snapshot.serverID,
              snapshot.clients.contains(where: { $0.pid == pid && $0.tty == fields[1] && !$0.isControl }) else {
            throw TmuxError.notReady
        }
        self.server = server
        self.serverID = serverID
        clientPID = pid
        clientTTY = fields[1]
        home = fields[2]
        host = fields[3]
    }

    public func snapshot() throws -> TmuxSnapshot {
        var snapshot = try server.snapshot()
        guard !snapshot.serverRunning || snapshot.serverID == serverID else { throw TmuxError.notReady }
        snapshot.ownClientTTY = snapshot.clients.first { $0.pid == clientPID && $0.tty == clientTTY && !$0.isControl }?.tty
        snapshot.homeDirectory = home
        for index in snapshot.windows.indices {
            snapshot.windows[index].homeDirectory = home
            snapshot.windows[index].hostName = host
            snapshot.windows[index].isRemote = true
        }
        return snapshot
    }

    @discardableResult public func run(_ arguments: [String]) throws -> String {
        // An admitted edit can remove its own Client. Finish that edit, but never target a replacement server.
        _ = try snapshot()
        return try server.run(arguments)
    }
}
