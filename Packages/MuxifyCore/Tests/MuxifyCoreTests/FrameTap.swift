import Foundation
@testable import MuxifyCore

/// The protocol frames that one side writes, read on their way to the other side.
final class FrameTap: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [ProtocolFrame] = []

    /// A handle to write in place of `sink`: what is written goes on to `sink`, and the tap has each whole line of it
    /// before `sink` gets it. So once the other side has read a frame, the tap holds it and every frame before it.
    func tapping(_ sink: FileHandle) -> FileHandle {
        let tapped = Pipe()
        let source = tapped.fileHandleForReading
        Thread.detachNewThread { [self] in
            var pending = Data()
            while true {
                let data = source.availableData
                guard !data.isEmpty else { try? sink.close(); return }
                pending.append(data)
                while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                    add(Data(pending[pending.startIndex..<newline]))
                    pending.removeSubrange(pending.startIndex...newline)
                }
                // The other side has gone: the tap stops, and the writer's next write fails.
                guard (try? sink.write(contentsOf: data)) != nil else { return }
            }
        }
        return tapped.fileHandleForWriting
    }

    private func add(_ line: Data) {
        guard let frame = try? ProtocolFrame.decode(line) else { return }
        lock.lock()
        frames.append(frame)
        lock.unlock()
    }

    /// The `item` frames so far.
    var items: [ProtocolFrame] { lock.lock(); defer { lock.unlock() }; return frames.filter { $0.kind == .item } }
}
