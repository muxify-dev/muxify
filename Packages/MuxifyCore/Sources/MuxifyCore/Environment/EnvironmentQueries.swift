import Foundation

public struct EnvironmentQueries: Sendable {
    private let answer: @Sendable (EnvironmentQuery) async -> EnvironmentQueryResponse

    public init(answer: @escaping @Sendable (EnvironmentQuery) async -> EnvironmentQueryResponse) {
        self.answer = answer
    }

    public func inventory() async -> Result<TmuxSnapshot, TopicFailure> {
        switch await answer(.inventory) {
        case .inventory(let value): return .success(value)
        case .failed(let error): return .failure(error)
        default: return .failure(Self.invalidResponse)
        }
    }

    public func settleChoices(for target: EnvironmentTarget) async -> Result<[TopicSettleSession], TopicFailure> {
        switch await answer(.settle(target)) {
        case .settle(let value): return .success(value)
        case .failed(let error): return .failure(error)
        default: return .failure(Self.invalidResponse)
        }
    }

    public func forgetChoices(for target: EnvironmentTarget) async -> Result<TopicForgetChoices, TopicFailure> {
        switch await answer(.forget(target)) {
        case .forget(let value): return .success(value)
        case .failed(let error): return .failure(error)
        default: return .failure(Self.invalidResponse)
        }
    }

    public func worktreeStarts(from path: String) async -> Result<[WorktreeStartChoice], TopicFailure> {
        switch await answer(.worktreeStarts(path)) {
        case .worktreeStarts(let value): return .success(value)
        case .failed(let error): return .failure(error)
        default: return .failure(Self.invalidResponse)
        }
    }

    public func muxifyWorktreeStarts(from path: String) async -> Result<[WorktreeStartChoice], TopicFailure> {
        switch await answer(.muxifyWorktreeStarts(path)) {
        case .worktreeStarts(let value): return .success(value)
        case .failed(let error): return .failure(error)
        default: return .failure(Self.invalidResponse)
        }
    }

    public func removeAndKillWorktree(of target: EnvironmentTarget) async -> Result<TopicForgetChoices.Worktree?, TopicFailure> {
        switch await answer(.removeWorktree(target)) {
        case .removeWorktree(let value): return .success(value)
        case .failed(let error): return .failure(error)
        default: return .failure(Self.invalidResponse)
        }
    }

    public func browserAvailability(pane: String?) async -> Result<EnvironmentBrowserAvailability, TopicFailure> {
        switch await answer(.browserAvailability(pane: pane)) {
        case .browserAvailability(let value): return .success(value)
        case .failed(let error): return .failure(error)
        default: return .failure(Self.invalidResponse)
        }
    }

    /// The socket of the app that serves this server's Browsers, or nil when no app serves them.
    public func browserSocket() async -> Result<String?, TopicFailure> {
        switch await answer(.browserSocket) {
        case .browserSocket(let value): return .success(value)
        case .failed(let error): return .failure(error)
        default: return .failure(Self.invalidResponse)
        }
    }

    public func resolveWindow(_ target: String) async -> Result<String?, TopicFailure> {
        switch await answer(.resolveWindow(target)) {
        case .window(let value): return .success(value)
        case .failed(let error): return .failure(error)
        default: return .failure(Self.invalidResponse)
        }
    }

    public func sessionExists(_ name: String) async -> Result<Bool, TopicFailure> {
        switch await answer(.sessionExists(name)) {
        case .sessionExists(let value): return .success(value)
        case .failed(let error): return .failure(error)
        default: return .failure(Self.invalidResponse)
        }
    }

    private static var invalidResponse: TopicFailure {
        TopicFailure(kind: .cancelled, phase: .nothingChanged, message: "The Environment query failed.")
    }
}

extension EnvironmentService {
    func resolveWindow(_ target: String) throws -> String? {
        // list-panes checks that the target exists. display-message succeeds for a missing Window.
        do {
            let output = try server.run(["list-panes", "-t", target, "-F", "#{window_id}"])
            guard let window = output.components(separatedBy: "\n").first, !window.isEmpty else { return nil }
            return window
        } catch TmuxError.failed { return nil }
    }

    func answer(_ query: EnvironmentQuery) -> EnvironmentQueryResponse {
        if !topicsAvailable {
            switch query {
            case .inventory, .browserAvailability, .resolveWindow, .browserSocket, .sessionExists, .muxifyWorktreeStarts: break
            default: return .failed(TopicFailure(kind: .unsupported, phase: .nothingChanged,
                                           message: "This Environment does not support Topics."))
            }
        }
        switch query {
        case .browserAvailability(let pane):
            do { return .browserAvailability(try EnvironmentBrowserAvailability.check(pane: pane, server: server)) }
            catch { return .failed(failure(error, phase: .nothingChanged)) }
        case .browserSocket:
            do {
                let path = try server.run(["show-options", "-sqv", BrowserAgentChannel.option]).trimmingCharacters(in: .newlines)
                return .browserSocket(path.isEmpty ? nil : path)
            } catch { return .failed(failure(error, phase: .nothingChanged)) }
        case .resolveWindow(let target):
            do { return .window(try resolveWindow(target)) }
            catch { return .failed(failure(error, phase: .nothingChanged)) }
        case .sessionExists(let name):
            do {
                _ = try server.run(["has-session", "-t", "=" + name])
                return .sessionExists(true)
            } catch TmuxError.failed { return .sessionExists(false) }
            catch { return .failed(failure(error, phase: .nothingChanged)) }
        case .inventory:
            do { return .inventory(try server.snapshot()) }
            catch { return .failed(failure(error, phase: .nothingChanged)) }
        case .settle(let target):
            return settleChoices(for: target).map(EnvironmentQueryResponse.settle).response
        case .forget(let target):
            return forgetChoices(for: target).map(EnvironmentQueryResponse.forget).response
        case .worktreeStarts(let path):
            return worktreeStarts(from: path).map(EnvironmentQueryResponse.worktreeStarts).response
        case .muxifyWorktreeStarts(let path):
            do { return .worktreeStarts(try WorktreeStartChoice.read(from: path, scripts: scripts)) }
            catch { return .failed(failure(error, phase: .nothingChanged)) }
        case .removeWorktree(let target):
            return removeAndKillWorktree(of: target).map(EnvironmentQueryResponse.removeWorktree).response
        }
    }
}

private extension Result where Success == EnvironmentQueryResponse, Failure == TopicFailure {
    var response: EnvironmentQueryResponse {
        switch self {
        case .success(let value): return value
        case .failure(let error): return .failed(error)
        }
    }
}
