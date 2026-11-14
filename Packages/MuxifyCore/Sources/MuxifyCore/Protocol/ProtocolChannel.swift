#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

/// One side of a Host Server channel, on a pair of file handles: an SSH channel's, `muxify server`'s stdin and
/// stdout, or a test's pipes. Both sides send requests and number their own from 1. Every request ends exactly once,
/// and when the channel ends every request that waits fails at once with `unavailable`; nothing is replayed (ADR 0083).
///
/// The reader runs on a read source of its own, the writer on a thread of its own behind one bounded queue, and each
/// request from the peer runs its handler on a concurrent queue. `ProtocolClient` and `HostServer` own a channel and
/// add their side's handshake.
public final class ProtocolChannel: @unchecked Sendable {
    /// Why a channel ended.
    public enum CloseReason: Equatable, Sendable {
        /// The peer closed its end: EOF on the input.
        case inputEnded
        /// This side closed it.
        case closed
        /// The client did not find the magic line: how many bytes the shell printed, and their first line.
        case noMagicLine(printed: Int, firstLine: String)
        /// A line longer than `HostProtocol.maxFrameBytes`.
        case frameTooLong
        /// The peer broke the protocol: a line that is not a frame, a request before `hello`, a bad `hello`.
        case violation(String)
        /// A write to the peer failed.
        case writeFailed(String)
        /// The handshake failed; its owner says why.
        case handshake(String)

        public var message: String {
            switch self {
            case .inputEnded: "the Host Server's channel ended"
            case .closed: "the channel to the Host Server was closed"
            case .noMagicLine(let printed, let firstLine):
                "no \(HostProtocol.magicLine) line: the shell printed \(printed) bytes" + (firstLine.isEmpty ? "" : ", first \"\(firstLine)\"")
            case .frameTooLong: "a frame was longer than \(HostProtocol.maxFrameBytes) bytes"
            case .violation(let what): "the peer broke the protocol: \(what)"
            case .writeFailed(let reason): "could not write to the channel: \(reason)"
            case .handshake(let reason): reason
            }
        }
    }

    /// A request that this side sent and that has not ended.
    private struct Outgoing {
        let onItem: (ProtocolFrame) -> Void
        let onEnd: (Result<ProtocolFrame, ProtocolError>) -> Void
    }

    private let input: FileHandle
    private let output: FileHandle
    /// Guards every field below, and the state of each `ProtocolIncomingRequest`.
    let state = NSCondition()
    private var queue: ProtocolWriterQueue
    private var closeReason: CloseReason?
    /// Set by `closeWhenFlushed`: the writer writes what is queued, then closes with this reason.
    private var drainReason: CloseReason?
    private var nextID = 1
    private var sentHello = false
    private var peerAccepted = false
    private var receivedHello = false
    /// Requests made before both `hello`s, never written until then.
    private var held: [(id: Int, line: Data)] = []
    private var outgoing: [Int: Outgoing] = [:]
    private var incoming: [Int: ProtocolIncomingRequest] = [:]
    private var lastFrame = DispatchTime.now()
    private var closeHandlers: [(CloseReason) -> Void] = []
    private var source: DispatchSourceRead?
    /// Touched only on `readQueue`.
    private var reader: ProtocolLineReader
    private let readQueue = DispatchQueue(label: "muxify.protocol.reader")
    private let handlerQueue = DispatchQueue(label: "muxify.protocol.handlers", attributes: .concurrent)

    /// The peer's `hello`. Its owner checks it, then calls `acceptPeer`, or closes the channel.
    var onHello: ((ProtocolHello) -> Void)?
    /// A request from the peer. Without a handler, every request is answered `unsupported`.
    var onRequest: ((ProtocolIncomingRequest) -> Void)?

    init(input: FileHandle, output: FileHandle, awaitingMagic: Bool, queueCapacity: Int = 256) {
        self.input = input
        self.output = output
        queue = ProtocolWriterQueue(capacity: queueCapacity)
        reader = ProtocolLineReader(awaitingMagic: awaitingMagic)
        ignoreBrokenPipes(on: output.fileDescriptor)
    }

    /// Starts reading and writing. Set the handlers first.
    func start() {
        let fd = input.fileDescriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: readQueue)
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR || errno == EAGAIN { return }
            guard count > 0 else {
                self.close(self.reader.endFailure.map(Self.reason) ?? .inputEnded)
                return
            }
            let lines: [Data]
            do { lines = try self.reader.feed(chunk[..<count]) }
            catch let failure as ProtocolLineReader.Failure { self.close(Self.reason(failure)); return }
            catch { self.close(.violation("\(error)")); return }
            for line in lines where !self.isClosed { self.receive(line) }
        }
        let input = input
        source.setCancelHandler { try? input.close() }
        state.lock()
        self.source = source
        state.unlock()
        source.resume()
        let writer = Thread { [self] in writeLoop() }
        writer.name = "muxify.protocol.writer"
        writer.start()
    }

    // MARK: - The handshake

    /// Writes a line that is not a frame: the server's magic line.
    func sendRaw(_ line: Data) { enqueueControl(line) }

    /// Writes this side's `hello`. Requests wait until both sides have it.
    func sendHello(_ hello: ProtocolHello) throws {
        let line = try ProtocolLine.hello(hello)
        state.lock()
        defer { state.unlock() }
        guard closeReason == nil else { return }
        queue.pushControl(line)
        sentHello = true
        openGateIfReady()
        state.broadcast()
    }

    /// The owner checked the peer's `hello`: requests may now go both ways.
    func acceptPeer() {
        state.lock()
        defer { state.unlock() }
        peerAccepted = true
        openGateIfReady()
        state.broadcast()
    }

    private var gateOpen: Bool { sentHello && peerAccepted }

    private func openGateIfReady() {
        guard gateOpen else { return }
        for request in held { queue.pushControl(request.line) }
        held = []
    }

    // MARK: - Requests this side sends

    /// Sends a request. `onItem` gets each `item` in order and `onEnd` its one `end`, both on the reader's queue, or
    /// `onEnd` at once when the channel has ended. Returns the request's id.
    @discardableResult
    func sendRequest<T: Encodable>(_ body: T, onItem: @escaping (ProtocolFrame) -> Void,
                                   onEnd: @escaping (Result<ProtocolFrame, ProtocolError>) -> Void) -> Int {
        state.lock()
        if let closeReason {
            state.unlock()
            onEnd(.failure(Self.error(closeReason)))
            return 0
        }
        let id = nextID
        nextID += 1
        let line: Data
        do { line = try ProtocolLine.request(id: id, body) }
        catch {
            state.unlock()
            onEnd(.failure(ProtocolError(.invalid, "the request does not encode: \(error)")))
            return id
        }
        outgoing[id] = Outgoing(onItem: onItem, onEnd: onEnd)
        if gateOpen { queue.pushControl(line) } else { held.append((id, line)) }
        state.broadcast()
        state.unlock()
        return id
    }

    /// Cancels a request this side sent. One not yet written ends `cancelled` here and is never written.
    func cancel(_ id: Int) {
        state.lock()
        if let index = held.firstIndex(where: { $0.id == id }) {
            held.remove(at: index)
            let request = outgoing.removeValue(forKey: id)
            state.unlock()
            request?.onEnd(.failure(ProtocolError(.cancelled, "cancelled before it was sent")))
            return
        }
        if closeReason == nil, outgoing[id] != nil {
            queue.pushControl(ProtocolLine.cancel(id: id))
            state.broadcast()
        }
        state.unlock()
    }

    // MARK: - Ending

    var isClosed: Bool {
        state.lock()
        defer { state.unlock() }
        return closeReason != nil
    }

    /// How long ago the peer's last frame came.
    var secondsSinceLastFrame: TimeInterval {
        state.lock()
        defer { state.unlock() }
        return Double(DispatchTime.now().uptimeNanoseconds - lastFrame.uptimeNanoseconds) / 1_000_000_000
    }

    /// Called once, when the channel ends. At once when it has ended already.
    func onClose(_ handler: @escaping (CloseReason) -> Void) {
        state.lock()
        if let closeReason {
            state.unlock()
            handler(closeReason)
            return
        }
        closeHandlers.append(handler)
        state.unlock()
    }

    /// Writes what is queued, then ends the channel.
    func closeWhenFlushed(_ reason: CloseReason = .closed) {
        state.lock()
        if closeReason == nil, drainReason == nil { drainReason = reason }
        state.broadcast()
        state.unlock()
    }

    /// Ends the channel at once. Every request this side sent fails with `unavailable`, and every handler of a
    /// request from the peer is told to stop.
    func close(_ reason: CloseReason = .closed) {
        state.lock()
        guard closeReason == nil else { state.unlock(); return }
        closeReason = reason
        let waiting = Array(outgoing.values)
        outgoing = [:]
        held = []
        var stops: [() -> Void] = []
        for request in incoming.values { stops += request.stopLocked() }
        incoming = [:]
        let handlers = closeHandlers
        closeHandlers = []
        let source = source
        state.broadcast()
        state.unlock()
        source?.cancel()
        let error = Self.error(reason)
        for request in waiting { request.onEnd(.failure(error)) }
        for stop in stops { stop() }
        for handler in handlers { handler(reason) }
    }

    private static func error(_ reason: CloseReason) -> ProtocolError {
        reason == .inputEnded ? .channelEnded : ProtocolError(.unavailable, reason.message)
    }

    private static func reason(_ failure: ProtocolLineReader.Failure) -> CloseReason {
        switch failure {
        case .noMagicLine(let printed, let firstLine): .noMagicLine(printed: printed, firstLine: firstLine)
        case .frameTooLong: .frameTooLong
        }
    }

    // MARK: - Reading

    private func receive(_ line: Data) {
        let frame: ProtocolFrame
        do {
            guard let decoded = try ProtocolFrame.decode(line) else { return }
            frame = decoded
        } catch {
            close(.violation("a line that is not a frame"))
            return
        }
        state.lock()
        lastFrame = DispatchTime.now()
        switch frame.kind {
        case .hello:
            guard !receivedHello else { state.unlock(); close(.violation("a second hello")); return }
            receivedHello = true
            state.unlock()
            guard let hello = try? frame.payload(ProtocolHello.self) else { close(.violation("a hello that does not decode")); return }
            onHello?(hello)
        case .request:
            guard peerAccepted else { state.unlock(); close(.violation("a request before hello")); return }
            guard incoming[frame.id] == nil else { state.unlock(); close(.violation("request \(frame.id) is still open")); return }
            let request = ProtocolIncomingRequest(channel: self, frame: frame)
            incoming[frame.id] = request
            let handler = onRequest
            state.unlock()
            handlerQueue.async {
                if let handler { handler(request) }
                else { request.fail(ProtocolError(.unsupported, "this side serves no requests")) }
            }
        case .item:
            let request = outgoing[frame.id]
            state.unlock()
            request?.onItem(frame)
        case .end:
            let request = outgoing.removeValue(forKey: frame.id)
            state.unlock()
            request?.onEnd(.success(frame))
        case .cancel:
            let stops = incoming[frame.id]?.cancelLocked() ?? []
            state.unlock()
            for stop in stops { handlerQueue.async(execute: stop) }
        }
    }

    // MARK: - Writing

    private func writeLoop() {
        let fd = output.fileDescriptor
        while true {
            state.lock()
            while queue.isEmpty, closeReason == nil, drainReason == nil { state.wait() }
            if closeReason != nil || (drainReason != nil && queue.isEmpty) {
                let drained = closeReason == nil ? drainReason : nil
                state.unlock()
                try? output.close()
                if let drained { close(drained) }
                return
            }
            let line = queue.pop() ?? Data()
            state.broadcast()
            state.unlock()
            guard writeAll(line, to: fd) else {
                let reason = String(cString: strerror(errno))
                try? output.close()
                close(.writeFailed(reason))
                return
            }
        }
    }

    // MARK: - For the requests from the peer

    func enqueueControl(_ line: Data) {
        state.lock()
        if closeReason == nil {
            queue.pushControl(line)
            state.broadcast()
        }
        state.unlock()
    }

    /// Queues an `item`, waiting for room. False when the request or the channel ended first.
    func enqueueItem(_ line: Data, for request: ProtocolIncomingRequest) -> Bool {
        state.lock()
        defer { state.unlock() }
        while closeReason == nil, !request.ended, !queue.hasRoom { state.wait() }
        guard closeReason == nil, !request.ended else { return false }
        _ = queue.pushItem(line)
        state.broadcast()
        return true
    }

    /// Queues an event. A subscriber whose queue has no room is ended with `unavailable`. False when the request
    /// has ended.
    func enqueueEvent(_ line: Data, key: String, for request: ProtocolIncomingRequest) -> Bool {
        state.lock()
        guard closeReason == nil, !request.ended else { state.unlock(); return false }
        switch queue.pushEvent(line, request: request.id, key: key) {
        case .queued, .replaced:
            state.broadcast()
            state.unlock()
            return true
        case .full:
            queue.removeEvents(of: request.id)
            let stops = request.stopLocked()
            incoming.removeValue(forKey: request.id)
            queue.pushControl(ProtocolLine.error(id: request.id, ProtocolError(.unavailable, "the subscriber fell behind")))
            state.broadcast()
            state.unlock()
            for stop in stops { stop() }
            return false
        }
    }

    /// Queues the `end` of a request from the peer, once. Called with `state` locked.
    func endLocked(_ request: ProtocolIncomingRequest, line: Data) {
        incoming.removeValue(forKey: request.id)
        guard closeReason == nil else { return }
        queue.pushControl(line)
        state.broadcast()
    }

    /// Drops the unsent events of a request from the peer. Called with `state` locked.
    func dropEventsLocked(of request: ProtocolIncomingRequest) {
        queue.removeEvents(of: request.id)
    }
}

/// A request from the peer, with what its handler answers. It ends exactly once: `finish`, `fail`, a cancel, a
/// subscriber that fell behind, or the end of the channel. Anything sent after that is dropped.
public final class ProtocolIncomingRequest: @unchecked Sendable {
    public let id: Int
    private let frame: ProtocolFrame
    private let channel: ProtocolChannel
    // Guarded by `channel.state`.
    fileprivate(set) var ended = false
    private var cancelled = false
    private var stopped = false
    private var mutationStarted = false
    private var stopHandlers: [() -> Void] = []

    init(channel: ProtocolChannel, frame: ProtocolFrame) {
        self.channel = channel
        self.frame = frame
        id = frame.id
    }

    /// The request's value. A case that this build does not know throws `unsupported`; other values that do not
    /// decode throw `invalid`.
    public func body<T: Decodable>(_ type: T.Type) throws -> T {
        do { return try frame.payload(T.self) }
        catch let error as ProtocolError { throw error }
        catch { throw ProtocolError(.invalid, "the request does not decode: \(error)") }
    }

    /// The peer cancelled it, or the channel ended.
    public var isCancelled: Bool {
        channel.state.lock()
        defer { channel.state.unlock() }
        return cancelled || stopped
    }

    /// Runs `handler` when the peer cancels the request, the subscriber falls behind or the channel ends, or at once
    /// when that has happened already. A mutation that has started is not stopped by a cancel.
    public func onCancel(_ handler: @escaping () -> Void) {
        channel.state.lock()
        guard !stopped else { channel.state.unlock(); handler(); return }
        if !ended { stopHandlers.append(handler) }
        channel.state.unlock()
    }

    /// Marks the request as a mutation that has started: a cancel from now on lets it finish and report what
    /// happened. False when it was cancelled already, and must not start.
    public func startMutation() -> Bool {
        channel.state.lock()
        defer { channel.state.unlock() }
        guard !ended, !cancelled, !stopped else { return false }
        mutationStarted = true
        return true
    }

    /// Sends an `item`, waiting for room in the writer queue. False when the request has ended.
    @discardableResult
    public func send<T: Encodable>(_ item: T) -> Bool {
        guard let line = try? ProtocolLine.item(id: id, item) else { return false }
        return channel.enqueueItem(line, for: self)
    }

    /// Sends an event of a subscription. It replaces an unsent event with the same key. A subscriber that cannot
    /// keep up is ended with `unavailable`. False when the request has ended.
    @discardableResult
    public func sendEvent<T: Encodable>(_ event: T, key: String) -> Bool {
        guard let line = try? ProtocolLine.item(id: id, event) else { return false }
        return channel.enqueueEvent(line, key: key, for: self)
    }

    /// Sends `data` as `item`s of at most `HostProtocol.maxChunkBytes`, one at a time, so other frames go out
    /// between them. Then `finish` ends it. False when the request ended first.
    @discardableResult
    public func stream(_ data: Data, chunkBytes: Int = HostProtocol.maxChunkBytes) -> Bool {
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = data.index(offset, offsetBy: min(chunkBytes, data.endIndex - offset))
            guard send(ProtocolChunk(data: data[offset..<end])) else { return false }
            offset = end
        }
        return true
    }

    /// Ends the request with `ok` and this value.
    public func finish<T: Encodable>(_ value: T) {
        guard let line = try? ProtocolLine.ok(id: id, value) else {
            fail(ProtocolError(.failed, "the answer does not encode"))
            return
        }
        end(line)
    }

    /// Ends the request with `ok` and `{}`.
    public func finish() { finish(ProtocolEmpty()) }

    /// Ends the request with an error.
    public func fail(_ error: ProtocolError) { end(ProtocolLine.error(id: id, error)) }

    private func end(_ line: Data) {
        channel.state.lock()
        guard !ended else { channel.state.unlock(); return }
        ended = true
        stopHandlers = []
        channel.endLocked(self, line: line)
        channel.state.unlock()
    }

    /// The peer's cancel, with `channel.state` locked. Ends the request `cancelled` unless it is a mutation that
    /// has started, and returns the handlers to tell.
    func cancelLocked() -> [() -> Void] {
        guard !ended else { return [] }
        cancelled = true
        guard !mutationStarted else { return [] }
        let handlers = stopLocked()
        channel.dropEventsLocked(of: self)
        channel.endLocked(self, line: ProtocolLine.error(id: id, ProtocolError(.cancelled, "cancelled")))
        return handlers
    }

    /// Ends the request without an answer of its own, with `channel.state` locked, and returns the handlers to tell.
    func stopLocked() -> [() -> Void] {
        ended = true
        stopped = true
        let handlers = stopHandlers
        stopHandlers = []
        return handlers
    }
}

/// Writes all of `data`. A peer that went away fails it with `EPIPE`, since `ignoreBrokenPipes` turned off SIGPIPE.
/// Outside the types, whose own `write` would hide the system call. The tmux control client writes its commands with it too.
func writeAll(_ data: Data, to fd: Int32) -> Bool {
    data.withUnsafeBytes { buffer in
        guard let base = buffer.baseAddress else { return true }
        var offset = 0
        while offset < buffer.count {
            let written = write(fd, base + offset, buffer.count - offset)
            if written < 0, errno == EINTR { continue }
            guard written > 0 else { return false }
            offset += written
        }
        return true
    }
}

/// A write to a pipe or socket whose reader went away fails with `EPIPE` instead of raising SIGPIPE. Darwin turns
/// it off per descriptor; Linux has no such option for a pipe, so the process ignores SIGPIPE.
func ignoreBrokenPipes(on fd: Int32) {
    #if canImport(Darwin)
    _ = fcntl(fd, F_SETNOSIGPIPE, 1)
    #else
    signal(SIGPIPE, SIG_IGN)
    #endif
}
