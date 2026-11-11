import AppKit
import MuxifyCore
import SwiftUI

/// The two versions of the Sidebar's Sessions list while the list moves from SwiftUI to AppKit (ADR 0074).
enum SessionsListVersion: String {
    case swiftui, appkit

    /// The user default that chooses the version: true is the AppKit list; missing or false is the SwiftUI list.
    /// It is not a Config key, because it goes away with the SwiftUI list.
    static let defaultsKey = "sessionsListAppKit"

    #if DEBUG
    /// The version in the App Window, for the verify driver: the AppKit list when the window holds one, also as the
    /// Sidebar page that does not show.
    static func shown(in window: NSWindow) -> SessionsListVersion {
        func holdsList(_ view: NSView?) -> Bool {
            guard let view else { return false }
            return view is SessionsListView || view.subviews.contains(where: holdsList)
        }
        return holdsList(window.contentView) ? .appkit : .swiftui
    }
    #endif
}

/// What the Sidebar's SwiftUI views read from the environment. The Sidebar hands it to the AppKit Sessions list,
/// which has no environment.
struct SessionsListEnvironment: Equatable {
    var fontSize = InterfaceFontSize()
    var typography = SidebarTypography()
    var hints = HintPresentation.hidden
    var agentColors = AgentColors()
    /// `ui.pulse` in the Config.
    var pulses = true
    /// The Ghostty theme of the chrome, nil for the system materials.
    var chromeTheme: TerminalTheme?
    var wrapsCardTitles = true
    var reduceMotion = false
    /// The pixels in a point on the display. A length is whole pixels, as SwiftUI lays its views out.
    var displayScale: CGFloat = 2
}

/// What the Sessions list says in its middle while tmux has no Window, for both versions of the list (ADR 0074): in the
/// font of a Window row's title, in the secondary text colour.
@MainActor enum SessionsListEmptyState {
    static let role = SidebarTypography.Role.title

    /// "No windows" while the tmux server runs, "No tmux server" when it does not. Nil while tmux has a Window.
    static func text(_ store: WorkspaceStore) -> String? {
        guard store.windows.isEmpty else { return nil }
        return store.serverRunning ? "No windows" : "No tmux server"
    }
}

/// A press on the header of a Session card, for both versions of the Sessions list (ADR 0074). As on a Topic card: on
/// the card of the Location's Session it opens or closes the card; on another card it goes to that Session, whose
/// card then opens.
@MainActor struct SessionCardPress {
    let store: WorkspaceStore
    let session: SessionGroup

    /// The card holds the Location's Window.
    var holdsSelection: Bool { session.windows.contains { $0.id == store.selectedWindowID } }

    func callAsFunction() {
        guard !holdsSelection else { return toggle() }
        withAnimation(.cardOpens) { _ = store.openSessionCards.insert(session.name) }
        store.goToSession(session.id)
    }

    private func toggle() {
        withAnimation(.cardOpens) {
            if store.openSessionCards.remove(session.name) == nil { store.openSessionCards.insert(session.name) }
        }
    }
}

/// The context menus of the Sessions list and the named accessibility actions they give, for both versions of the list
/// (ADR 0074). Each item starts what it names; Rename Window…, the Move items and the two Kill items open their step in
/// the palette's view (ADR 0014).
@MainActor enum SessionsListMenus {
    /// The menu of a Session card, which is also the card's named actions: Go to Session, the Topic membership items
    /// for a Session, and the lock item.
    static func card(_ session: SessionGroup, store: WorkspaceStore) -> SidebarMenu {
        let lock = lock(session, store: store)
        guard let window = session.windows.first else { return SidebarMenu([[goTo(session, store: store)] + lock]) }
        return SidebarMenu([[goTo(session, store: store)], TopicMembershipMenu.items(store: store, source: .session(window)) + lock])
    }

    /// The named actions of a Session card's header: Go to Session and the lock item.
    static func header(_ session: SessionGroup, store: WorkspaceStore) -> SidebarMenu {
        SidebarMenu([[goTo(session, store: store)] + lock(session, store: store)])
    }

    /// The menu of a Window row: the Topic membership items for a Window, Rename Window… and New Window in the
    /// Session, Copy Path and Reveal in Finder, and Kill Window…. Reveal in Finder is off in a Remote Environment.
    static func window(_ window: TmuxWindow, store: WorkspaceStore) -> SidebarMenu {
        SidebarMenu([
            TopicMembershipMenu.items(store: store, source: .window(window)),
            [SidebarMenuItem(title: "Rename Window…") { store.palette.begin(.text(.renameWindow(window)), text: window.name) },
             SidebarMenuItem(title: "New Window in \(window.sessionName)") { store.newWindow(beside: window) }],
            [SidebarMenuItem(title: "Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(window.path, forType: .string)
             },
             SidebarMenuItem(title: "Reveal in Finder", isEnabled: !store.isRemote) {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: window.path)
             }],
            [SidebarMenuItem(title: "Kill Window…", isDestructive: true) {
                store.palette.begin(.confirm(PaletteConfirmation(.killWindow(window))))
            }],
        ])
    }

    private static func goTo(_ session: SessionGroup, store: WorkspaceStore) -> SidebarMenuItem {
        SidebarMenuItem(title: "Go to Session") { store.goToSession(session.id) }
    }

    /// One of Lock Session and Unlock Session, or with `topics.in_play` one of Make a Guest and Bench, because a Lock
    /// is then a Guest. None for a Session that cannot be Locked: only a No Topic Session of a Local App Window can.
    /// It is off while a Topic change runs.
    private static func lock(_ session: SessionGroup, store: WorkspaceStore) -> [SidebarMenuItem] {
        let card = WorkspaceStore.GuestCard.session(session.id)
        if let guest = store.guestState(of: card) {
            return [SidebarMenuItem(title: guest ? "Bench" : "Make a Guest", isEnabled: !store.changingTopic,
                                    identifier: guest ? "bench" : "make-guest") {
                if guest { store.bench(card) } else { store.makeGuest(card) }
            }]
        }
        if let locked = store.lockState(ofSession: session.id) {
            return [SidebarMenuItem(title: locked ? "Unlock Session" : "Lock Session", isEnabled: !store.changingTopic) {
                store.setLock(ofSession: session.id, !locked)
            }]
        }
        return []
    }
}

/// The AppKit Sessions list as one hosted view in the SwiftUI Sidebar: the Sessions page of the pager, or alone when
/// Topics are off.
struct SessionsListHost: NSViewRepresentable {
    let store: WorkspaceStore
    @Environment(\.interfaceFontSize) private var fontSize
    @Environment(\.sidebarTypography) private var typography
    @Environment(\.quickSwitchHints) private var hints
    @Environment(\.agentColors) private var agentColors
    @Environment(\.pulses) private var pulses
    @Environment(\.chromeTheme) private var chromeTheme
    @Environment(\.wrapsCardTitles) private var wrapsCardTitles
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale

    private var environment: SessionsListEnvironment {
        SessionsListEnvironment(fontSize: fontSize, typography: typography, hints: hints, agentColors: agentColors,
                                pulses: pulses, chromeTheme: chromeTheme, wrapsCardTitles: wrapsCardTitles,
                                reduceMotion: reduceMotion, displayScale: displayScale)
    }

    func makeNSView(context: Context) -> SessionsListView {
        SessionsListView(store: store, environment: environment)
    }

    func updateNSView(_ view: SessionsListView, context: Context) {
        view.environment = environment
    }
}
