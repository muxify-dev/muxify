import Foundation

/// The `topic` subscriptions of one Host Server (ADR 0093): each pushes one Topic's detail, as `environment { show }`
/// answers it, keyed `topic <id>`. The first item is the current state. Each change that the `environment` publisher
/// reports reads the subscribed Topics again, one `show` per Topic however many subscribe to it, and a subscription
/// gets an item only when the encoded detail differs from the one it got last. A Topic that is gone is `null`.
///
/// Reads run one at a time: changes that come while one runs make one read after it.
final class HostTopicDetails: @unchecked Sendable {
    /// What a read of one Topic found.
    enum Read {
        /// The answer of `environment { show }` for the Topic.
        case shown(EnvironmentResponse)
        /// No open Topic has the id.
        case gone
    }

    /// Reads the Topics with these ids. A Topic that could not be read, such as when the records do not open, has no
    /// entry, and its subscriptions keep what they got last.
    private let read: @Sendable (Set<String>) async -> [String: Read]
    private let queue = DispatchQueue(label: "dev.muxify.host-server.topic-detail")

    // Only `queue` touches these.
    private var subscribers: [Int: Subscriber] = [:]
    private var reading = false
    /// The changes heard, and those that a finished read covers: a read covers every change heard before it started.
    private var heard = 0
    private var covered = 0
    private var waiters: [(change: Int, resume: () -> Void)] = []
    private var stopped = false

    private struct Subscriber {
        let request: ProtocolIncomingRequest
        let topic: String
        /// The encoded item sent last; nil before the first.
        var sent: Data?
    }

    init(read: @escaping @Sendable (Set<String>) async -> [String: Read]) {
        self.read = read
    }

    func subscribe(_ request: ProtocolIncomingRequest, topic: String) {
        let id = request.id
        queue.async { [self] in
            guard !request.isCancelled, !stopped else { return }
            subscribers[id] = Subscriber(request: request, topic: topic)
            hear()
        }
        request.onCancel { self.queue.async { self.subscribers[id] = nil } }
    }

    /// Something that a Topic's detail shows may have changed: the subscribed Topics are read again.
    func changed() {
        queue.async { [self] in
            guard !subscribers.isEmpty else { return }
            hear()
        }
    }

    /// Returns once a read that covers every change heard before has sent its items.
    func caughtUp() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if covered >= heard || stopped { return continuation.resume() }
                waiters.append((heard, { continuation.resume() }))
            }
        }
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            subscribers = [:]
            covered = heard
            resumeWaiters()
        }
    }

    // MARK: - On `queue`

    private func hear() {
        heard += 1
        readIfIdle()
    }

    private func readIfIdle() {
        guard !reading, covered < heard else { return }
        let change = heard
        let topics = Set(subscribers.values.map(\.topic))
        guard !topics.isEmpty, !stopped else {
            covered = change
            return resumeWaiters()
        }
        reading = true
        let read = read
        Task {
            let found = await read(topics)
            queue.async { [self] in
                reading = false
                send(found)
                covered = change
                resumeWaiters()
                readIfIdle()
            }
        }
    }

    private func send(_ found: [String: Read]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        for id in subscribers.keys.sorted() {
            guard var subscriber = subscribers[id], let read = found[subscriber.topic] else { continue }
            let item: TopicDetailItem
            switch read {
            case .shown(let response): item = response
            case .gone: item = nil
            }
            guard let encoded = try? encoder.encode(item), encoded != subscriber.sent else { continue }
            guard subscriber.request.sendEvent(item, key: "topic \(subscriber.topic)") else {
                subscribers[id] = nil
                continue
            }
            subscriber.sent = encoded
            subscribers[id] = subscriber
        }
    }

    private func resumeWaiters() {
        let ready = waiters.filter { $0.change <= covered }
        waiters.removeAll { $0.change <= covered }
        ready.forEach { $0.resume() }
    }
}
