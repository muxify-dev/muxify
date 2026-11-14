import Foundation

/// Splits the bytes of a channel into frame lines. The client's reader first skips what a login shell prints before
/// the magic line, up to `HostProtocol.maxPreambleBytes`.
struct ProtocolLineReader {
    enum Failure: Error, Equatable {
        /// The magic line did not come in the first 64 KiB, or the channel ended before it: how many bytes the shell
        /// printed, and the first line of them.
        case noMagicLine(printed: Int, firstLine: String)
        /// A line longer than `maxFrameBytes`.
        case frameTooLong
    }

    private(set) var awaitingMagic: Bool
    private let maxFrameBytes: Int
    private let maxPreambleBytes: Int
    private var buffer: [UInt8] = []
    /// How far `buffer` has been searched for a newline.
    private var scanned = 0
    private var skipped = 0
    private var firstLine: String?

    init(awaitingMagic: Bool, maxFrameBytes: Int = HostProtocol.maxFrameBytes, maxPreambleBytes: Int = HostProtocol.maxPreambleBytes) {
        self.awaitingMagic = awaitingMagic
        self.maxFrameBytes = maxFrameBytes
        self.maxPreambleBytes = maxPreambleBytes
    }

    /// The complete frame lines in `bytes` and in what came before them. Blank lines are skipped.
    mutating func feed<Bytes: Collection>(_ bytes: Bytes) throws -> [Data] where Bytes.Element == UInt8 {
        buffer.append(contentsOf: bytes)
        var lines: [Data] = []
        var start = 0
        while let newline = buffer[scanned...].firstIndex(of: UInt8(ascii: "\n")) {
            let lineStart = start
            var line = buffer[lineStart..<newline]
            if line.last == UInt8(ascii: "\r") { line = line.dropLast() }
            start = newline + 1
            scanned = start
            if awaitingMagic {
                if line.elementsEqual(HostProtocol.magicLine.utf8) {
                    awaitingMagic = false
                } else {
                    if firstLine == nil { firstLine = String(decoding: line, as: UTF8.self) }
                    skipped += start - lineStart
                    if skipped > maxPreambleBytes { throw noMagicLine(pending: 0) }
                }
                continue
            }
            guard line.count <= maxFrameBytes else { throw Failure.frameTooLong }
            if !line.isEmpty { lines.append(Data(line)) }
        }
        buffer.removeFirst(start)
        scanned = buffer.count
        if awaitingMagic {
            // The partial line can still be the magic line only while it is no longer than it.
            let partial = buffer.count > HostProtocol.magicLine.utf8.count + 1 ? buffer.count : 0
            if skipped + partial > maxPreambleBytes { throw noMagicLine(pending: buffer.count) }
        } else if buffer.count > maxFrameBytes + 1 {
            throw Failure.frameTooLong
        }
        return lines
    }

    /// The failure when the channel ends while the reader still waits for the magic line.
    var endFailure: Failure? { awaitingMagic ? noMagicLine(pending: buffer.count) : nil }

    /// `pending` is how many bytes after the skipped lines the shell printed.
    private func noMagicLine(pending: Int) -> Failure {
        let first = firstLine ?? String(decoding: buffer.suffix(pending).prefix(200), as: UTF8.self)
        return .noMagicLine(printed: skipped + pending, firstLine: String(first.prefix(200)))
    }
}
