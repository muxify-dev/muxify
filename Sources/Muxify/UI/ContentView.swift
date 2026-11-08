import SwiftUI
import MuxifyCore

struct ContentView: View {
    @Bindable var store: WorkspaceStore
    let configStore: ConfigStore
    /// The width the user last dragged the Sidebar to; nil until they drag it, so its default follows the Interface font size.
    @AppStorage("sidebarWidth") private var sidebarWidth: Double?
    /// The Browser's share of the room beside the sidebar, common to all Windows.
    @AppStorage("browserShare") private var browserShare: Double = 0.45
    /// The Terminal's width when it was last shown.
    @State private var terminalWidth: Double?

    var body: some View {
        GeometryReader { proxy in
            let layout = store.panelLayout
            let showsTerminal = layout.shows(.terminal)
            let browser = layout.shows(.browser) ? store.currentBrowser : nil
            let sidebar = shownSidebarWidth
            let room = proxy.size.width - sidebar
            let browserMax = max(320, room - 360)
            let browserWidth = showsTerminal ? clamp(browserShare * room, 320, browserMax) : room
            let shownTerminalWidth: Double? = showsTerminal ? (browser == nil ? room : room - browserWidth - 1) : nil
            // Panels appear and disappear without animation, so switching
            // between Windows with and without a Browser is instant.
            HStack(spacing: 0) {
                if store.sidebarShown {
                    SidebarView(store: store, fontFamily: store.config.sidebarFontFamily)
                        .frame(width: sidebar)
                        .chrome(theme: store.theme, material: .sidebar)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("sidebar-panel")
                    PanelResizeHandle(width: sidebar, range: SidebarWidth.bounds(interfaceFontSize), edge: .leading) {
                        sidebarWidth = $0
                    }
                }
                // A hidden Terminal stays behind the Browser at its last width,
                // so tmux does not resize the client and reflow its Panes.
                ZStack(alignment: .topLeading) {
                    TerminalArea(store: store)
                        .frame(width: shownTerminalWidth ?? terminalWidth ?? room)
                        .allowsHitTesting(showsTerminal)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("terminal-panel")
                        .accessibilityHidden(!showsTerminal)
                        .quickSwitchHint(.terminal, hints: store.hintPresentation)
                        .overlay(alignment: .top) { FocusMarker(store: store, side: .terminal) }
                        // The verify checks open Find in Pane here, because they must not type ⌘F.
                        .accessibilityAction(named: "Find in Pane") { store.showFindInPane() }
                    if let browser {
                        HStack(spacing: 0) {
                            if showsTerminal {
                                Spacer(minLength: 0)
                                PanelResizeHandle(width: browserWidth, range: 320...browserMax, edge: .trailing) {
                                    browserShare = $0 / room
                                }
                            }
                            BrowserPanel(browser: browser).id(browser.windowID)
                                .frame(width: browserWidth)
                                .background(Color(nsColor: .windowBackgroundColor))
                                .overlay(alignment: .top) { FocusMarker(store: store, side: .browser) }
                                .accessibilityElement(children: .contain)
                                .accessibilityIdentifier("browser-panel")
                                // The verify checks open Find in Page here, because they must not type ⌘F.
                                .accessibilityAction(named: "Find in Page") { browser.activeTab?.showFind() }
                        }
                    }
                }
                .frame(width: room, alignment: .topLeading)
                .clipped()
                .onChange(of: shownTerminalWidth, initial: true) { _, width in
                    if let width { terminalWidth = width }
                }
            }
        }
        .overlay {
            if let gitView = store.currentGitView {
                GitViewOverlay(gitView: gitView, config: store.config.gitView, placement: .window)
            }
        }
        .overlay { CommandPaletteOverlay(palette: store.palette) }
        .overlay { PillOverlay(pills: store.pills, theme: PaletteTheme(store.theme)) }
        .overlay(alignment: .top) {
            ConfigProblemsBanner(store: store, configStore: configStore)
        }
        .padding(.top, headerHeight)
        // An overlay, so it is above everything for clicks: scroll views below
        // (sidebar list, tab strip) reach up under the title bar area and would
        // otherwise swallow clicks on the toggles.
        .overlay(alignment: .top) {
            // The sidebar's divider is 1 point wide.
            HeaderBar(store: store, keybinds: store.config.keybinds, height: headerHeight,
                      panelsLeading: store.sidebarShown ? shownSidebarWidth + 1 : 0)
        }
        .modifier(HintVerification(store: store))
        .modifier(ClientVerification(store: store))
        .ignoresSafeArea()
        // Names the window for the Window menu and Mission Control.
        .navigationTitle(store.isRemote
                         ? "\(store.environmentName) — \(store.selectedWindow?.sessionName ?? "Muxify")"
                         : store.selectedWindow?.sessionName ?? "Muxify")
        .onAppear { store.start() }
        .onChange(of: store.config.hints.holdDelay, initial: true) { _, delay in
            store.hintHold.configure(delay: delay)
        }
        .onChange(of: configStore.config.remoteEnvironments) { _, _ in store.reconcileEnvironments() }
        .overlay(alignment: .bottom) {
            if let message = store.attachmentStatus {
                Text(message).font(interfaceFontSize.font(.body))
                    .padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(16).accessibilityIdentifier("attachment-status")
            }
        }
        .environment(\.quickSwitchHints, store.hintPresentation)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
            if let window = notification.object as? NSWindow, window === store.terminalHost.window {
                store.hintHold.receive(.reset)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            store.hintHold.receive(.reset)
        }
        .environment(\.pulses, configStore.config.pulse)
        .environment(\.agentColors, configStore.config.agentColors)
        .environment(\.chromeTheme, store.theme)
        // From this App Window's own Config, its Remote Environment's when that machine has one (ADR 0010).
        .environment(\.interfaceFontSize, interfaceFontSize)
    }

    private var interfaceFontSize: InterfaceFontSize { store.config.interfaceFontSize }

    private var headerHeight: CGFloat { TitlebarMetrics.headerHeight(store.config) }

    private var shownSidebarWidth: Double {
        store.sidebarShown ? SidebarWidth.shown(dragged: sidebarWidth, size: interfaceFontSize) : 0
    }

    private func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(max(value, low), high)
    }
}

/// Session and Window navigation beside the traffic lights, with Git, Environment and panel controls on the right.
private struct HeaderBar: View {
    let store: WorkspaceStore
    let keybinds: Keybinds
    let height: CGFloat
    /// Where the Terminal and Browser start, beside the sidebar.
    let panelsLeading: CGFloat
    private let spacing: CGFloat = 2
    @Environment(\.interfaceFontSize) private var fontSize

    var body: some View {
        HStack(spacing: spacing) {
            if store.config.statusLine.enabled, let window = store.selectedWindow,
               !store.showsEmptyPage {
                let overSidebar = max(0, panelsLeading - TitlebarMetrics.trafficLightsWidth - spacing)
                Text(window.sessionName)
                    .font(fontSize.font(13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    // Keep the full name whenever it fits. The Window list can collapse first;
                    // only the room over the sidebar or the remaining titlebar width, not a fixed cap,
                    // truncates the name.
                    .layoutPriority(1)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(window.sessionName)
                    .accessibilityIdentifier("header-session-name")
                    .padding(.trailing, 8)
                    // The Window list starts at the Terminal's edge, never over the sidebar.
                    // A Session name too long for the sidebar is cut in the middle to stay over it,
                    // or, with status_line.session.wrap off, pushes the list right.
                    .frame(minWidth: overSidebar,
                           maxWidth: store.config.statusLine.wrapsSession && panelsLeading > 0 ? overSidebar : nil,
                           alignment: .leading)
                HeaderWindowSelector(store: store, current: window)
            }
            Spacer(minLength: 12)
            if let window = store.selectedWindow, !store.showsEmptyPage {
                HeaderGitButton(store: store, window: window,
                                help: help(store.currentGitView?.isOpen == true ? "Hide Git View" : "Show Git View", .toggleGitView))
                    .id("\(window.sourceID):\(window.path)")
                    .padding(.trailing, 8)
                    // Before the Window list and the Session name give way, the branch keeps its whole width up to
                    // its maximum; it is cut only when the header has no other room left.
                    .layoutPriority(2)
            }
            EnvironmentSelector(environments: store.remoteEnvironments, activeEnvironment: store.activeEnvironment,
                                isConnected: store.isConnected, hasConnectionError: store.terminalMessage != nil,
                                status: store.environmentStatus, onSelect: store.selectEnvironment)
                .accessibilityIdentifier("header-environment-selector")
                .layoutPriority(2)
            let layout = store.panelLayout
            TitlebarButton(
                systemName: layout.maximized == nil ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left",
                help: help(layout.maximized == nil ? "Maximize" : "Restore", .toggleMaximize),
                isOn: layout.maximized != nil,
                action: store.toggleMaximize
            )
            .disabled(!store.canToggleMaximize)
            .accessibilityIdentifier("toggle-maximize")
            TitlebarButton(
                systemName: "sidebar.left",
                help: help(store.sidebarShown ? "Hide Sidebar" : "Show Sidebar", .toggleSidebar),
                isOn: store.sidebarShown,
                action: store.toggleSidebar
            )
            .accessibilityIdentifier("toggle-sidebar")
            TitlebarButton(
                systemName: "terminal",
                help: help(layout.shows(.terminal) ? "Hide Terminal" : "Show Terminal", .toggleTerminal),
                isOn: layout.isToggledOn(.terminal),
                mark: mark(of: .terminal, in: layout),
                action: { store.toggle(.terminal) }
            )
            .disabled(!store.canToggle(.terminal))
            .accessibilityIdentifier("toggle-terminal")
            TitlebarButton(
                systemName: "sidebar.right",
                help: help(layout.shows(.browser) ? "Hide Browser" : "Show Browser", .toggleBrowser),
                isOn: layout.isToggledOn(.browser),
                mark: mark(of: .browser, in: layout),
                action: { store.toggle(.browser) }
            )
            .disabled(!store.canToggle(.browser))
            .accessibilityIdentifier("toggle-browser")
        }
        .padding(.leading, TitlebarMetrics.trafficLightsWidth)
        .padding(.trailing, 8)
        .frame(height: height)
        .background(WindowDragArea())
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: store.theme?.separator ?? .separatorColor))
                .frame(height: 1)
        }
        .chrome(theme: store.theme, material: .titlebar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("header-bar")
    }

    private func help(_ title: String, _ action: ConfigAction) -> String {
        keybinds.firstTrigger(for: action).map { "\(title) (\($0.symbol))" } ?? title
    }

    /// The toggles say which side is Maximized, and which side the toggles keep for Restore.
    private func mark(of side: PanelLayout.Side, in layout: PanelLayout) -> TitlebarButtonMark {
        switch layout.maximized {
        case side: .maximized
        case side.other? where layout.isToggledOn(side): .hiddenByMaximize
        default: .none
        }
    }
}

/// Lists the Config values Muxify skipped, or the syntax error that keeps
/// the last good Config, until the user closes it or the Config reloads: the
/// local Config's, and a Remote Environment's own Config's.
private struct ConfigProblemsBanner: View {
    let store: WorkspaceStore
    let configStore: ConfigStore
    @Environment(\.interfaceFontSize) private var fontSize

    private var local: [ConfigProblem] { configStore.problemsDismissed ? [] : configStore.problems }
    private var remote: [ConfigProblem] {
        store.remoteProblemsDismissed ? [] : store.remoteConfig?.problems ?? []
    }

    var body: some View {
        if !local.isEmpty || !remote.isEmpty || !store.sessionPathWarnings.isEmpty && !store.sessionPathWarningsDismissed { banner(theme: store.theme) }
    }

    private func banner(theme: TerminalTheme?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(fontSize.font(.body))
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 4) {
                Text("Problems in the Muxify Config")
                    .font(fontSize.font(.callout, weight: .semibold))
                    .accessibilityIdentifier("config-problems-title")
                if !store.sessionPathWarningsDismissed {
                    ForEach(store.sessionPathWarnings, id: \.self) { warning in
                        Text(warning).font(fontSize.font(.caption)).textSelection(.enabled)
                    }
                }
                ForEach(Array((remote + local).enumerated()), id: \.offset) { _, problem in
                    Text("\((problem.path as NSString).abbreviatingWithTildeInPath):\(problem.line): \(problem.message)")
                        .font(fontSize.font(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                HStack(spacing: 12) {
                    if !remote.isEmpty {
                        Button("Open \(store.environmentName) Config") { store.openConfig() }
                    }
                    if !local.isEmpty {
                        Button(remote.isEmpty ? "Open Config" : "Open Local Config") { configStore.openInEditor() }
                    }
                }
                .buttonStyle(.link)
                .font(fontSize.font(.caption))
            }
            Spacer(minLength: 0)
            Button {
                configStore.problemsDismissed = true
                store.remoteProblemsDismissed = true
                store.sessionPathWarningsDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(fontSize.font(10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: fontSize(18), height: fontSize(18))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close")
            .accessibilityIdentifier("config-problems-close")
        }
        .padding(10)
        // A maximum, so in a narrower App Window the banner takes the width there is.
        .frame(maxWidth: fontSize(560))
        .chrome(theme: theme, material: .popover)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(nsColor: theme?.separator ?? .separatorColor))
        )
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("config-problems")
        .padding(10)
    }
}

extension View {
    /// Header and sidebar take their background from the Ghostty theme, and
    /// their text follows its lightness, so a dark theme stays readable while
    /// macOS is in light mode. Without a theme they use the system materials.
    @ViewBuilder
    func chrome(theme: TerminalTheme?, material: NSVisualEffectView.Material) -> some View {
        if let theme {
            background(Color(nsColor: theme.chrome))
                .environment(\.colorScheme, theme.isDark ? .dark : .light)
        } else {
            background(VisualEffectBackground(material: material))
        }
    }
}

/// A short line in the middle of a side's top edge while that side has Focus.
private struct FocusMarker: View {
    let store: WorkspaceStore
    let side: PanelLayout.Side

    var body: some View {
        if store.focusMarkerSide == side {
            UnevenRoundedRectangle(bottomLeadingRadius: 2, bottomTrailingRadius: 2)
                .fill(color)
                .frame(width: 32, height: 2)
                .allowsHitTesting(false)
                .accessibilityElement()
                .accessibilityIdentifier("focus-marker-" + (side == .terminal ? "terminal" : "browser"))
        }
    }

    /// `ui.focus_marker_color` at `ui.focus_marker_opacity`, each picked for the appearance that draws it.
    private var color: Color {
        let config = store.config
        return Color(nsColor: NSColor(name: nil) { appearance in
            let color = config.focusMarkerColor?.nsColor(in: appearance) ?? .controlAccentColor
            let opacity = appearance.isDark ? config.focusMarkerOpacity.dark : config.focusMarkerOpacity.light
            return color.withAlphaComponent(opacity)
        })
    }
}

private struct TerminalArea: View {
    let store: WorkspaceStore
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.interfaceFontSize) private var fontSize

    var body: some View {
        ZStack {
            TerminalHostRepresentable(host: store.terminalHost)
            if store.surface == nil { placeholder }
            if let topic = store.topics.emptyTopic { emptyTopic(topic) }
            if store.location == .emptyTopic(.noTopic) {
                VStack(spacing: 12) {
                    Text("No Topic").font(fontSize.font(.title2))
                    Text("No Sessions outside Topics").foregroundStyle(.secondary)
                    Button("New Session") { store.newSession() }
                }
                .font(fontSize.font(.body))
                .controlSize(fontSize.systemControlSize)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
                .accessibilityIdentifier("empty-no-topic")
            }
            if store.paneFinder.isShown, store.surface != nil, !store.showsEmptyPage { findBar }
            if let gitView = store.currentGitView {
                GitViewOverlay(gitView: gitView, config: store.config.gitView, placement: .terminal)
            }
        }
    }

    /// Find in Pane floats over the Terminal's top right corner, so the Panes keep their size (ADR 0051). Its width is a
    /// maximum, so over a narrower Terminal the bar takes the width there is.
    private var findBar: some View {
        FindBar(finder: store.paneFinder, placeholder: "Find in Pane", identifier: "terminal-find",
                window: { store.terminalHost.window }, onClose: store.closeFindInPane) { _ in store.readFocusedPanel() }
        .padding(.horizontal, 10)
        .frame(maxWidth: fontSize(420))
        .frame(height: fontSize(34))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.2), radius: 4, y: 1)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal-find-bar")
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }

    private func emptyTopic(_ topic: TopicsModel.Row) -> some View {
        VStack(spacing: 12) {
            Image(systemName: offersReopen(topic) ? "clock.arrow.circlepath" : "folder.badge.plus")
                .font(fontSize.font(34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(topic.title).font(fontSize.font(.title2, weight: .semibold))
                .accessibilityIdentifier("empty-topic-title")
            if case .topic(let id) = topic.id {
                switch (store.reopening(id, .reopen), store.reopening(id, .startFresh)) {
                case (.success(let reopen)?, .success(let startFresh)?) where !reopen.sessions.isEmpty && topic.state != .empty:
                    ReopenChoiceView(store: store, topicID: id, reopen: reopen, startFresh: startFresh)
                case (.failure(let error)?, _):
                    Text("This Topic cannot be reopened. \(String(describing: error))")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("reopen-choice-failure")
                default:
                    if case .settled = topic.kind {
                        Text("This Topic remembers no Session.").foregroundStyle(.secondary)
                        Button("Reopen") { store.reopenTopic(id, .reopen) }
                            .keyboardShortcut(.defaultAction)
                            .disabled(store.changingTopic)
                            .accessibilityIdentifier("reopen-choice-reopen")
                    } else {
                        Text("Add a Session to start this Topic.").foregroundStyle(.secondary)
                        Button("Add a Session…") { store.presentAddSession(toTopic: id) }
                            .keyboardShortcut(.defaultAction)
                            .disabled(store.changingTopic)
                            .accessibilityIdentifier("empty-topic-add-session")
                    }
                }
            }
        }
        .font(fontSize.font(.body))
        .controlSize(fontSize.systemControlSize)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: store.theme?.background ?? .windowBackgroundColor))
        .environment(\.colorScheme, store.theme.map { $0.isDark ? .dark : .light } ?? systemColorScheme)
    }

    /// A Settled Topic, or a Dormant one that remembers a Session, offers Reopen; an empty open Topic offers Add a Session.
    private func offersReopen(_ topic: TopicsModel.Row) -> Bool {
        if case .settled = topic.kind { return true }
        guard topic.state == .dormant, case .topic(let id) = topic.id, case .success(let reopening)? = store.reopening(id, .reopen) else { return false }
        return !reopening.sessions.isEmpty
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(fontSize.font(34, weight: .light))
                .foregroundStyle(.tertiary)
            if let message = store.terminalMessage {
                Text(message).foregroundStyle(.secondary).textSelection(.enabled)
                if store.isRemote {
                    Text(store.environmentStatus).font(fontSize.font(.caption)).foregroundStyle(.secondary)
                    Button("Retry Connection") { store.reattach() }
                }
            } else if store.hasNoSessions {
                Text(store.serverRunning ? "No tmux Sessions" : "tmux server is not running")
                    .foregroundStyle(.secondary)
                Button("Reconnect") { store.reattach() }
                    .keyboardShortcut(.defaultAction)
            } else if store.isRemote, !store.isConnected {
                Text(store.environmentStatus).foregroundStyle(.secondary)
                ProgressView().controlSize(.small)
            } else {
                Text("Detached from tmux").foregroundStyle(.secondary)
                Button("Reattach") { store.reattach() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .font(fontSize.font(.body))
        .controlSize(fontSize.systemControlSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: store.theme?.background ?? .windowBackgroundColor))
        .environment(\.colorScheme, store.theme.map { $0.isDark ? .dark : .light } ?? systemColorScheme)
    }
}

private struct TerminalHostRepresentable: NSViewRepresentable {
    let host: TerminalHostView

    func makeNSView(context: Context) -> TerminalHostView { host }
    func updateNSView(_ nsView: TerminalHostView, context: Context) {}
}

// MARK: - Title bar controls

enum TitlebarMetrics {
    /// Room to leave on the leading edge for the traffic lights.
    static let trafficLightsWidth: CGFloat = 78

    /// The header's height: `ui.header_height`, a length at size 12, or its default, times the factor of the Interface
    /// font size (ADR 0068), so the header's controls grow with their text and never clip.
    static func headerHeight(_ config: Config) -> CGFloat {
        config.interfaceFontSize(CGFloat(config.headerHeight))
    }
}

/// What a side's toggle shows besides on and off while the Window is Maximized.
enum TitlebarButtonMark {
    case none
    /// The side shown alone: a filled accent capsule.
    case maximized
    /// On in the toggles, but hidden until Restore: dimmed.
    case hiddenByMaximize
}

struct TitlebarButton<Icon: View>: View {
    let help: String
    var isOn = false
    var mark = TitlebarButtonMark.none
    let action: () -> Void
    @ViewBuilder let icon: () -> Icon

    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.interfaceFontSize) private var fontSize

    init(help: String, isOn: Bool = false, mark: TitlebarButtonMark = .none, action: @escaping () -> Void,
         @ViewBuilder icon: @escaping () -> Icon) {
        self.help = help
        self.isOn = isOn
        self.mark = mark
        self.action = action
        self.icon = icon
    }

    var body: some View {
        Button(action: action) {
            icon()
                .font(fontSize.font(13, weight: .regular))
                .foregroundStyle(isOn || mark == .maximized ? Color.accentColor : Color.secondary)
                .opacity(opacity)
                // The button holds its symbol, so it grows with it.
                .frame(width: fontSize(28), height: fontSize(24))
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(background)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityValue(accessibilityValue)
        .actsOnFirstClick()
    }

    /// The Maximized side's toggle can't hide the only side on screen, so it is disabled, but its capsule stays clear.
    private var opacity: Double {
        switch mark {
        case .maximized: 1
        case .hiddenByMaximize: 0.45
        case .none: isEnabled ? 1 : 0.4
        }
    }

    private var background: Color {
        if mark == .maximized { return Color.accentColor.opacity(hovering ? 0.28 : 0.2) }
        return hovering ? Color.primary.opacity(0.08) : .clear
    }

    private var accessibilityValue: String {
        switch mark {
        case .maximized: "maximized"
        case .hiddenByMaximize: "hidden"
        case .none: isOn ? "on" : "off"
        }
    }
}

extension TitlebarButton where Icon == Image {
    init(systemName: String, help: String, isOn: Bool = false, mark: TitlebarButtonMark = .none, action: @escaping () -> Void) {
        self.init(help: help, isOn: isOn, mark: mark, action: action) { Image(systemName: systemName) }
    }
}

extension View {
    /// Like toolbar buttons: a click on an inactive window both activates it
    /// and presses the button.
    @ViewBuilder
    func actsOnFirstClick() -> some View {
        if #available(macOS 15.0, *) {
            allowsWindowActivationEvents(true)
        } else {
            self
        }
    }
}

/// Empty space that moves the window when dragged, since there is no title
/// bar to grab anymore.
struct WindowDragArea: View {
    var body: some View {
        if #available(macOS 15.0, *) {
            Color.clear
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
                .allowsWindowActivationEvents(true)
        } else {
            Color.clear
        }
    }
}

/// The divider beside a panel; drag it to resize the panel.
private struct PanelResizeHandle: View {
    /// The panel's width as laid out.
    let width: Double
    let range: ClosedRange<Double>
    /// Which side of the handle the resized panel is on.
    let edge: HorizontalEdge
    /// Receives the dragged width, kept within `range`.
    let resize: (Double) -> Void

    @State private var startWidth: Double?

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .overlay {
                PanelDivider(
                    onDrag: { translation in
                        let start = startWidth ?? width
                        if startWidth == nil { startWidth = start }
                        let delta = edge == .leading ? translation : -translation
                        resize(min(max(start + delta, range.lowerBound), range.upperBound))
                    },
                    onDragEnded: { startWidth = nil }
                )
                .frame(width: 1 + 2 * PanelDividerView.reach)
            }
            .zIndex(1)
    }
}

/// Native translucent material (the sidebar and title bar look).
struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}
