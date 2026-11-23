#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation
import XCTest
@testable import MuxifyCore
import MuxifyTestSupport

/// A Host Server's own socket (ADR 0091) through a pair of pipes in this process: a program's line on the socket
/// reaches the protocol client as a `MacRequest`, and `@muxify_browser_socket` follows `claim_open` and
/// `release_open`, on a throwaway tmux server.
final class HostServerSocketTests: DescriptorCheckedTestCase {
    private var directory: URL!
    private var tmux: TmuxServer!
    private var paths: MuxifyPaths!
    private var servers: [ProtocolServer] = []
    private var clients: [ProtocolClient] = []
    private var saved: [String: String?] = [:]
    private var socket: String { directory.appendingPathComponent("s").path }

    override class func setUp() {
        super.setUp()
        signal(SIGPIPE, SIG_IGN)
    }

    override func setUpWithError() throws {
        _ = try requireTmux()
        // A short path: a socket path must fit in 104 bytes.
        directory = URL(fileURLWithPath: "/tmp/mxs-" + UUID().uuidString.prefix(8), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tmux = TmuxServer(socketPath: socket, configPath: "/dev/null")
        paths = MuxifyPaths(environment: ["XDG_STATE_HOME": directory.appendingPathComponent("state").path], home: "/nonexistent")
        for name in ["TMUX", "TMUX_PANE", "TMUX_TMPDIR"] { saved[name] = ProcessInfo.processInfo.environment[name] }
        unsetenv("TMUX")
        unsetenv("TMUX_PANE")
        setenv("TMUX_TMPDIR", directory.path, 1)
        try tmux.run(["new-session", "-d", "-s", "work", "-x", "120", "-y", "40", "-c", directory.path])
    }

    override func tearDown() async throws {
        clients.forEach { $0.close() }
        for server in servers { _ = await server.wait() }
        // XCTest keeps every test case to the end of the run, and with it what the test case holds (DescriptorCheck).
        clients = []
        servers = []
        if let actual = try? tmux?.run(["display-message", "-p", "#{socket_path}"]),
           actual.trimmingCharacters(in: .whitespacesAndNewlines) == socket {
            _ = try? tmux.run(["kill-server"])
        }
        for (name, value) in saved {
            if let value { setenv(name, value, 1) } else { unsetenv(name) }
        }
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: - Requests from the Host

    func testALineOnTheSocketReachesTheClientAsABrowserRequestAndTheClientsReplyComesBack() async throws {
        let tab = BrowserAgentTab(id: UUID(), url: "http://localhost:3000/", title: "App", active: true)
        let mac = MacSide { request, incoming in
            if case .browser = request { incoming.finish(browser: .tabs([tab])) }
        }
        let path = try await connect(id: "101", mac: mac).path

        let request = BrowserAgentRequest(window: "@3", command: .tabs)
        let reply = try await send(request, to: path)
        XCTAssertEqual(reply, .tabs([tab]))
        XCTAssertEqual(mac.requests, [.browser(request)])
    }

    func testAScreenshotLargerThanOneChunkArrivesAsChunksAndComesBackWhole() async throws {
        var picture = Data([0x89, 0x50, 0x4E, 0x47])
        picture.append(Data((0..<(200 * 1024)).map { UInt8($0 % 251) }))
        let mac = MacSide { _, incoming in incoming.finish(browser: .png(picture)) }
        let tap = FrameTap()
        let path = try await connect(id: "102", mac: mac, tap: tap).path

        let reply = try await send(BrowserAgentRequest(window: "@3", command: .screenshot), to: path)
        XCTAssertEqual(reply, .png(picture))
        let chunks = tap.items.compactMap { try? $0.payload(ProtocolChunk.self).data }
        XCTAssertEqual(chunks.count, 4, "200 KiB goes as four chunks of at most 64 KiB")
        XCTAssertTrue(chunks.allSatisfy { $0.count <= HostProtocol.maxChunkBytes })
        XCTAssertEqual(chunks.reduce(Data(), +), picture)
    }

    func testASelectLineReachesTheClientAsASelectRequest() async throws {
        let mac = MacSide { _, incoming in incoming.finish() }
        let path = try await connect(id: "103", mac: mac).path
        let reply = try await Task.detached {
            try BrowserAgentChannel.send(MacRequest.select(.window("@7")), replyTimeout: 10, to: path)
        }.value
        XCTAssertEqual(reply, .done)
        XCTAssertEqual(mac.requests, [.select(.window("@7"))])
    }

    func testARequestWithNoHandlerOnTheMacFailsWithCannotReachMuxify() async throws {
        let path = try await connect(id: "104", mac: nil).path
        let reply = try await send(BrowserAgentRequest(window: "@3", command: .tabs), to: path)
        guard case .failure(let message, _) = reply else { return XCTFail("unexpected \(reply)") }
        XCTAssertTrue(message.hasPrefix("cannot reach Muxify"), message)
    }

    // MARK: - The socket's file

    func testTheSocketSitsBesideTmuxsAndGoesWhenTheServerExits() async throws {
        let (path, client, server) = try await connect(id: "105", mac: nil)
        XCTAssertEqual(path, socket + ".muxify-browser.105")
        XCTAssertTrue(BrowserAgentChannel.isHostServerSocket(path))
        XCTAssertFalse(BrowserAgentChannel.isHostServerSocket(BrowserAgentChannel.socketPath(forTmuxSocket: socket)))
        await eventually("the socket is not beside tmux's") { FileManager.default.fileExists(atPath: path) }
        client.close()
        _ = await server.wait()
        await eventually("the socket outlived its server") { !FileManager.default.fileExists(atPath: path) }
    }

    func testAStartingServerRemovesADeadSocketAndKeepsALiveOne() async throws {
        let dead = socket + ".muxify-browser.98"
        try leaveDeadSocket(at: dead)
        let live = try BrowserAgentListener(path: socket + ".muxify-browser.99") { _, respond in respond(.done) }
        defer { live.stop() }
        XCTAssertTrue(BrowserAgentChannel.refusesConnection(dead))

        _ = try await connect(id: "106", mac: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dead), "a killed server's socket stayed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.path), "a live server's socket was removed")
    }

    // MARK: - @muxify_browser_socket

    func testTheOptionFollowsClaimOpenAndReleaseOpen() async throws {
        let first = try await connect(id: "107", mac: nil)
        let second = try await connect(id: "108", mac: nil)
        try await first.client.call(HostRequest.claimOpen)
        XCTAssertEqual(try option(), first.path)

        try await second.client.call(HostRequest.claimOpen)
        XCTAssertEqual(try option(), second.path, "the App Window used last takes the option")
        try await first.client.call(HostRequest.releaseOpen)
        XCTAssertEqual(try option(), second.path, "a release leaves another server's socket")

        try await second.client.call(HostRequest.releaseOpen)
        XCTAssertEqual(try option(), "")
    }

    func testAnExitingServerClearsTheOptionOnlyWhileItNamesItsSocket() async throws {
        let first = try await connect(id: "109", mac: nil)
        try await first.client.call(HostRequest.claimOpen)
        try tmux.run(["set-option", "-sq", BrowserAgentChannel.option, "/elsewhere.muxify-browser.1"])
        first.client.close()
        _ = await first.server.wait()
        XCTAssertEqual(try option(), "/elsewhere.muxify-browser.1", "an exit cleared another server's socket")

        let second = try await connect(id: "110", mac: nil)
        try await second.client.call(HostRequest.claimOpen)
        XCTAssertEqual(try option(), second.path)
        second.client.close()
        _ = await second.server.wait()
        XCTAssertEqual(try option(), "", "an exit left its own socket in the option")
    }

    func testTheConsumersServerTakesTheOptionWhileItIsEmpty() async throws {
        let consumer = try await connect(id: "111", mac: nil)
        let events = consumer.client.subscribe(HostRequest.subscribe(.environment), as: EnvironmentItem.self)
        let reading = Task { for try await _ in events {} }
        defer { reading.cancel() }
        try await consumer.client.call(HostRequest.claimOpen)
        XCTAssertEqual(try option(), consumer.path)

        // Another server that exits clears the option; the consumer's server takes it again from its next read.
        try tmux.run(["set-option", "-squ", BrowserAgentChannel.option])
        try tmux.run(["new-session", "-d", "-s", "other"])
        await eventually("the consumer's server did not take the empty option") { (try? self.option()) == consumer.path }
    }

    // MARK: - Helpers

    /// The Mac's end: records each request and answers it with `answer`.
    private final class MacSide: @unchecked Sendable {
        private let lock = NSLock()
        private var log: [MacRequest] = []
        let answer: (MacRequest, ProtocolIncomingRequest) -> Void

        init(answer: @escaping (MacRequest, ProtocolIncomingRequest) -> Void) { self.answer = answer }

        func serve(_ incoming: ProtocolIncomingRequest) {
            guard let request = try? incoming.body(MacRequest.self) else { return incoming.fail(ProtocolError(.invalid, "?")) }
            lock.lock()
            log.append(request)
            lock.unlock()
            answer(request, incoming)
        }

        var requests: [MacRequest] { lock.lock(); defer { lock.unlock() }; return log }
    }

    /// A server whose socket is `<tmux socket>.muxify-browser.<id>`, and a client whose requests from the server go
    /// to `mac`; without it, the client serves none.
    private func connect(id: String, mac: MacSide?, tap: FrameTap? = nil) async throws
        -> (path: String, client: ProtocolClient, server: ProtocolServer) {
        let up = Pipe(), down = Pipe()
        let server = HostServer.make(input: up.fileHandleForReading, output: down.fileHandleForWriting, build: "server",
                                     context: HostServerContext(paths: paths, tmux: tmux, config: { Config() }, socketID: id))
        server.start()
        servers.append(server)
        // What the client writes goes on to the server, and the tap gets each whole line of it.
        let output = tap?.tapping(up.fileHandleForWriting) ?? up.fileHandleForWriting
        let client = ProtocolClient(input: down.fileHandleForReading, output: output, build: "client", helloTimeout: 5,
                                    onRequest: mac.map { mac in { mac.serve($0) } })
        clients.append(client)
        try await client.connect()
        return (socket + ".muxify-browser." + id, client, server)
    }

    private func send(_ request: BrowserAgentRequest, to path: String) async throws -> BrowserAgentReply {
        try await Task.detached { try BrowserAgentChannel.send(request, to: path) }.value
    }

    private func option() throws -> String {
        try tmux.run(["show-options", "-sqv", BrowserAgentChannel.option]).trimmingCharacters(in: .newlines)
    }

    /// A socket file that nobody listens on, as a server killed with -9 leaves.
    private func leaveDeadSocket(at path: String) throws {
        var address = try XCTUnwrap(BrowserAgentChannel.address(path))
        #if canImport(Glibc)
        let fd = Glibc.socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
        defer { close(fd) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                #if canImport(Glibc)
                Glibc.bind(fd, pointer, socklen_t(MemoryLayout<sockaddr_un>.size))
                #else
                Darwin.bind(fd, pointer, socklen_t(MemoryLayout<sockaddr_un>.size))
                #endif
            }
        }
        XCTAssertEqual(bound, 0)
    }
}
