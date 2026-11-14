import Foundation

// The messages of the Host Server protocol: the Mac app and `muxify server` speak it over one SSH channel, and a test
// over a pair of pipes. Each frame is one line of JSON (ADR 0083). The two sides agree on a protocol number and on
// capabilities, never on a build (ADR 0084). The JSON form of every message is a contract pinned by tests, and a
// fixtures folder per release keeps the older forms decodable.

/// The constants of the wire and of the version contract.
public enum HostProtocol {
    /// The server's first line. The client skips what a login shell prints before it.
    public static let magicLine = "MUXIFY-PROTOCOL"
    /// The longest frame, without its newline. A longer line is a protocol error that closes the channel.
    public static let maxFrameBytes = 16 * 1024 * 1024
    /// The most shell output that the client skips before the magic line.
    public static let maxPreambleBytes = 64 * 1024
    /// The largest chunk of a streamed response, before base64.
    public static let maxChunkBytes = 64 * 1024
    /// The protocols that this build speaks. Both ends started at 1; a bump needs an ADR.
    public static let supported: ClosedRange<Int> = 1...1
    /// What this build adds to its protocol. Protocol 1's surface has none.
    public static let capabilities: [String] = []
    /// How long the client waits for the server's `hello`.
    public static let helloTimeout: TimeInterval = 10
    /// How long the server waits for any frame before it exits. Longer than the Mac's own master timeout
    /// (`ServerAliveInterval=15` × `ServerAliveCountMax=2`), so a server never exits while the Mac holds its master.
    public static let serverSilence: TimeInterval = 45
}

/// The `kind` of a frame.
public enum ProtocolKind: String, Codable, Sendable {
    case hello, request, item, end, cancel
}

/// What each side says first. The server's carries the protocols it speaks; the client's names the one it picked.
public struct ProtocolHello: Codable, Equatable, Sendable {
    /// The server's highest protocol, or the protocol that the client picked.
    public var protocolVersion: Int
    /// The server's lowest protocol. The client's `hello` has none.
    public var minProtocol: Int?
    /// The `muxify --version` line, `muxify <short-sha> <commit-unix-time>`. Never compared: it goes to Diagnostics
    /// and to the reason a window gives when it falls back to Sessions only.
    public var build: String
    /// What this side adds to its protocol. The other side sends only what this side declared.
    public var capabilities: [String]

    public init(protocolVersion: Int, minProtocol: Int? = nil, build: String, capabilities: [String] = []) {
        self.protocolVersion = protocolVersion
        self.minProtocol = minProtocol
        self.build = build
        self.capabilities = capabilities
    }

    /// The protocols that a server's `hello` offers.
    public var offered: ClosedRange<Int>? {
        let lowest = minProtocol ?? protocolVersion
        return lowest <= protocolVersion ? lowest...protocolVersion : nil
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case minProtocol = "min_protocol"
        case build, capabilities
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try values.decode(Int.self, forKey: .protocolVersion)
        minProtocol = try values.decodeIfPresent(Int.self, forKey: .minProtocol)
        build = try values.decodeIfPresent(String.self, forKey: .build) ?? ""
        capabilities = try values.decodeIfPresent([String].self, forKey: .capabilities) ?? []
    }
}

/// Why a request ended without `ok`.
public enum ProtocolErrorCode: String, Codable, Sendable, CaseIterable {
    /// The receiver does not know the request.
    case unsupported
    /// The receiver knows the request, but its values do not decode or make no sense.
    case invalid
    /// The request was cancelled before it changed anything.
    case cancelled
    /// The channel ended, or a subscriber fell behind.
    case unavailable
    /// A domain failure, with MuxifyCore's message.
    case failed

    /// A code that a newer peer added reads as `failed`, so its message still reaches the user.
    public init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .failed
    }
}

/// The `error` of an `end`.
public struct ProtocolError: Error, Codable, Equatable, Sendable, LocalizedError {
    public var code: ProtocolErrorCode
    public var message: String

    public init(_ code: ProtocolErrorCode, _ message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { message }

    /// Every waiting request fails with this when its channel ends. Nothing is replayed.
    public static let channelEnded = ProtocolError(.unavailable, "the connection to the Host Server ended")
}

/// The `ok` of a request that answers nothing: `{}`.
public struct ProtocolEmpty: Codable, Equatable, Sendable {
    public init() {}
}

/// One `item` of a streamed response: at most `HostProtocol.maxChunkBytes`, as base64.
public struct ProtocolChunk: Codable, Equatable, Sendable {
    public var data: Data

    public init(data: Data) { self.data = data }
}

/// A request that the Mac sends to the Host Server. Later releases add cases, each behind a capability. A case
/// that this build does not know is answered `unsupported`.
public enum HostRequest: Codable, Equatable, Sendable {
    /// Answers `ok`. The Mac sends one every 15 s when it has sent nothing else.
    case ping
    /// Answers `ok`, then the server exits.
    case shutdown

    private enum CodingKeys: String, CodingKey, CaseIterable { case ping, shutdown }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: ProtocolKey.self)
        guard let known = CodingKeys.allCases.first(where: { values.contains(ProtocolKey($0.rawValue)) }) else {
            let names = values.allKeys.map(\.stringValue).sorted().joined(separator: ", ")
            throw ProtocolError(.unsupported, "this muxify does not know the request \(names.isEmpty ? "{}" : names)")
        }
        switch known {
        case .ping: self = .ping
        case .shutdown: self = .shutdown
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ping: try values.encode(ProtocolEmpty(), forKey: .ping)
        case .shutdown: try values.encode(ProtocolEmpty(), forKey: .shutdown)
        }
    }
}

/// A key named at run time, such as the payload key of a frame, which is its `kind`.
struct ProtocolKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(_ name: String) { stringValue = name }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
