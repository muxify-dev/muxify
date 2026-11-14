import Foundation

/// The client half of the Host Server protocol, on a pair of file handles: an SSH channel's in the Mac app, a pair
/// of pipes in a test. It skips what a login shell prints before the magic line, waits for the server's `hello`,
/// picks the highest protocol both speak and answers with its own `hello`. Calls made before that wait, and are
/// never written before it. When the channel ends, every call that waits fails at once with `unavailable`.
public final class ProtocolClient: @unchecked Sendable {
    /// Why the handshake failed.
    public enum Failure: Error, Equatable, Sendable, LocalizedError {
        /// The magic line did not come in the first 64 KiB, or the channel ended before it: how many bytes the shell
        /// printed, and the first line of them. A `muxify` with no `server` verb prints nothing and exits 2.
        case noMagicLine(printed: Int, firstLine: String)
        /// The server's `hello` did not come within the timeout.
        case noHello(timeout: TimeInterval)
        /// The two sides share no protocol. Carries the server's build line for the reason the window gives.
        case noSharedProtocol(serverBuild: String, serverProtocols: ClosedRange<Int>?)
        /// The channel ended during the handshake.
        case ended(String)

        public var errorDescription: String? {
            switch self {
            case .noMagicLine(let printed, let firstLine):
                "the Host Server did not start: the shell printed \(printed) bytes before it" + (firstLine.isEmpty ? "" : ", first \"\(firstLine)\"")
            case .noHello: "the Host Server did not answer"
            case .noSharedProtocol(let build, _): "the Host's muxify is too old (\(build))"
            case .ended(let reason): reason
            }
        }
    }

    /// What the handshake agreed on.
    public struct Session: Equatable, Sendable {
        public let protocolVersion: Int
        /// The server's `build` line. Never compared.
        public let peerBuild: String
        /// What the server declared. Send only what it lists.
        public let peerCapabilities: Set<String>

        public func supports(_ capability: String) -> Bool { peerCapabilities.contains(capability) }
    }

    private let channel: ProtocolChannel
    private let hello: ProtocolHello
    private let protocols: ClosedRange<Int>
    private let lock = NSLock()
    private var outcome: Result<Session, Failure>?
    private var waiters: [CheckedContinuation<Session, Error>] = []

    /// Starts reading at once. `onRequest` serves the requests that the server starts; without it they are answered
    /// `unsupported`.
    public init(input: FileHandle, output: FileHandle, build: String, capabilities: [String] = HostProtocol.capabilities,
                protocols: ClosedRange<Int> = HostProtocol.supported, helloTimeout: TimeInterval = HostProtocol.helloTimeout,
                queueCapacity: Int = 256, onRequest: ((ProtocolIncomingRequest) -> Void)? = nil) {
        channel = ProtocolChannel(input: input, output: output, awaitingMagic: true, queueCapacity: queueCapacity)
        hello = ProtocolHello(protocolVersion: protocols.upperBound, build: build, capabilities: capabilities)
        self.protocols = protocols
        channel.onRequest = onRequest
        channel.onHello = { [weak self] hello in self?.received(hello) }
        channel.onClose { [weak self] reason in
            let failure: Failure = switch reason {
            case .noMagicLine(let printed, let firstLine): .noMagicLine(printed: printed, firstLine: firstLine)
            default: .ended(reason.message)
            }
            self?.settle(.failure(failure))
        }
        channel.start()
        DispatchQueue.global().asyncAfter(deadline: .now() + helloTimeout) { [weak self] in
            guard let self, self.isWaiting else { return }
            self.settle(.failure(.noHello(timeout: helloTimeout)))
            self.channel.close(.handshake("the Host Server did not answer within \(Int(helloTimeout)) s"))
        }
    }

    deinit { channel.close() }

    /// Waits for the handshake.
    @discardableResult
    public func connect() async throws -> Session {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            guard let outcome else {
                waiters.append(continuation)
                lock.unlock()
                return
            }
            lock.unlock()
            continuation.resume(with: outcome.mapError { $0 as Error })
        }
    }

    /// What the handshake agreed on, once it has.
    public var session: Session? {
        lock.lock()
        defer { lock.unlock() }
        return try? outcome?.get()
    }

    /// Sends a request and waits for its `end`, whose `ok` decodes as `Response`. Cancelling the task sends `cancel`.
    public func call<Request: Encodable, Response: Decodable>(_ request: Request, as response: Response.Type) async throws -> Response {
        let cancel = CancelBox(channel: channel)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let id = channel.sendRequest(request, onItem: { _ in }, onEnd: { result in
                    continuation.resume(with: result.flatMap { $0.outcome(Response.self) }.mapError { $0 as Error })
                })
                cancel.sent(id)
            }
        } onCancel: {
            cancel.cancel()
        }
    }

    /// Sends a request that answers `{}`.
    public func call<Request: Encodable>(_ request: Request) async throws {
        _ = try await call(request, as: ProtocolEmpty.self)
    }

    public func ping() async throws { try await call(HostRequest.ping) }

    /// A request whose `item`s are base64 chunks: the stream yields their bytes and finishes at `end`. Stopping the
    /// stream early sends `cancel`.
    public func stream<Request: Encodable>(_ request: Request) -> AsyncThrowingStream<Data, Error> {
        items(request) { try $0.payload(ProtocolChunk.self).data }
    }

    /// A subscription: the stream yields its events in order, the first being the full state. It ends with the
    /// request's `end`, or with `unavailable` when the channel ends. Stopping the stream sends `cancel`.
    public func subscribe<Request: Encodable, Event: Decodable>(_ request: Request, as event: Event.Type) -> AsyncThrowingStream<Event, Error> {
        items(request) { try $0.payload(Event.self) }
    }

    private func items<Request: Encodable, Item>(_ request: Request, _ decode: @escaping (ProtocolFrame) throws -> Item) -> AsyncThrowingStream<Item, Error> {
        let channel = channel
        return AsyncThrowingStream { continuation in
            let cancel = CancelBox(channel: channel)
            let id = channel.sendRequest(request, onItem: { frame in
                do { continuation.yield(try decode(frame)) }
                catch { continuation.finish(throwing: ProtocolError(.invalid, "an item does not decode: \(error)")) }
            }, onEnd: { result in
                switch result.flatMap({ $0.outcome(ProtocolEmpty.self) }) {
                case .success: continuation.finish()
                case .failure(let error): continuation.finish(throwing: error)
                }
            })
            cancel.sent(id)
            continuation.onTermination = { termination in
                if case .cancelled = termination { cancel.cancel() }
            }
        }
    }

    /// Ends the channel. Every call that waits fails with `unavailable`.
    public func close() { channel.close() }

    /// Called once, when the channel ends.
    public func onClose(_ handler: @escaping (ProtocolChannel.CloseReason) -> Void) { channel.onClose(handler) }

    // MARK: - The handshake

    private var isWaiting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return outcome == nil
    }

    private func received(_ server: ProtocolHello) {
        guard let offered = server.offered, let picked = Self.pick(offered, protocols) else {
            settle(.failure(.noSharedProtocol(serverBuild: server.build, serverProtocols: server.offered)))
            channel.close(.handshake("no shared protocol with \(server.build)"))
            return
        }
        var answer = hello
        answer.protocolVersion = picked
        do { try channel.sendHello(answer) }
        catch { channel.close(.handshake("the hello does not encode")); return }
        channel.acceptPeer()
        settle(.success(Session(protocolVersion: picked, peerBuild: server.build, peerCapabilities: Set(server.capabilities))))
    }

    /// The highest protocol in both ranges.
    static func pick(_ server: ClosedRange<Int>, _ client: ClosedRange<Int>) -> Int? {
        server.overlaps(client) ? min(server.upperBound, client.upperBound) : nil
    }

    private func settle(_ result: Result<Session, Failure>) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        outcome = result
        let waiting = waiters
        waiters = []
        lock.unlock()
        for waiter in waiting { waiter.resume(with: result.mapError { $0 as Error }) }
    }
}

/// The id of a request, so a cancel that comes before the id is known still reaches it.
private final class CancelBox: @unchecked Sendable {
    private let channel: ProtocolChannel
    private let lock = NSLock()
    private var id: Int?
    private var cancelled = false

    init(channel: ProtocolChannel) { self.channel = channel }

    func sent(_ id: Int) {
        lock.lock()
        self.id = id
        let cancelled = cancelled
        lock.unlock()
        if cancelled { channel.cancel(id) }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let id = id
        lock.unlock()
        if let id { channel.cancel(id) }
    }
}
