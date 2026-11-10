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
