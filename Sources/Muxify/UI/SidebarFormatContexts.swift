import Foundation
import MuxifyCore

struct SidebarFormatContexts {
    typealias Context = SidebarFormat.Context
    typealias Variable = SidebarFormat.Variable

    var topics: [TopicGroupID: Context] = [:]
    var sessions: [String: Context] = [:]
    var windows: [String: Context] = [:]
    var panes: [String: Context] = [:]

    init(model: TopicsModel, windows: [TmuxWindow], panes: [TmuxPane], agents: [Agent],
         branches: TopicBranches, records: [TopicRecord], sessionPaths: [SessionPath], tabCounts: [String: Int]) {
        let panesByWindow = Dictionary(grouping: panes, by: \.windowID)
        let agentsByPane = Dictionary(agents.map { ($0.paneID, $0) }, uniquingKeysWith: { first, _ in first })
        let recordsByID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func topicTags(_ shown: [ShownTag]) -> String { shown.map(\.tag.description).joined(separator: " ") }
        func counts(_ agents: [Agent]) -> [Variable: String] {
            [.agent_count: String(agents.count), .agents_working: String(agents.filter { $0.status == .working }.count),
             .agents_unread: String(agents.filter(\.unread).count)]
        }
        func merged(_ base: [Variable: String], _ extra: [Variable: String]) -> [Variable: String] {
            base.merging(extra, uniquingKeysWith: { _, new in new })
        }
        for (sessionID, members) in Dictionary(grouping: windows, by: \.sessionID) {
            guard let first = members.first else { continue }
            let record = first.isRemote ? nil : first.topicID.flatMap { recordsByID[$0] }
            let topicSession = model.topicSessions[sessionID]
            let sessionAgents = agents.filter { $0.sessionID == sessionID }
            let sessionValues = merged(counts(sessionAgents), [
                .session_name: first.sessionName,
                .session_base_name: topicSession?.baseName ?? SessionNaming.base(of: first.sessionName, topic: record),
                .branch: first.isRemote ? "" : branches[.local(first.sessionPath)] ?? "",
                .topic_title: first.isRemote ? "" : first.topicID.flatMap { model.titles[$0] } ?? "",
                .topic_tags: topicTags(record.map { model.tags?.shown($0.tags) ?? [] } ?? []),
                .window_count: String(members.count),
                .pane_count: String(members.reduce(0) { $0 + $1.paneCount }),
            ])
            var windowContexts: [Context] = []
            var paneContexts: [Context] = []
            for window in members {
                let windowPanes = (panesByWindow[window.id] ?? []).sorted { $0.index < $1.index }
                let windowAgents = windowPanes.compactMap { agentsByPane[$0.id] }
                let firstAgent = windowAgents.first
                let windowValues = merged(merged(sessionValues, counts(windowAgents)), [
                    .window_index: String(window.index), .window_name: window.name, .window_title: window.displayTitle,
                    .window_panes: String(window.paneCount), .window_zoomed_flag: window.isZoomed ? "1" : "0",
                    .tab_count: String(tabCounts[window.id] ?? 0),
                    .pane_current_command: window.command, .pane_current_path: window.path,
                    .agent_kind: firstAgent?.kind.displayName ?? "", .agent_status: firstAgent?.status?.rawValue ?? "",
                ])
                let children = windowPanes.map { pane -> Context in
                    let agent = agentsByPane[pane.id]
                    let values = merged(windowValues, [
                        .pane_index: String(pane.index), .pane_label: pane.label, .pane_title: pane.title,
                        .pane_current_command: pane.command, .pane_current_path: pane.path,
                        .pane_active_flag: pane.isActive ? "1" : "0",
                        .branch: window.isRemote ? "" : branches[.local(pane.path)] ?? "",
                        .agent_kind: agent?.kind.displayName ?? "", .agent_status: agent?.status?.rawValue ?? "",
                        .agent_unread_flag: agent?.unread == true ? "1" : "0",
                        .agent_group: model.agentGroups[pane.id] ?? "",
                    ])
                    let context = Context(values: values)
                    self.panes[pane.id] = context
                    return context
                }
                let context = Context(values: windowValues, loops: [.panes: children])
                self.windows[window.id] = context
                windowContexts.append(context)
                paneContexts += children
            }
            sessions[sessionID] = Context(values: sessionValues, loops: [.windows: windowContexts, .panes: paneContexts])
        }
        for topic in model.rows + model.snoozedRows + model.groups.filter({ $0.kind == .settled }).flatMap(\.topics) {
            // A Locked card shows its Session's Formats.
            guard case .topic = topic.id else { continue }
            let children = topic.sessions.compactMap { sessions[$0.id.session] }
            let windowIDs = Set(topic.sessions.flatMap(\.windows).map(\.id))
            let topicAgents = agents.filter { windowIDs.contains($0.windowID) }
            let allWindows = children.flatMap { $0.loops[.windows] ?? [] }
            let allPanes = children.flatMap { $0.loops[.panes] ?? [] }
            let values = merged(counts(topicAgents), [
                .topic_title: topic.title, .topic_pinned_flag: topic.isPinned ? "1" : "0",
                .topic_dormant_flag: topic.isDormant ? "1" : "0", .session_count: String(children.count),
                .window_count: String(allWindows.count), .pane_count: String(allPanes.count),
                .topic_tags: topicTags(topic.tags), .tag_count: String(topic.tags.count),
            ])
            let tags = topic.tags.map { Context(values: merged(values, [.tag: $0.tag.name])) }
            topics[topic.id] = Context(values: values, loops: [.sessions: children, .windows: allWindows, .panes: allPanes, .tags: tags])
        }
    }
}
