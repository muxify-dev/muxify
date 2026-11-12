import AppKit
import MuxifyCore
import SwiftUI

/// An AppKit list of the Sidebar as one hosted view in the SwiftUI Sidebar: the Sessions list or the Topics list, as
/// its page of the pager or alone. It hands the list what the Sidebar's SwiftUI views read from the environment, and
/// the list draws again when one of these changes.
struct SidebarListHost<ListView: SidebarList>: NSViewRepresentable {
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

    private var environment: SidebarListEnvironment {
        SidebarListEnvironment(fontSize: fontSize, typography: typography, hints: hints, agentColors: agentColors,
                               pulses: pulses, chromeTheme: chromeTheme, wrapsCardTitles: wrapsCardTitles,
                               reduceMotion: reduceMotion, displayScale: displayScale)
    }

    func makeNSView(context: Context) -> ListView {
        ListView(store: store, environment: environment)
    }

    func updateNSView(_ view: ListView, context: Context) {
        view.environment = environment
    }
}
