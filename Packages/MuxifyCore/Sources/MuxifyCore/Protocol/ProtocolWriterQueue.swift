import Foundation

/// The frames that one side has made and not yet written, in order. It is bounded: an `item` waits for room, so a
/// stream's chunks go out one at a time among the other frames. Control frames (`hello`, `request`, `end`, `cancel`)
/// always go in, so the reader that answers a frame never waits on the writer. An event replaces an unsent event of
/// its subscription with the same key, since events push state, not deltas.
struct ProtocolWriterQueue {
    enum EventAdmission: Equatable {
        case queued
        /// It took the place of an unsent event with the same key.
        case replaced
        /// No room, and no unsent event with its key: the subscriber cannot keep up.
        case full
    }

    private struct Entry {
        var line: Data
        let request: Int?
        let key: String?
    }

    let capacity: Int
    private var entries: [Entry] = []

    init(capacity: Int) { self.capacity = max(1, capacity) }

    var isEmpty: Bool { entries.isEmpty }
    var hasRoom: Bool { entries.count < capacity }

    mutating func pushControl(_ line: Data) {
        entries.append(Entry(line: line, request: nil, key: nil))
    }

    /// False when the queue is full; the caller waits for room.
    mutating func pushItem(_ line: Data) -> Bool {
        guard hasRoom else { return false }
        entries.append(Entry(line: line, request: nil, key: nil))
        return true
    }

    mutating func pushEvent(_ line: Data, request: Int, key: String) -> EventAdmission {
        if let index = entries.firstIndex(where: { $0.request == request && $0.key == key }) {
            entries[index].line = line
            return .replaced
        }
        guard hasRoom else { return .full }
        entries.append(Entry(line: line, request: request, key: key))
        return .queued
    }

    /// Drops the unsent events of a subscription that ends.
    mutating func removeEvents(of request: Int) {
        entries.removeAll { $0.request == request }
    }

    mutating func pop() -> Data? {
        entries.isEmpty ? nil : entries.removeFirst().line
    }
}
