#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import XCTest
@testable import MuxifyCore

/// The Host Server protocol through a pair of pipes in this process: a client and a server, or one of them and a
/// peer driven by hand, line by line.
final class ProtocolChannelTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        // A test writes by hand to a peer that may have closed; a write then fails rather than ending the process.
        signal(SIGPIPE, SIG_IGN)
    }

    // MARK: - Client and server

    func testAClientAndAServerCompleteHelloThenAPingEndsOk() async throws {
        let wire = Wire()
        let server = HostServer.make(input: wire.serverInput, output: wire.serverOutput, build: "muxify server 1")
        server.start()
        let client = wire.client(build: "muxify client 1")
        let session = try await client.connect()
        XCTAssertEqual(session, ProtocolClient.Session(protocolVersion: 1, peerBuild: "muxify server 1", peerCapabilities: []))
        try await client.ping()
        XCTAssertEqual(server.client?.build, "muxify client 1")
        try await client.call(HostRequest.shutdown)
        let exit = await server.wait()
        XCTAssertEqual(exit, .shutdown)
    }

    func testAnUnknownRequestCaseIsAnsweredUnsupportedAndTheChannelGoesOn() async throws {
        let wire = Wire()
        let server = HostServer.make(input: wire.serverInput, output: wire.serverOutput, build: "s")
        server.start()
        let client = wire.client()
        do {
            try await client.call(["frob": ProtocolEmpty()])
            XCTFail("an unknown request must not end ok")
        } catch let error as ProtocolError {
            XCTAssertEqual(error.code, .unsupported)
            XCTAssertTrue(error.message.contains("frob"), error.message)
        }
        try await client.ping()
        client.close()
        let exit = await server.wait()
        XCTAssertEqual(exit, .inputEnded)
    }

    func testUnknownKeysAreIgnoredByTheServer() throws {
        let wire = Wire()
        let server = HostServer.make(input: wire.serverInput, output: wire.serverOutput, build: "s")
        server.start()
        let mac = wire.handDrivenClient()
        XCTAssertEqual(try mac.line(), "MUXIFY-PROTOCOL")
        XCTAssertTrue((try mac.line() ?? "").contains(#""kind":"hello""#))
        mac.write(#"{"id":0,"kind":"hello","later":1,"hello":{"protocol":1,"build":"b","capabilities":[],"later":[1]}}"#)
        mac.write(#"{"id":1,"kind":"request","later":{},"request":{"ping":{"later":true}}}"#)
        XCTAssertEqual(try mac.line(), #"{"end":{"ok":{}},"id":1,"kind":"end"}"#)
        mac.closeOutput()
    }

    func testCancelIsAnsweredCancelledAndTheHandlerIsTold() async throws {
        let wire = Wire()
        let received = expectation(description: "the request arrived")
        let told = expectation(description: "the handler was told")
        let server = ProtocolServer(input: wire.serverInput, output: wire.serverOutput, build: "s") { request, _ in
            request.onCancel { told.fulfill() }
            received.fulfill()
        }
        server.start()
        let client = wire.client()
        let call = Task { try await client.call(["wait": ProtocolEmpty()]) }
        await fulfillment(of: [received], timeout: 5)
        call.cancel()
        do {
            try await call.value
            XCTFail("a cancelled request must not end ok")
        } catch let error as ProtocolError {
            XCTAssertEqual(error.code, .cancelled)
        }
        await fulfillment(of: [told], timeout: 5)
    }

    func testACancelledMutationThatStartedFinishesAndReportsWhatHappened() async throws {
        let wire = Wire()
        let started = expectation(description: "the mutation started")
        let release = DispatchSemaphore(value: 0)
        let server = ProtocolServer(input: wire.serverInput, output: wire.serverOutput, build: "s") { request, _ in
            XCTAssertTrue(request.startMutation())
            started.fulfill()
            release.wait()
            request.finish(["renamed": "Fix"])
        }
        server.start()
        let client = wire.client()
        let call = Task { try await client.call(["rename": ProtocolEmpty()], as: [String: String].self) }
        await fulfillment(of: [started], timeout: 5)
        call.cancel()
        try await Task.sleep(for: .milliseconds(100))
        release.signal()
        let answer = try await call.value
        XCTAssertEqual(answer, ["renamed": "Fix"])
    }

    func testAStreamedRequestDeliversItsChunksThenOneEnd() async throws {
        let wire = Wire()
        let bytes = Data((0..<(200 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let server = ProtocolServer(input: wire.serverInput, output: wire.serverOutput, build: "s") { request, _ in
            if (try? request.body(HostRequest.self)) == .ping { return request.finish() }
            request.stream(bytes)
            request.finish()
        }
        server.start()
        let client = wire.client()
        var chunks: [Data] = []
        for try await chunk in client.stream(["read": ProtocolEmpty()]) { chunks.append(chunk) }
        XCTAssertEqual(chunks.map(\.count), [65536, 65536, 65536, 8192])
        XCTAssertEqual(chunks.reduce(Data(), +), bytes)
        try await client.ping()
    }

    func testASubscriptionDeliversItsEventsAndStoppingItSendsCancel() async throws {
        let wire = Wire()
        let told = expectation(description: "the subscription was cancelled")
        let server = ProtocolServer(input: wire.serverInput, output: wire.serverOutput, build: "s") { request, _ in
            request.onCancel { told.fulfill() }
            for value in ["full", "a", "b"] { request.sendEvent(["state": value], key: value) }
        }
        server.start()
        let client = wire.client()
        var events: [String] = []
        for try await event in client.subscribe(["watch": ProtocolEmpty()], as: [String: String].self) {
            events.append(event["state"] ?? "")
            if events.count == 3 { break }
        }
        XCTAssertEqual(events, ["full", "a", "b"])
        await fulfillment(of: [told], timeout: 5)
    }

    func testASubscriberThatCannotKeepUpIsEndedUnavailable() async throws {
        let wire = Wire()
        let server = ProtocolServer(input: wire.serverInput, output: wire.serverOutput, build: "s", queueCapacity: 4) { request, _ in
            // Far more keys than the pipe and a queue of 4 hold while the client is not reading.
            for index in 0..<2000 {
                guard request.sendEvent(["n": String(repeating: "x", count: 1000) + String(index)], key: String(index)) else { return }
            }
            request.finish()
        }
        server.start()
        let mac = wire.handDrivenClient()
        XCTAssertEqual(try mac.line(), "MUXIFY-PROTOCOL")
        _ = try mac.line()
        mac.write(#"{"id":0,"kind":"hello","hello":{"protocol":1,"build":"b","capabilities":[]}}"#)
        mac.pause()
        mac.write(#"{"id":1,"kind":"request","request":{"watch":{}}}"#)
        try await Task.sleep(for: .milliseconds(500))
        mac.resume()
        var last = ""
        while let line = try mac.line(timeout: 5) {
            last = line
            if line.contains(#""kind":"end""#) { break }
        }
        XCTAssertEqual(last, #"{"end":{"error":{"code":"unavailable","message":"the subscriber fell behind"}},"id":1,"kind":"end"}"#)
        mac.closeOutput()
    }

    // MARK: - The channel ends

    func testClosingThePipeFailsEveryWaitingCallWithUnavailable() async throws {
        let wire = Wire()
        let host = wire.handDrivenServer()
        host.write("MUXIFY-PROTOCOL")
        host.write(#"{"id":0,"kind":"hello","hello":{"protocol":1,"min_protocol":1,"build":"s","capabilities":[]}}"#)
        let client = wire.client()
        try await client.connect()
        let calls = (0..<3).map { _ in Task { try await client.ping() } }
        _ = try host.line()
        for _ in calls { XCTAssertTrue((try host.line() ?? "").contains(#""ping""#)) }
        host.closeOutput()
        for call in calls {
            do {
                try await call.value
                XCTFail("a call whose channel ended must not end ok")
            } catch let error as ProtocolError {
                XCTAssertEqual(error, .channelEnded)
            }
        }
        do {
            try await client.ping()
            XCTFail("a call on an ended channel must fail")
        } catch let error as ProtocolError {
            XCTAssertEqual(error.code, .unavailable)
        }
    }

    func testAFrameOver16MiBClosesTheChannel() async throws {
        let wire = Wire()
        let host = wire.handDrivenServer()
        host.write("MUXIFY-PROTOCOL")
        host.write(#"{"id":0,"kind":"hello","hello":{"protocol":1,"min_protocol":1,"build":"s","capabilities":[]}}"#)
        let client = wire.client()
        try await client.connect()
        let closed = expectation(description: "the channel closed")
        client.onClose { reason in
            XCTAssertEqual(reason, .frameTooLong)
            closed.fulfill()
        }
        let call = Task { try await client.ping() }
        _ = try host.line()
        _ = try host.line()
        let huge = Data(repeating: UInt8(ascii: "a"), count: HostProtocol.maxFrameBytes + 2)
        DispatchQueue.global().async { host.writeRaw(huge) }
        await fulfillment(of: [closed], timeout: 20)
        do {
            try await call.value
            XCTFail("a call whose channel broke must not end ok")
        } catch let error as ProtocolError {
            XCTAssertEqual(error.code, .unavailable)
        }
    }

    // MARK: - Shell output and the gate

    func testTheClientSkipsShellOutputBeforeTheMagicLine() async throws {
        let wire = Wire()
        let host = wire.handDrivenServer()
        host.write("Welcome to fish, the friendly interactive shell")
        host.write(String(repeating: "motd ", count: 2000))
        host.write("MUXIFY-PROTOCOL")
        host.write(#"{"id":0,"kind":"hello","hello":{"protocol":1,"min_protocol":1,"build":"s","capabilities":[]}}"#)
        let session = try await wire.client().connect()
        XCTAssertEqual(session.peerBuild, "s")
    }

    func testTheClientFailsWithTheByteCountAndFirstLineWhenTheMagicLineIsMissing() async throws {
        let wire = Wire()
        let host = wire.handDrivenServer()
        host.write("fish: Unknown command: muxify")
        host.closeOutput()
        do {
            try await wire.client().connect()
            XCTFail("no magic line must fail")
        } catch let failure as ProtocolClient.Failure {
            XCTAssertEqual(failure, .noMagicLine(printed: 30, firstLine: "fish: Unknown command: muxify"))
        }
    }

    func testTheClientFailsWhenTheMagicLineComesAfter64KiB() async throws {
        let wire = Wire()
        let host = wire.handDrivenServer()
        // The client reads while the shell prints more than a pipe holds.
        let client = wire.client()
        host.write("last login: today")
        for _ in 0..<64 { host.write(String(repeating: "z", count: 1023)) }
        host.write("MUXIFY-PROTOCOL")
        do {
            try await client.connect()
            XCTFail("a late magic line must fail")
        } catch let failure as ProtocolClient.Failure {
            XCTAssertEqual(failure, .noMagicLine(printed: 18 + 64 * 1024, firstLine: "last login: today"))
        }
    }

    func testTheClientPicksTheHighestSharedProtocolAndExposesTheServersCapabilities() async throws {
        let wire = Wire()
        let host = wire.handDrivenServer()
        host.write("MUXIFY-PROTOCOL")
        host.write(#"{"id":0,"kind":"hello","hello":{"protocol":3,"min_protocol":1,"build":"newer","capabilities":["events.git"]}}"#)
        let client = wire.client(build: "older", protocols: 1...2)
        let session = try await client.connect()
        XCTAssertEqual(session.protocolVersion, 2)
        XCTAssertTrue(session.supports("events.git"))
        XCTAssertFalse(session.supports("config.watch"))
        XCTAssertEqual(try host.line(), #"{"hello":{"build":"older","capabilities":[],"protocol":2},"id":0,"kind":"hello"}"#)
    }

    func testNoSharedProtocolFailsWithAReasonThatCarriesTheServersBuild() async throws {
        let wire = Wire()
        let host = wire.handDrivenServer()
        host.write("MUXIFY-PROTOCOL")
        host.write(#"{"id":0,"kind":"hello","hello":{"protocol":5,"min_protocol":4,"build":"muxify abc1234 1800000000","capabilities":[]}}"#)
        let client = wire.client(protocols: 1...1)
        let ping = Task { try await client.ping() }
        do {
            try await client.connect()
            XCTFail("no shared protocol must fail")
        } catch let failure as ProtocolClient.Failure {
            XCTAssertEqual(failure, .noSharedProtocol(serverBuild: "muxify abc1234 1800000000", serverProtocols: 4...5))
            XCTAssertEqual(failure.localizedDescription, "the Host's muxify is too old (muxify abc1234 1800000000)")
        }
        await XCTAssertThrowsErrorAsync { try await ping.value }
        XCTAssertNil(try host.line(timeout: 1), "the client writes nothing, not even its hello")
    }

    func testAMissingHelloFailsAfterTheTimeout() async throws {
        let wire = Wire()
        let host = wire.handDrivenServer()
        host.write("MUXIFY-PROTOCOL")
        let start = Date()
        do {
            try await wire.client(helloTimeout: 0.3).connect()
            XCTFail("a missing hello must fail")
        } catch let failure as ProtocolClient.Failure {
            XCTAssertEqual(failure, .noHello(timeout: 0.3))
        }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.3)
    }

    func testARequestSentBeforeHelloIsNeverWrittenUntilBothHellos() async throws {
        let wire = Wire()
        let host = wire.handDrivenServer()
        let client = wire.client()
        let ping = Task { try await client.ping() }
        XCTAssertNil(try host.line(timeout: 0.3), "nothing is written before the server's hello")
        host.write("MUXIFY-PROTOCOL")
        host.write(#"{"id":0,"kind":"hello","hello":{"protocol":1,"min_protocol":1,"build":"s","capabilities":[]}}"#)
        XCTAssertTrue((try host.line() ?? "").contains(#""kind":"hello""#), "the client's hello comes first")
        XCTAssertEqual(try host.line(), #"{"id":1,"kind":"request","request":{"ping":{}}}"#)
        host.write(#"{"id":1,"kind":"end","end":{"ok":{}}}"#)
        try await ping.value
    }

    func testARequestThatTimedOutWaitingForHelloIsNeverWritten() async throws {
        let wire = Wire()
        let host = wire.handDrivenServer()
        let client = wire.client(helloTimeout: 0.2)
        await XCTAssertThrowsErrorAsync { try await client.ping() }
        XCTAssertNil(try host.line(timeout: 0.3))
    }

    // MARK: - Helpers

    private func XCTAssertThrowsErrorAsync(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await body()
            XCTFail("expected an error", file: file, line: line)
        } catch {}
    }
}

/// Two pipes: the client's output is the server's input, and the server's output the client's input.
private struct Wire {
    let up = Pipe()
    let down = Pipe()

    var serverInput: FileHandle { up.fileHandleForReading }
    var serverOutput: FileHandle { down.fileHandleForWriting }

    func client(build: String = "c", protocols: ClosedRange<Int> = HostProtocol.supported, helloTimeout: TimeInterval = 5) -> ProtocolClient {
        ProtocolClient(input: down.fileHandleForReading, output: up.fileHandleForWriting, build: build, protocols: protocols, helloTimeout: helloTimeout)
    }

    /// The server's end, driven by hand.
    func handDrivenServer() -> HandDriven { HandDriven(output: down.fileHandleForWriting, input: up.fileHandleForReading) }

    /// The client's end, driven by hand.
    func handDrivenClient() -> HandDriven { HandDriven(output: up.fileHandleForWriting, input: down.fileHandleForReading) }
}

/// One end of a channel driven by hand: lines written raw, lines read back with a timeout.
private final class HandDriven: @unchecked Sendable {
    private let output: FileHandle
    private let condition = NSCondition()
    private var buffer = Data()
    private var ended = false
    private var paused = false

    init(output: FileHandle, input: FileHandle) {
        self.output = output
        let thread = Thread { [condition = condition, weak self] in
            while true {
                condition.lock()
                while self?.paused == true { condition.wait() }
                condition.unlock()
                let data = input.availableData
                condition.lock()
                if data.isEmpty { self?.ended = true } else { self?.buffer.append(data) }
                condition.broadcast()
                condition.unlock()
                if data.isEmpty || self == nil { return }
            }
        }
        thread.start()
    }

    func write(_ line: String) { writeRaw(Data((line + "\n").utf8)) }

    func writeRaw(_ data: Data) { try? output.write(contentsOf: data) }

    func closeOutput() { try? output.close() }

    /// Stops reading, so the peer's writes fill the pipe.
    func pause() {
        condition.lock()
        paused = true
        condition.unlock()
    }

    func resume() {
        condition.lock()
        paused = false
        condition.broadcast()
        condition.unlock()
    }

    /// The next line, or nil when none comes in time or the peer closed.
    func line(timeout: TimeInterval = 5) throws -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while true {
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                return String(decoding: line, as: UTF8.self)
            }
            if ended || !condition.wait(until: deadline) { return nil }
        }
    }
}
