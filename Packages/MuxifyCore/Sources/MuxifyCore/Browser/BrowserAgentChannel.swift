import Darwin
import Foundation

/// The Unix socket between `muxify browser` and the app (ADR 0057): one request line of JSON and one reply line
/// of JSON on each connection.
public enum BrowserAgentChannel {
    /// The tmux server option that holds the socket path of the app that serves the server's Browsers.
    public static let option = "@muxify_browser_socket"

    /// The socket of the server at `tmuxSocket`, in the server's own 0700 directory.
    public static func socketPath(forTmuxSocket tmuxSocket: String) -> String { tmuxSocket + ".muxify-browser" }

    public enum Failure: Error, Equatable {
        /// No app listens on the path: the app quit, or crashed and left the option.
        case unreachable(String)
        /// The app took the request, but the reply did not come or did not decode.
        case broken(String)
    }

    public static func send(_ request: BrowserAgentRequest, to path: String) throws -> BrowserAgentReply {
        let fd = try connect(to: path)
        defer { close(fd) }
        var wait = timeval(tv_sec: Int(request.command.replyTimeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        var line = try JSONEncoder().encode(request)
        line.append(UInt8(ascii: "\n"))
        guard write(all: line, to: fd) else { throw Failure.broken("could not send the request to Muxify") }
        guard let reply = readLine(from: fd) else { throw Failure.broken("Muxify did not reply") }
        do { return try JSONDecoder().decode(BrowserAgentReply.self, from: reply) }
        catch { throw Failure.broken("Muxify sent a reply that this muxify cannot read; update the CLI and the app together") }
    }

    private static func connect(to path: String) throws -> Int32 {
        guard var address = address(path) else { throw Failure.unreachable("the socket path is too long: \(path)") }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.unreachable(String(cString: strerror(errno))) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            let reason = String(cString: strerror(errno))
            close(fd)
            throw Failure.unreachable(reason)
        }
        return fd
    }

    static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        return address
    }

    static func write(all data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }

    /// The bytes before the first newline, or before the end when the peer closes without one.
    static func readLine(from fd: Int32) -> Data? {
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return data.isEmpty ? nil : data }
            if let newline = chunk[..<count].firstIndex(of: UInt8(ascii: "\n")) {
                data.append(contentsOf: chunk[..<newline])
                return data
            }
            data.append(contentsOf: chunk[..<count])
        }
    }
}

/// The app's end of the channel. Each connection is read on a queue of its own; `handler` gets the decoded
/// request and calls `reply` once, from any thread.
public final class BrowserAgentListener: @unchecked Sendable {
    public typealias Handler = @Sendable (BrowserAgentRequest, @escaping @Sendable (BrowserAgentReply) -> Void) -> Void

    public let path: String
    private let fd: Int32
    /// The socket file this listener made, so `stop` never removes the file of a listener that replaced it.
    private let inode: ino_t
    private let source: DispatchSourceRead
    private let connections = DispatchQueue(label: "muxify.browser-agent.connections", attributes: .concurrent)

    public init(path: String, handler: @escaping Handler) throws {
        guard var address = BrowserAgentChannel.address(path) else {
            throw BrowserAgentChannel.Failure.unreachable("the socket path is too long: \(path)")
        }
        // A file left by a crashed app, or by another Muxify on the same server, is replaced: the newest app
        // also writes the option, so it is the one that the CLI finds.
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BrowserAgentChannel.Failure.unreachable(String(cString: strerror(errno))) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        var status = stat()
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 16) == 0, stat(path, &status) == 0 else {
            let reason = String(cString: strerror(errno))
            close(fd)
            throw BrowserAgentChannel.Failure.unreachable("cannot listen on \(path): \(reason)")
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        self.path = path
        self.fd = fd
        inode = status.st_ino
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "muxify.browser-agent.accept"))
        let connections = connections
        source.setEventHandler {
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                connections.async { Self.serve(client, handler: handler) }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    public func stop() {
        source.cancel()
        var status = stat()
        if stat(path, &status) == 0, status.st_ino == inode { unlink(path) }
    }

    private static func serve(_ client: Int32, handler: Handler) {
        // An accepted socket inherits O_NONBLOCK from the listener; the reads below wait.
        _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
        var wait = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        let respond: @Sendable (BrowserAgentReply) -> Void = { reply in
            var line = (try? JSONEncoder().encode(reply)) ?? Data()
            line.append(UInt8(ascii: "\n"))
            _ = BrowserAgentChannel.write(all: line, to: client)
            close(client)
        }
        guard let line = BrowserAgentChannel.readLine(from: client) else { close(client); return }
        guard let request = try? JSONDecoder().decode(BrowserAgentRequest.self, from: line) else {
            respond(.failure(message: "Muxify cannot read this request; update the CLI and the app together", exitCode: 2))
            return
        }
        handler(request, respond)
    }
}
