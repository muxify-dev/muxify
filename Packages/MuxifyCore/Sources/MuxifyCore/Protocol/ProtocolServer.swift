import Foundation

/// The server half of the Host Server protocol, on a pair of file handles: `muxify server`'s stdin and stdout, or a
/// test's pipes. It writes the magic line and its `hello`, waits for the client's, and serves requests with
/// `handler`. It exits on EOF, on `stop`, or when no frame comes for `silence` seconds (ADR 0083; the end rules of
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
    private var peer: ProtocolHello?
    private var waiters: [CheckedContinuation<Exit, Never>] = []
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
            self?.finish(reason == .inputEnded ? .inputEnded : .failed(reason.message))
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

    /// Writes what is queued, such as the `end` of `shutdown`, then exits.
    public func stop(_ exit: Exit) {
        finish(exit)
        channel.closeWhenFlushed()
    }

    /// Waits until the server exits.
    public func wait() async -> Exit {
        await withCheckedContinuation { continuation in
            lock.lock()
            guard let exit else {
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
        let waiting = waiters
        waiters = []
        let timer = timer
        lock.unlock()
        timer?.cancel()
        log("muxify server: exits, \(Self.describe(exit))")
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

/// `muxify server`: the Host Server's requests. Protocol 1 serves `ping` and `shutdown`; later tasks add the domain
/// commands and subscriptions.
public enum HostServer {
    /// A server on these handles that serves `HostRequest`.
    public static func make(input: FileHandle, output: FileHandle, build: String, silence: TimeInterval = HostProtocol.serverSilence,
                            log: @escaping (String) -> Void = { _ in }) -> ProtocolServer {
        ProtocolServer(input: input, output: output, build: build, silence: silence, log: log, handler: serve)
    }

    /// Runs a server on stdin and stdout until it exits, logging to stderr.
    public static func run(build: String, silence: TimeInterval = HostProtocol.serverSilence) async -> ProtocolServer.Exit {
        let server = make(input: .standardInput, output: .standardOutput, build: build, silence: silence) { line in
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }
        server.start()
        return await server.wait()
    }

    static func serve(_ request: ProtocolIncomingRequest, server: ProtocolServer) {
        do {
            switch try request.body(HostRequest.self) {
            case .ping:
                request.finish()
            case .shutdown:
                request.finish()
                server.stop(.shutdown)
            }
        } catch let error as ProtocolError {
            request.fail(error)
        } catch {
            request.fail(ProtocolError(.invalid, "\(error)"))
        }
    }
}
