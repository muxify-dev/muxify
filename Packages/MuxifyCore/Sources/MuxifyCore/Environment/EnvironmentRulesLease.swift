import Foundation
import Darwin
import CryptoKit

public enum EnvironmentRulesScope: Sendable {
    case local(socketPath: String)
    case remoteFallback(host: String)

    func directory(server: any TmuxRunning) throws -> URL {
        let identity: String
        switch self {
        case .local(let path):
            identity = "local:" + Folder.local(path).real
        case .remoteFallback(let host):
            let socket = try server.run(["display-message", "-p", "#{socket_path}"]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard socket.hasPrefix("/") else { throw TmuxError.notReady }
            identity = "remote:" + host + ":" + socket
        }
        let name = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return URL(fileURLWithPath: "/tmp").appendingPathComponent("muxify-rules-\(getuid())/\(name)")
    }
}

public struct EnvironmentViewing: Codable, Equatable, Sendable {
    public var client: String?
    public var window: String?
    public var visible: Bool

    public init(client: String? = nil, window: String? = nil, visible: Bool = false) {
        self.client = client
        self.window = window
        self.visible = visible
    }
}

/// Each reader holds its own lock for its lifetime. A crash releases the lock, so old facts cannot hide an update.
final class EnvironmentRulesLease {
    private struct Reader: Codable {
        var serverID: String?
        var clientPID: Int?
        var viewing: EnvironmentViewing
    }
    let directory: URL
    private let readerID = UUID().uuidString
    private var readerDescriptor: Int32 = -1
    private var ownerDescriptor: Int32 = -1
    private(set) var ownsRules = false
    /// What this lease wrote last to each file. A renewal about once a second writes a file only when its content
    /// changes, because a virus scanner holds each new file open.
    private var writtenSettings: Data?
    private var writtenReader: Data?
    private var payload: URL { directory.appendingPathComponent(readerID + ".json") }
    private var readerLock: URL { directory.appendingPathComponent(readerID + ".lock") }
    private var settingsFile: URL { directory.appendingPathComponent("settings.json") }

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        readerDescriptor = try Self.openLock(readerLock)
        guard flock(readerDescriptor, LOCK_EX | LOCK_NB) == 0 else { throw POSIXError(.EIO) }
        ownerDescriptor = try Self.openLock(directory.appendingPathComponent("owner.lock"))
    }

    deinit {
        if readerDescriptor >= 0 { close(readerDescriptor) }
        if ownerDescriptor >= 0 { close(ownerDescriptor) }
        try? FileManager.default.removeItem(at: payload)
        try? FileManager.default.removeItem(at: readerLock)
    }

    func acquire(settings: EnvironmentRuleSettings) throws -> Bool {
        if !ownsRules {
            if flock(ownerDescriptor, LOCK_EX | LOCK_NB) == 0 {
                ownsRules = true
                // An owner before this one may have left other settings in the file.
                writtenSettings = nil
            } else if errno != EWOULDBLOCK { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        if ownsRules {
            let data = try JSONEncoder().encode(settings)
            if data != writtenSettings {
                try data.write(to: settingsFile, options: .atomic)
                writtenSettings = data
            }
        }
        return ownsRules
    }

    func effectiveSettings() -> EnvironmentRuleSettings? {
        (try? Data(contentsOf: settingsFile)).flatMap { try? JSONDecoder().decode(EnvironmentRuleSettings.self, from: $0) }
    }

    func update(_ viewing: EnvironmentViewing, serverID: String?, clientPID: Int?) throws {
        let data = try JSONEncoder().encode(Reader(serverID: serverID, clientPID: clientPID, viewing: viewing))
        guard data != writtenReader else { return }
        try data.write(to: payload, options: .atomic)
        writtenReader = data
    }

    func viewed(in snapshot: TmuxSnapshot) throws -> Set<String> {
        var viewed: Set<String> = []
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for file in files where file.pathExtension == "json" && file.lastPathComponent != "settings.json" {
            let lock = file.deletingPathExtension().appendingPathExtension("lock")
            let descriptor = open(lock.path, O_RDONLY | O_CLOEXEC)
            guard descriptor >= 0 else { continue }
            defer { close(descriptor) }
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                try? FileManager.default.removeItem(at: file)
                try? FileManager.default.removeItem(at: lock)
                continue
            }
            guard errno == EWOULDBLOCK,
                  let data = try? Data(contentsOf: file), let reader = try? JSONDecoder().decode(Reader.self, from: data),
                  reader.serverID == snapshot.serverID, reader.viewing.visible,
                  let tty = reader.viewing.client, let id = reader.viewing.window,
                  snapshot.clients.contains(where: { !$0.isControl && $0.tty == tty && $0.pid == reader.clientPID && $0.windowID == id }),
                  let window = snapshot.windows.first(where: { $0.id == id }) else { continue }
            viewed.formUnion(AgentReadScope(window: window).paneIDs(in: snapshot.panes))
        }
        return viewed
    }

    private static func openLock(_ file: URL) throws -> Int32 {
        let descriptor = open(file.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return descriptor
    }
}
