import AppKit
import SwiftUI
import MuxifyCore

struct TopicMembershipMenu: View {
    let store: WorkspaceStore
    let source: TopicMembershipPlan.Source

    private var currentSource: TopicMembershipPlan.Source {
        (try? source.resolved(in: store.windows)) ?? source
    }

    private var isSession: Bool {
        if case .session = source { return true }
        return false
    }

    fileprivate var moveTitle: String { isSession ? "Move to Topic" : "Move Window to Topic" }

    /// The Topic membership items for the source: Move to Topic…, New Topic from this Session or Window, for a Window
    /// New Topic from this Pane, and for a Session in a Topic Remove from Topic and Remove from Topic and Kill…. They
    /// are off while a Topic change runs. The AppKit Sessions list lists them too (ADR 0074).
    @MainActor static func items(store: WorkspaceStore, source: TopicMembershipPlan.Source) -> [SidebarMenuItem] {
        let menu = TopicMembershipMenu(store: store, source: source)
        let enabled = !store.changingTopic
        var items = [
            SidebarMenuItem(title: menu.moveTitle + "…", isEnabled: enabled) { menu.openMove() },
            SidebarMenuItem(title: menu.isSession ? "New Topic from this Session" : "New Topic from this Window", isEnabled: enabled) {
                menu.openMove()
            },
        ]
        if !menu.isSession {
            items.append(SidebarMenuItem(title: "New Topic from this Pane", isEnabled: enabled) {
                store.palette.openMove(menu.currentSource.window, scope: .pane)
            })
        }
        if menu.isSession, menu.currentSource.window.topicID != nil {
            items.append(SidebarMenuItem(title: "Remove from Topic", isEnabled: enabled) { store.removeFromTopic(menu.currentSource.window) })
            items.append(SidebarMenuItem(title: "Remove from Topic and Kill…", isEnabled: enabled) {
                store.palette.begin(.confirm(PaletteConfirmation(.removeAndKill(menu.currentSource.window))))
            })
        }
        return items
    }

    var body: some View {
        SidebarMenuButtons(SidebarMenu([Self.items(store: store, source: source)]))
    }

    fileprivate func openMove() {
        store.palette.openMove(currentSource.window, scope: isSession ? .session : .window)
    }

}

extension View {
    func topicMembershipActions(store: WorkspaceStore, source: TopicMembershipPlan.Source) -> some View {
        let menu = TopicMembershipMenu(store: store, source: source)
        return accessibilityActions {
            Button(menu.moveTitle + "…") { menu.openMove() }
        }
    }
}
