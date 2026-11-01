import Foundation
import Observation

/// An App Window keeps its own lifetime, viewing facts and write barrier while sharing Environment state.
@MainActor @Observable public final class EnvironmentReader {
    public let id: UUID
    private let client: EnvironmentWatchClient?
    private var latestState: EnvironmentState?
    private var pendingWrites = 0
    private var pendingSynchronizations = 0
    private var requiredRevision: EnvironmentRevision?
    public private(set) var isRetired = false
    @ObservationIgnored public var onDisconnect: (() -> Void)?
    @ObservationIgnored private var receive: ((EnvironmentState) -> Void)?
    @ObservationIgnored private let attachmentDriver: (any EnvironmentAttachmentDriver)?
    @ObservationIgnored private var markers: [UUID: EnvironmentClientMarker] = [:]
    @ObservationIgnored private var searchPanes: Set<PaneID> = []
    @ObservationIgnored private var retireCompletions: [() -> Void] = []
    @ObservationIgnored private var didRetire = false

    public init(id: UUID = UUID(), client: EnvironmentWatchClient? = nil,
                attachmentDriver: (any EnvironmentAttachmentDriver)? = nil) {
        self.id = id
        self.client = client
        self.attachmentDriver = attachmentDriver
        client?.register(self)
    }

    public var state: EnvironmentState? { latestState }
    public var revision: EnvironmentRevision { requiredRevision ?? state?.revision ?? EnvironmentRevision(moduleID: id, number: 0) }
    public var records: TopicContents { state?.records.lastKnown ?? TopicContents() }
    public var isReady: Bool {
        guard !isRetired else { return false }
        return client?.isConnected == true && pendingWrites == 0 && pendingSynchronizations == 0 && state?.isConfirmed == true &&
            (requiredRevision == nil || state?.revision == requiredRevision || state?.revision.isAfter(requiredRevision!) == true)
    }

    public func perform(_ request: EnvironmentRequest, client tty: String? = nil,
                        sessionPaths: [SessionPath] = [], topics: Config.Topics = Config.Topics(), worktreesRoot: String? = nil,
                        preparing browsers: [EnvironmentBrowserState] = [],
                        completion: @escaping (EnvironmentWriteReceipt<EnvironmentResponse>) -> Void = { _ in }) {
        guard let client, !isRetired else {
            completion(EnvironmentWriteReceipt(revision: revision, value: .failed(TopicFailure(kind: .cancelled,
                phase: .nothingChanged, message: "The Environment reader has closed."))))
            return
        }
        if case .runtime(let operation) = request.command {
            switch operation {
            case .registerClient(let marker): markers[marker.id] = marker
            case .paneSearch(.search(_, _, let pane, _, _)): searchPanes.insert(pane)
            default: break
            }
        }
        pendingWrites += 1
        client.perform(reader: id, request: request, client: tty, sessionPaths: sessionPaths, topics: topics,
                       worktreesRoot: worktreesRoot, browsers: browsers) { [self] receipt in
            pendingWrites -= 1
            if client.isConnected { requiredRevision = receipt.revision }
            if case .runtime(.removeClient(let id)) = request.command, case .changed = receipt.value { markers[id] = nil }
            if case .runtime(.paneSearch(.cancel(let pane))) = request.command, case .paneSearch(.cancelled) = receipt.value { searchPanes.remove(pane) }
            completion(receipt)
        }
    }

    public func updateRules(settings: EnvironmentRuleSettings, viewing: EnvironmentViewing) {
        guard !isRetired else { return }
        client?.updateSettings(settings)
        client?.updateViewing(reader: id, facts: viewing)
    }

    public func read<Context>(context: @escaping () -> Context,
                              receive: @escaping (EnvironmentState, Context) -> Void) {
        guard !isRetired else { return }
        self.receive = { state in receive(state, context()) }
        _ = context()
        client?.synchronize(reader: id)
    }

    func awaitSynchronization() { pendingSynchronizations += 1 }

    func synchronized(_ revision: EnvironmentRevision) {
        pendingSynchronizations = max(0, pendingSynchronizations - 1)
        if requiredRevision == nil || revision.isAfter(requiredRevision!) { requiredRevision = revision }
    }

    func accept(_ state: EnvironmentState) {
        guard !isRetired else { return }
        guard pendingWrites == 0, pendingSynchronizations == 0 else { return }
        if let requiredRevision, !state.revision.isAfter(requiredRevision), state.revision != requiredRevision { return }
        latestState = state
        receive?(state)
    }

    func disconnected() {
        latestState = nil
        requiredRevision = nil
        pendingSynchronizations = 0
        onDisconnect?()
    }

    func restoreOwnership() {
        guard !isRetired else { return }
        for marker in markers.values { perform(EnvironmentRequest(.runtime(.registerClient(marker)))) }
        // A crash can leave copy mode active. Closing that search is safe; replaying its last step is not.
        for pane in searchPanes { perform(EnvironmentRequest(.runtime(.paneSearch(.cancel(pane))))) }
    }

    func attach(_ plan: EnvironmentAttachment, completion: @escaping (Result<Void, Error>) -> Void) {
        guard !isRetired, let attachmentDriver else { completion(.failure(TmuxError.cancelled)); return }
        attachmentDriver.attach(plan, completion: completion)
    }

    public func reloadRecords() { client?.read() }
    public func invalidateRead() { client?.synchronize(reader: id) }

    public func retire(completion: @escaping () -> Void = {}) {
        if didRetire { completion(); return }
        retireCompletions.append(completion)
        guard !isRetired else { return }
        for marker in markers.keys { perform(EnvironmentRequest(.runtime(.removeClient(marker)))) }
        for pane in searchPanes { perform(EnvironmentRequest(.runtime(.paneSearch(.cancel(pane))))) }
        isRetired = true
        receive = nil
        if let client { client.close(reader: id) { [self] in finishRetire() } }
        else { finishRetire() }
    }

    private func finishRetire() {
        didRetire = true
        let completions = retireCompletions
        retireCompletions.removeAll()
        completions.forEach { $0() }
    }
}
