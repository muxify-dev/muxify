import AppKit
import MuxifyCore

/// What the Sidebar's SwiftUI views read from the environment. The Sidebar hands it to its AppKit lists, the Sessions
/// list and the Topics list, which have no environment (`SidebarListHost`).
struct SidebarListEnvironment: Equatable {
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

    /// The appearance of a list's text: the lightness of the Ghostty theme, as the SwiftUI Sidebar's colour scheme
    /// follows it. Nil for the system's.
    var appearance: NSAppearance? {
        chromeTheme.flatMap { NSAppearance(named: $0.isDark ? .darkAqua : .aqua) }
    }
}

/// An AppKit list of the Sidebar, which the SwiftUI Sidebar hosts as one view through `SidebarListHost`
/// (docs/adr/0075-muxify-leaves-swiftui-entirely-one-area-at-a-time.md). The list reads the store itself, and draws
/// again when a value from the Sidebar changes.
@MainActor protocol SidebarList: NSView {
    init(store: WorkspaceStore, environment: SidebarListEnvironment)
    /// The values from the SwiftUI Sidebar.
    var environment: SidebarListEnvironment { get set }
}
