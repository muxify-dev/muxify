import XCTest
@testable import MuxifyCore

/// The JSON of every frame of the Host Server protocol is a contract (ADR 0084's change rule): these strings are
/// pinned, and every release's fixtures folder must still decode.
final class ProtocolWireTests: XCTestCase {
    private static let build = "muxify 1a2b3c4 1763100000"

    /// This release's messages, in the order of the newest fixtures folder.
    private func thisReleasesFrames() throws -> [Data] {
        [
            try ProtocolLine.hello(ProtocolHello(protocolVersion: 1, minProtocol: 1, build: Self.build)),
            try ProtocolLine.hello(ProtocolHello(protocolVersion: 1, build: Self.build)),
            try ProtocolLine.request(id: 1, HostRequest.ping),
            try ProtocolLine.request(id: 2, HostRequest.shutdown),
            try ProtocolLine.item(id: 3, ProtocolChunk(data: Data("hello".utf8))),
            try ProtocolLine.ok(id: 1, ProtocolEmpty()),
            ProtocolLine.error(id: 4, ProtocolError(.unsupported, "this muxify does not know the request frob")),
            ProtocolLine.error(id: 5, ProtocolError(.invalid, "m")),
            ProtocolLine.error(id: 6, ProtocolError(.cancelled, "cancelled")),
            ProtocolLine.error(id: 7, ProtocolError(.unavailable, "the subscriber fell behind")),
            ProtocolLine.error(id: 8, ProtocolError(.failed, "m")),
            ProtocolLine.cancel(id: 6),
        ]
    }

    func testEveryEnvelopeKindAndHelloArePinned() throws {
        func text(_ line: Data) -> String { String(decoding: line, as: UTF8.self) }
        XCTAssertEqual(text(try ProtocolLine.hello(ProtocolHello(protocolVersion: 1, minProtocol: 1, build: Self.build))),
                       #"{"hello":{"build":"muxify 1a2b3c4 1763100000","capabilities":[],"min_protocol":1,"protocol":1},"id":0,"kind":"hello"}"# + "\n")
        XCTAssertEqual(text(try ProtocolLine.hello(ProtocolHello(protocolVersion: 2, build: "muxify dev 0", capabilities: ["events.git"]))),
                       #"{"hello":{"build":"muxify dev 0","capabilities":["events.git"],"protocol":2},"id":0,"kind":"hello"}"# + "\n")
        XCTAssertEqual(text(try ProtocolLine.request(id: 1, HostRequest.ping)), #"{"id":1,"kind":"request","request":{"ping":{}}}"# + "\n")
        XCTAssertEqual(text(try ProtocolLine.request(id: 9, HostRequest.shutdown)), #"{"id":9,"kind":"request","request":{"shutdown":{}}}"# + "\n")
        XCTAssertEqual(text(try ProtocolLine.item(id: 3, ProtocolChunk(data: Data("hi".utf8)))), #"{"id":3,"item":{"data":"aGk="},"kind":"item"}"# + "\n")
        XCTAssertEqual(text(try ProtocolLine.ok(id: 1, ProtocolEmpty())), #"{"end":{"ok":{}},"id":1,"kind":"end"}"# + "\n")
        for code in ProtocolErrorCode.allCases {
            XCTAssertEqual(text(ProtocolLine.error(id: 2, ProtocolError(code, "m"))),
                           #"{"end":{"error":{"code":"\#(code.rawValue)","message":"m"}},"id":2,"kind":"end"}"# + "\n")
        }
        XCTAssertEqual(text(ProtocolLine.cancel(id: 4)), #"{"id":4,"kind":"cancel"}"# + "\n")
        XCTAssertEqual(text(ProtocolLine.magic), "MUXIFY-PROTOCOL\n")
    }

    func testAFrameIsOneLineEvenWhenItsStringsHoldNewlines() throws {
        let line = ProtocolLine.error(id: 1, ProtocolError(.failed, "one\ntwo\r\nthree"))
        XCTAssertEqual(line.filter { $0 == UInt8(ascii: "\n") }.count, 1)
        XCTAssertEqual(try XCTUnwrap(try ProtocolFrame.decode(line.dropLast())).outcome(ProtocolEmpty.self),
                       .failure(ProtocolError(.failed, "one\ntwo\r\nthree")))
    }

    func testUnknownKeysAreIgnoredAndAnUnknownCodeReadsAsFailed() throws {
        let hello = try XCTUnwrap(try ProtocolFrame.decode(Data(#"{"id":0,"kind":"hello","later":true,"hello":{"protocol":3,"min_protocol":1,"build":"b","capabilities":["x"],"later":{}}}"#.utf8)))
        XCTAssertEqual(try hello.payload(ProtocolHello.self), ProtocolHello(protocolVersion: 3, minProtocol: 1, build: "b", capabilities: ["x"]))
        let request = try XCTUnwrap(try ProtocolFrame.decode(Data(#"{"id":1,"kind":"request","request":{"ping":{"later":1},"later":{}}}"#.utf8)))
        XCTAssertEqual(try request.payload(HostRequest.self), .ping)
        let end = try XCTUnwrap(try ProtocolFrame.decode(Data(#"{"id":1,"kind":"end","end":{"error":{"code":"later","message":"m"}}}"#.utf8)))
        XCTAssertEqual(end.outcome(ProtocolEmpty.self), .failure(ProtocolError(.failed, "m")))
        XCTAssertNil(try ProtocolFrame.decode(Data(#"{"id":1,"kind":"later"}"#.utf8)), "a kind this build does not know is skipped")
        XCTAssertThrowsError(try ProtocolFrame.decode(Data(#"{"kind":"end"}"#.utf8)), "a line with no id is not a frame")
    }

    func testAnUnknownRequestCaseThrowsUnsupported() {
        XCTAssertThrowsError(try JSONDecoder().decode(HostRequest.self, from: Data(#"{"frob":{}}"#.utf8))) { error in
            XCTAssertEqual((error as? ProtocolError)?.code, .unsupported)
        }
    }

    /// The newest folder holds exactly this release's messages; every folder, this one and those of earlier
    /// releases, decodes.
    func testEveryReleasesFixturesDecode() throws {
        let root = try XCTUnwrap(Bundle.module.url(forResource: "Protocol", withExtension: nil, subdirectory: "Fixtures"))
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        XCTAssertEqual(folders.last?.lastPathComponent, "1-first-server")
        for folder in folders {
            let text = try String(contentsOf: folder.appendingPathComponent("frames.jsonl"), encoding: .utf8)
            let lines = text.split(separator: "\n").map { Data($0.utf8) }
            XCTAssertFalse(lines.isEmpty, folder.lastPathComponent)
            for line in lines {
                let frame = try XCTUnwrap(try ProtocolFrame.decode(line), String(decoding: line, as: UTF8.self))
                switch frame.kind {
                case .hello: XCTAssertNoThrow(try frame.payload(ProtocolHello.self))
                case .request: XCTAssertNoThrow(try frame.payload(HostRequest.self))
                case .item: XCTAssertNoThrow(try frame.payload(ProtocolChunk.self))
                case .end:
                    if case .failure(let error) = frame.outcome(ProtocolEmpty.self) { XCTAssertNotEqual(error.message, "", "\(error)") }
                case .cancel: XCTAssertGreaterThan(frame.id, 0)
                }
            }
            if folder == folders.last {
                XCTAssertEqual(lines, try thisReleasesFrames().map { $0.dropLast() }, "the newest fixtures are this release's messages")
            }
        }
    }

    // MARK: - Lines

    func testTheReaderSkipsShellOutputBeforeTheMagicLine() throws {
        var reader = ProtocolLineReader(awaitingMagic: true)
        XCTAssertEqual(try reader.feed(Data("Welcome to fish\r\nlast login\nMUXIFY-PRO".utf8)), [])
        XCTAssertEqual(try reader.feed(Data("TOCOL\r\n{\"a\":1}\n\n{\"b\"".utf8)), [Data(#"{"a":1}"#.utf8)])
        XCTAssertEqual(try reader.feed(Data(":2}\n".utf8)), [Data(#"{"b":2}"#.utf8)])
        XCTAssertNil(reader.endFailure)
    }

    func testTheReaderFailsWithTheByteCountAndFirstLineWhenTheMagicLineIsLateOrMissing() throws {
        var missing = ProtocolLineReader(awaitingMagic: true)
        XCTAssertEqual(try missing.feed(Data("bash: muxify: command not found\nbye".utf8)), [])
        XCTAssertEqual(missing.endFailure, .noMagicLine(printed: 35, firstLine: "bash: muxify: command not found"))

        let line = String(repeating: "x", count: 1023) + "\n"
        var exactly = ProtocolLineReader(awaitingMagic: true)
        XCTAssertEqual(try exactly.feed(Data((String(repeating: line, count: 64) + "MUXIFY-PROTOCOL\n{}\n").utf8)), [Data("{}".utf8)],
                       "64 KiB of shell output is skipped")
        var late = ProtocolLineReader(awaitingMagic: true)
        XCTAssertThrowsError(try late.feed(Data(("motd\n" + String(repeating: line, count: 64) + "MUXIFY-PROTOCOL\n").utf8))) { error in
            XCTAssertEqual(error as? ProtocolLineReader.Failure, .noMagicLine(printed: 5 + 64 * 1024, firstLine: "motd"))
        }
        var endless = ProtocolLineReader(awaitingMagic: true)
        XCTAssertThrowsError(try endless.feed(Data(repeating: UInt8(ascii: "y"), count: 64 * 1024 + 100))) { error in
            XCTAssertEqual(error as? ProtocolLineReader.Failure, .noMagicLine(printed: 64 * 1024 + 100, firstLine: String(repeating: "y", count: 200)))
        }
    }

    func testALineOverTheLimitIsAProtocolError() throws {
        var reader = ProtocolLineReader(awaitingMagic: false, maxFrameBytes: 8)
        XCTAssertEqual(try reader.feed(Data("12345678\n".utf8)), [Data("12345678".utf8)])
        XCTAssertThrowsError(try reader.feed(Data("123456789\n".utf8)))
        var partial = ProtocolLineReader(awaitingMagic: false, maxFrameBytes: 8)
        XCTAssertThrowsError(try partial.feed(Data("1234567890".utf8)), "a long line fails before its newline comes")
    }

    // MARK: - The writer queue

    func testANewerEventReplacesAnUnsentOneWithTheSameKey() {
        var queue = ProtocolWriterQueue(capacity: 3)
        XCTAssertEqual(queue.pushEvent(Data("a1".utf8), request: 1, key: "session $1"), .queued)
        XCTAssertEqual(queue.pushEvent(Data("b1".utf8), request: 1, key: "topic t"), .queued)
        XCTAssertEqual(queue.pushEvent(Data("a2".utf8), request: 1, key: "session $1"), .replaced)
        XCTAssertEqual(queue.pushEvent(Data("other".utf8), request: 2, key: "session $1"), .queued, "another subscription's key is its own")
        queue.pushControl(Data("end".utf8))
        XCTAssertEqual([queue.pop(), queue.pop(), queue.pop(), queue.pop(), queue.pop()],
                       [Data("a2".utf8), Data("b1".utf8), Data("other".utf8), Data("end".utf8), nil])
    }

    func testAFullQueueRefusesANewEventAndItemsButNotControlFrames() {
        var queue = ProtocolWriterQueue(capacity: 2)
        XCTAssertEqual(queue.pushEvent(Data("a".utf8), request: 1, key: "a"), .queued)
        XCTAssertTrue(queue.pushItem(Data("chunk".utf8)))
        XCTAssertEqual(queue.pushEvent(Data("b".utf8), request: 1, key: "b"), .full)
        XCTAssertEqual(queue.pushEvent(Data("a2".utf8), request: 1, key: "a"), .replaced, "replacing needs no room")
        XCTAssertFalse(queue.pushItem(Data("chunk".utf8)))
        queue.pushControl(Data("end".utf8))
        queue.removeEvents(of: 1)
        XCTAssertEqual([queue.pop(), queue.pop(), queue.pop()], [Data("chunk".utf8), Data("end".utf8), nil])
    }

    func testTheClientPicksTheHighestProtocolBothSpeak() {
        XCTAssertEqual(ProtocolClient.pick(1...3, 1...2), 2)
        XCTAssertEqual(ProtocolClient.pick(2...2, 1...4), 2)
        XCTAssertEqual(ProtocolClient.pick(1...1, 1...1), 1)
        XCTAssertNil(ProtocolClient.pick(3...4, 1...2))
        XCTAssertEqual(ProtocolHello(protocolVersion: 3, minProtocol: 2, build: "b").offered, 2...3)
        XCTAssertEqual(ProtocolHello(protocolVersion: 3, build: "b").offered, 3...3)
        XCTAssertNil(ProtocolHello(protocolVersion: 1, minProtocol: 2, build: "b").offered)
    }
}
