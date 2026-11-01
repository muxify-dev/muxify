import Foundation

extension EnvironmentService {
    func execute(_ operation: EnvironmentOperation, client: String?) -> EnvironmentResponse {
        var phase = TopicFailure.Phase.nothingChanged
        func run(_ arguments: [String]) throws -> String {
            phase = .changesStarted
            return try server.run(arguments)
        }
        do {
            switch operation {
            case .openBrowser(let target, let urls):
                guard let window = try resolveWindow(target) else {
                    return .failed(TopicFailure(kind: .sourceUnavailable, phase: .nothingChanged,
                                               message: "no tmux Window '\(target)'"))
                }
                // Append, so a request made before the app's next poll is not overwritten.
                _ = try run(["set-option", "-wa", "-t", window, Tmux.openOption, " " + urls.joined(separator: " ")])
            case .browserSocket(let path):
                _ = try run(path.map { ["set-option", "-sq", BrowserAgentChannel.option, $0] } ?? ["set-option", "-squ", BrowserAgentChannel.option])
            case .browser(let values):
                for value in values { _ = try run(value.browser.setOptionArgs(windowID: value.window.rawValue)) }
            case .visit(_, manualRead: true): break
            case .visit(.emptyTopic(let id), manualRead: false):
                phase = .changesStarted
                try store.write { transaction in
                    guard let record = transaction.records.first(where: { $0.id == id }), record.isUnread else { return }
                    try transaction.update(id) { $0.isUnread = false }
                }
            case .visit(.panes(let window, let shown), manualRead: false):
                let snapshot = try server.snapshot()
                for pane in snapshot.panes where pane.windowID == window.rawValue && shown.contains(where: { $0.rawValue == pane.id }) {
                    _ = try run(AgentUnread.acknowledge(pane, unread: false))
                }
            case .pane(let window, let action):
                let pane = try server.run(["display-message", "-p", "-t", window.rawValue, "#{pane_id}"])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard PaneID(rawValue: pane) != nil else { throw TmuxError.notReady }
                func flag(_ direction: PaneDirection) throws -> String {
                    switch direction {
                    case .up: return "-U"
                    case .down: return "-D"
                    case .left: return "-L"
                    case .right: return "-R"
                    }
                }
                switch action {
                case .zoom: _ = try run(["resize-pane", "-Z", "-t", pane])
                case .equalize: _ = try run(["select-layout", "-E", "-t", pane])
                case .resize(let direction, let amount): _ = try run(["resize-pane", try flag(direction), "-t", pane, String(amount)])
                case .previous: _ = try run(["select-pane", "-t", window.rawValue + ".-"])
                case .next: _ = try run(["select-pane", "-t", window.rawValue + ".+"])
                case .select(let direction): _ = try run(["select-pane", try flag(direction), "-t", pane])
                case .split(let direction):
                    let flags: [String]
                    switch direction {
                    case .up: flags = ["-v", "-b"]
                    case .down: flags = ["-v"]
                    case .left: flags = ["-h", "-b"]
                    case .right: flags = ["-h"]
                    }
                    _ = try run(["split-window"] + flags + ["-t", pane, "-c", "#{pane_current_path}"])
                }
            case .paneSearch(let operation):
                switch operation {
                case .resolve(let window):
                    let output = try server.run(["display-message", "-p", "-t", window.rawValue, "#{pane_id}"])
                    guard let pane = PaneID(rawValue: output.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw TmuxError.notReady }
                    return .paneSearch(.resolved(pane))
                case .search(let step, let query, let pane, let styles, let previousTotal):
                    let output = try run(PaneSearch.commands(step, query: query, target: pane.rawValue, styles: styles))
                    guard let status = PaneSearch.Status(output) else { throw TopicEditFailure.invalidTmuxResponse }
                    let total = step == .query ? status.total : status.total ?? previousTotal
                    let text = status.found && !query.isEmpty ? try? server.run(PaneSearch.capture(status)) : nil
                    let index = text.map { PaneSearch.index(of: query, in: $0, column: status.column, total: total ?? 0) } ?? 0
                    return .paneSearch(.searched(found: status.found, total: total, index: index))
                case .cancel(let pane):
                    _ = try run(PaneSearch.cancel(pane: pane.rawValue))
                    return .paneSearch(.cancelled)
                case .isActive(let pane):
                    let output = try server.run(["display-message", "-p", "-t", pane.rawValue, "#{pane_active}"])
                    return .paneSearch(.active(output.trimmingCharacters(in: .whitespacesAndNewlines) == "1"))
                }
            case .selectPane(let pane): _ = try run(["select-pane", "-t", pane.rawValue])
            case .switchClient(let session, let window):
                guard let client else { throw TmuxError.notReady }
                _ = try run(["switch-client", "-Z", "-c", client, "-t", session.rawValue + ":" + window.rawValue])
            case .rememberWindow(let window): _ = try run(["set-option", "-gq", Tmux.lastWindowOption, window.rawValue])
            case .consumeOpen(let window): _ = try run(["set-option", "-wqu", "-t", window.rawValue, Tmux.openOption])
            case .sendText(let pane, let text): _ = try run(Tmux.sendKeysArguments(target: pane.rawValue, keys: [text], literal: true, client: client))
            case .pasteText(let pane, let text):
                let buffer = "muxify-paste-" + UUID().uuidString
                defer { _ = try? server.run(["delete-buffer", "-b", buffer]) }
                _ = try run(["set-buffer", "-b", buffer, "--", text, ";", "paste-buffer", "-d", "-p", "-b", buffer, "-t", pane.rawValue])
            case .editorWindow(let session, let after, let directory, let command):
                let place = after.map { ["-a", "-t", session.rawValue + ":" + $0.rawValue] } ?? ["-t", session.rawValue + ":"]
                let output = try run(["new-window", "-d", "-P", "-F", "#{window_id}"] + place + ["-c", directory, command])
                guard let window = WindowID(rawValue: output.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw TopicEditFailure.invalidTmuxResponse }
                return .changed(TopicChange(topicID: nil, window: window))
            case .attach(let plan):
                if topicsAvailable, plan.target == nil {
                    let snapshot = try server.snapshot()
                    if snapshot.windows.isEmpty {
                        guard plan.createSessionIfNeeded else { throw TmuxError.notReady }
                        _ = try run(["new-session", "-d", "-A", "-s", "main", "-c", plan.directory ?? NSHomeDirectory()])
                    }
                }
            case .registerClient(let marker):
                let value = [String(marker.pid), marker.tty, marker.home, marker.host, "local"].joined(separator: Tmux.separator)
                _ = try run(["set-option", "-sq", marker.option, value])
            case .removeClient(let id): _ = try run(["set-option", "-squ", EnvironmentClientMarker.option(id)])
            case .gatherGuests:
                if let failure = gatherGuests(client: client) { return .failed(failure) }
            }
            return .changed(TopicChange(topicID: nil))
        } catch { return .failed(failure(error, phase: phase)) }
    }
}
