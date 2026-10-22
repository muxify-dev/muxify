import SwiftUI
import MuxifyCore

/// The choice that a Dormant or Settled Topic shows in place of the terminal: Reopen or Start Fresh, each with
/// what it will create.
struct ReopenChoiceView: View {
    let store: WorkspaceStore
    let topicID: String
    let reopen: TopicReopening
    let startFresh: TopicReopening

    var body: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                column(.reopen, reopen, title: "Reopen", summary: "The remembered Windows, Panes, Tabs and Agents.")
                column(.startFresh, startFresh, title: "Start Fresh", summary: "One shell Window in each remembered Session.")
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("Start Fresh") { store.reopenTopic(topicID, .startFresh) }
                    .accessibilityIdentifier("reopen-choice-start-fresh")
                Button("Reopen") { store.reopenTopic(topicID, .reopen) }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("reopen-choice-reopen")
            }
            .disabled(store.changingTopic)
        }
        .frame(maxWidth: 760)
    }

    private func column(_ choice: TopicReopening.Choice, _ reopening: TopicReopening, title: String, summary: String) -> some View {
        let id = choice == .reopen ? "reopen" : "start-fresh"
        return VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            Text(summary).font(.callout).foregroundStyle(.secondary)
            ForEach(reopening.sessions, id: \.name) { session in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(session.baseName).fontWeight(.semibold)
                        if let branch = session.branch {
                            Text(branch).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                    Text((session.directory as NSString).abbreviatingWithTildeInPath)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    if session.createsWorktree {
                        Text("Creates the Worktree again").font(.caption).foregroundStyle(.orange)
                    }
                    ForEach(Array(session.windows.enumerated()), id: \.offset) { _, window in
                        windowLine(window, in: session)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("\(id)-session-\(session.baseName)")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    private func windowLine(_ window: TopicReopening.Window, in session: TopicReopening.Session) -> some View {
        let tabs = window.browser.tabURLs.count
        let agents = window.agents.map(\.kind.displayName)
        let details = [Folder.local(window.directory) == Folder.local(session.directory) ? nil : (window.directory as NSString).abbreviatingWithTildeInPath,
                       window.panes.count == 1 ? nil : "\(window.panes.count) Panes",
                       tabs == 0 ? nil : tabs == 1 ? "1 Tab" : "\(tabs) Tabs",
                       agents.isEmpty ? nil : "resumes " + agents.joined(separator: ", ")].compactMap { $0 }
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: agents.isEmpty ? "terminal" : "sparkles").foregroundStyle(.tertiary)
            Text(window.name)
            Text(details.joined(separator: " · ")).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        .font(.callout)
    }
}
