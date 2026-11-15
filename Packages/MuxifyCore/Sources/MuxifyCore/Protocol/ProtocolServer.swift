import Foundation

/// The server half of the Host Server protocol, on a pair of file handles: `muxify server`'s stdin and stdout, or a
/// test's pipes. It writes the magic line and its `hello`, waits for the client's, and serves requests with
/// `handler`. It exits on EOF, on `stop`, or when no frame comes for `silence` seconds (ADR 0085; the end rules of
/// the server's lifecycle). Its log lines are plain text, never parsed.
public final class ProtocolServer: @unchecked Sendable {
    public enum Exit: Equatable, Sendable {
        /// stdin ended: the master exited, the window closed, or the Mac closed the channel.
        case inputEnded
        /// The client asked it to.
        case shutdown
        /// No frame came for the silence timeout: the Mac slept or left the network.
        case silence
        /// The channel broke, or the client broke the protocol.
        case failed(String)

        public var exitCode: Int32 {
            if case .failed = self { return 1 }
            return 0
        }
    }

    private let channel: ProtocolChannel
    private let hello: ProtocolHello
    private let protocols: ClosedRange<Int>
    private let silence: TimeInterval
    private let log: (String) -> Void
    private let lock = NSLock()
    private var exit: Exit?
    /// `exit` once the exit handlers have run: `wait` returns only then.
    private var exited: Exit?
    /// The exit that `stop` asked for, which comes once what was queued is written.
    private var stopping: Exit?
    private var peer: ProtocolHello?
    private var waiters: [CheckedContinuation<Exit, Never>] = []
    private var exitHandlers: [() -> Void] = []
    private var timer: DispatchSourceTimer?

    public init(input: FileHandle, output: FileHandle, build: String, capabilities: [String] = HostProtocol.capabilities,
                protocols: ClosedRange<Int> = HostProtocol.supported, silence: TimeInterval = HostProtocol.serverSilence,
                queueCapacity: Int = 256, log: @escaping (String) -> Void = { _ in },
                handler: @escaping (ProtocolIncomingRequest, ProtocolServer) -> Void) {
        channel = ProtocolChannel(input: input, output: output, awaitingMagic: false, queueCapacity: queueCapacity)
        hello = ProtocolHello(protocolVersion: protocols.upperBound, minProtocol: protocols.lowerBound, build: build, capabilities: capabilities)
        self.protocols = protocols
        self.silence = silence
        self.log = log
        channel.onHello = { [weak self] client in self?.received(client) }
        channel.onRequest = { [weak self] request in
            guard let self else { return request.fail(.channelEnded) }
            handler(request, self)
        }
        channel.onClose { [weak self] reason in
            guard let self else { return }
            self.lock.lock()
            let stopping = self.stopping
            self.lock.unlock()
            self.finish(stopping ?? (reason == .inputEnded ? .inputEnded : .failed(reason.message)))
        }
    }

    /// Writes the magic line and the `hello`, and starts reading.
    public func start() {
        log("muxify server: \(hello.build) speaks protocols \(protocols.lowerBound) to \(protocols.upperBound)")
        channel.sendRaw(ProtocolLine.magic)
        // A hello of an integer, strings and a list always encodes.
        try? channel.sendHello(hello)
        channel.start()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "muxify.protocol.silence"))
        let interval = min(1, silence / 4)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self, self.channel.secondsSinceLastFrame >= self.silence else { return }
            self.finish(.silence)
            self.channel.close()
        }
        lock.lock()
        self.timer = timer
        lock.unlock()
        timer.resume()
    }

    /// The client's `hello`, once it came.
    public var client: ProtocolHello? {
        lock.lock()
        defer { lock.unlock() }
        return peer
    }

    /// Writes what is queued, such as the `end` of `shutdown`, then exits: `wait` returns once it is written, so a
    /// process that exits then has sent it.
    public func stop(_ exit: Exit) {
        lock.lock()
        if stopping == nil { stopping = exit }
        lock.unlock()
        channel.closeWhenFlushed()
    }

    /// Runs `handler` once when the server exits, before `wait` returns, so a process that exits then has run it.
    public func onExit(_ handler: @escaping () -> Void) {
        lock.lock()
        guard exit != nil else {
            exitHandlers.append(handler)
            lock.unlock()
            return
        }
        lock.unlock()
        handler()
    }

    // MARK: - Requests to the client

    /// Sends the client a request (ADR 0091) and waits for its `end`, whose `ok` decodes as `Response`. It is
    /// written once both `hello`s are in; once the channel has ended it fails at once with `unavailable`.
    public func call<Request: Encodable, Response: Decodable>(_ request: Request, as response: Response.Type) async throws -> Response {
        try await channel.call(request, as: Response.self)
    }

    /// `call` for a request whose `item`s are `ProtocolChunk`s: the `end`'s value, and the chunks' bytes in order.
    public func callStreaming<Request: Encodable, Response: Decodable>(_ request: Request,
                                                                       as response: Response.Type) async throws -> (Response, Data) {
        let bytes = ChunkBuffer()
        let value = try await channel.call(request, as: Response.self) { frame in
            if let chunk = try? frame.payload(ProtocolChunk.self) { bytes.append(chunk.data) }
        }
        return (value, bytes.data)
    }

    /// Waits until the server exits.
    public func wait() async -> Exit {
        await withCheckedContinuation { continuation in
            lock.lock()
            guard let exit = exited else {
                waiters.append(continuation)
                lock.unlock()
                return
            }
            lock.unlock()
            continuation.resume(returning: exit)
        }
    }

    private func received(_ client: ProtocolHello) {
        guard protocols.contains(client.protocolVersion) else {
            log("muxify server: \(client.build) picked protocol \(client.protocolVersion), which this server does not speak")
            finish(.failed("the client picked protocol \(client.protocolVersion)"))
            channel.close(.handshake("the client picked protocol \(client.protocolVersion)"))
            return
        }
        lock.lock()
        peer = client
        lock.unlock()
        log("muxify server: \(client.build) speaks protocol \(client.protocolVersion)")
        channel.acceptPeer()
    }

    private func finish(_ exit: Exit) {
        lock.lock()
        guard self.exit == nil else { lock.unlock(); return }
        self.exit = exit
        let timer = timer
        let handlers = exitHandlers
        exitHandlers = []
        lock.unlock()
        timer?.cancel()
        log("muxify server: exits, \(Self.describe(exit))")
        for handler in handlers { handler() }
        // A `wait` that comes while the handlers run waits for them too.
        lock.lock()
        exited = exit
        let waiting = waiters
        waiters = []
        lock.unlock()
        for waiter in waiting { waiter.resume(returning: exit) }
    }

    private static func describe(_ exit: Exit) -> String {
        switch exit {
        case .inputEnded: "stdin ended"
        case .shutdown: "asked to shut down"
        case .silence: "no frame came in time"
        case .failed(let reason): reason
        }
    }
}

/// The bytes of a streamed answer, gathered on the reader's queue.
private final class ChunkBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()

    func append(_ chunk: Data) {
        lock.lock()
        bytes.append(chunk)
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return bytes
    }
}
