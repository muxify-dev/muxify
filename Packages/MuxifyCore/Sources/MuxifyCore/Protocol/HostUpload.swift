#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation

extension ProtocolClient {
    /// Uploads one Attachment to the Host as a pipelined run of `upload` chunks of at most
    /// `HostProtocol.maxChunkBytes`, with at most `window` of them waiting for their `end`. Returns the file's path on
    /// the Host. When a chunk fails, the chunks still waiting are cancelled, the server deletes the partial file, and
    /// the chunk's error is thrown.
    public func upload(_ file: URL, name: String, window: Int = 8) async throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
        var waiting: [ProtocolCall<UploadPath>] = []
        var path: String?
        var offset = 0
        do {
            var last = false
            while !last {
                let data = try handle.read(upToCount: min(HostProtocol.maxChunkBytes, max(size - offset, 0))) ?? Data()
                last = data.isEmpty || offset + data.count >= size
                waiting.append(begin(HostRequest.upload(UploadChunk(name: name, offset: offset, data: data, last: last)), as: UploadPath.self))
                offset += data.count
                while waiting.count >= max(window, 1) || (last && !waiting.isEmpty) {
                    path = try await waiting.removeFirst().value.path
                }
            }
        } catch {
            waiting.forEach { $0.cancel() }
            throw error
        }
        guard let path else { throw ProtocolError(.failed, "the upload of \(name) answered no path") }
        return path
    }
}

/// The uploads of one Host Server. A chunk is written once every chunk before it is: the channel hands requests to
/// their handlers concurrently, so a chunk can arrive before the one it follows, and waits for it. The file is
/// written as `.upload` in a private folder of its own under the Host's `TMPDIR`, and takes its name only when its
/// last chunk is written, as the Sessions-only upload script does. A failed chunk deletes the folder; so does a
/// cancelled one, and a server that stops with an upload unfinished.
final class HostUploads: @unchecked Sendable {
    private let directory: String
    private let queue = DispatchQueue(label: "dev.muxify.host-server.uploads")
    // Only `queue` touches these.
    private var uploads: [String: Upload] = [:]

    private final class Upload {
        var folder: String?
        var handle: FileHandle?
        var written = 0
        /// Chunks that came before the one they follow, by offset.
        var held: [Int: (UploadChunk, ProtocolIncomingRequest)] = [:]
        /// Set once a chunk failed: every later chunk of the run fails with it, until a new run starts at offset 0.
        var failure: String?

        var path: String? { folder.map { $0 + "/" + name } }
        let name: String

        init(name: String) { self.name = name }
    }

    init(directory: String) {
        self.directory = directory
    }

    func receive(_ chunk: UploadChunk, for request: ProtocolIncomingRequest) {
        queue.async { self.take(chunk, request) }
        request.onCancel { [weak self] in
            self?.queue.async { self?.abort(chunk.name, because: "the upload of \(chunk.name) was cancelled", request: nil) }
        }
    }

    /// Deletes every unfinished upload.
    func stop() {
        queue.sync {
            for name in Array(uploads.keys) { abort(name, because: "the Host Server stopped", request: nil) }
            uploads = [:]
        }
    }

    // MARK: - On `queue`

    private func take(_ chunk: UploadChunk, _ request: ProtocolIncomingRequest) {
        let name = chunk.name
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            return request.fail(ProtocolError(.invalid, "an upload's name must be one file name, not \"\(name)\""))
        }
        guard chunk.data.count <= HostProtocol.maxChunkBytes, chunk.offset >= 0 else {
            return abort(name, because: "a chunk of \(name) is larger than \(HostProtocol.maxChunkBytes) bytes", request: request)
        }
        if chunk.offset == 0 {
            if let running = uploads[name], running.folder != nil || running.failure != nil {
                abort(name, because: "a new upload of \(name) started", request: nil)
                uploads[name] = nil
            }
            let upload = uploads[name] ?? Upload(name: name)
            uploads[name] = upload
            do {
                try start(upload)
            } catch {
                return abort(name, because: "the upload of \(name) could not start: \(Self.message(error))", request: request)
            }
            write(chunk, request, to: upload)
            return
        }
        let upload = uploads[name] ?? Upload(name: name)
        uploads[name] = upload
        if let failure = upload.failure { return request.fail(ProtocolError(.failed, failure)) }
        if upload.folder != nil, chunk.offset < upload.written {
            return abort(name, because: "a chunk of \(name) at \(chunk.offset) overlaps the \(upload.written) bytes written", request: request)
        }
        if upload.folder != nil, chunk.offset == upload.written {
            write(chunk, request, to: upload)
        } else {
            upload.held[chunk.offset] = (chunk, request)
        }
    }

    private func start(_ upload: Upload) throws {
        var template = Array((directory + "/muxify-paste.XXXXXXXX").utf8CString)
        guard let made = template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress!) }) else {
            throw ProtocolError(.failed, String(cString: strerror(errno)))
        }
        let folder = String(cString: made)
        upload.folder = folder
        let fd = open(folder + "/.upload", O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw ProtocolError(.failed, String(cString: strerror(errno))) }
        upload.handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// Writes a chunk that follows what is written, then each held chunk that now follows.
    private func write(_ chunk: UploadChunk, _ request: ProtocolIncomingRequest, to upload: Upload) {
        let name = upload.name
        guard request.startMutation() else {
            return abort(name, because: "the upload of \(name) was cancelled", request: nil)
        }
        guard let handle = upload.handle, let folder = upload.folder, let path = upload.path else {
            return abort(name, because: "the upload of \(name) has no file", request: request)
        }
        do {
            try handle.write(contentsOf: chunk.data)
            upload.written += chunk.data.count
            if chunk.last {
                try handle.close()
                upload.handle = nil
                guard rename(folder + "/.upload", path) == 0 else { throw ProtocolError(.failed, String(cString: strerror(errno))) }
            }
        } catch {
            return abort(name, because: "a chunk of \(name) could not be written: \(Self.message(error))", request: request)
        }
        request.finish(UploadPath(path: path))
        if chunk.last {
            let extra = upload.held.values
            uploads[name] = nil
            for (_, held) in extra { held.fail(ProtocolError(.invalid, "a chunk of \(name) came after its last")) }
            return
        }
        if let (next, nextRequest) = upload.held.removeValue(forKey: upload.written) {
            write(next, nextRequest, to: upload)
        }
    }

    /// Deletes the partial file of `name` and fails `request` and every held chunk with `reason`.
    private func abort(_ name: String, because reason: String, request: ProtocolIncomingRequest?) {
        let error = ProtocolError(.failed, reason)
        request?.fail(error)
        guard let upload = uploads[name] else { return }
        guard upload.failure == nil else { return }
        try? upload.handle?.close()
        upload.handle = nil
        if let folder = upload.folder { try? FileManager.default.removeItem(atPath: folder) }
        upload.folder = nil
        upload.failure = reason
        let held = upload.held.values
        upload.held = [:]
        for (_, request) in held { request.fail(error) }
    }

    private static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}
