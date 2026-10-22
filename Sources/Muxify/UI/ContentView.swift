import SwiftUI
import MuxifyCore

struct ContentView: View {
    @Bindable var store: WorkspaceStore
    let configStore: ConfigStore
    @AppStorage("sidebarWidth") private var sidebarWidth: Double = 260
    /// The Browser's share of the room beside the sidebar, common to all Windows.
    @AppStorage("browserShare") private var browserShare: Double = 0.45
    /// The Terminal's width when it was last shown.
    @State private var terminalWidth: Double?

    var body: some View {
        GeometryReader { proxy in
            let layout = store.panelLayout
            let showsTerminal = layout.shows(.terminal)
            let browser = layout.shows(.browser) ? store.currentBrowser : nil
            let sidebar = store.sidebarShown ? clamp(sidebarWidth, 180, 420) : 0
            let room = proxy.size.width - sidebar
            let browserMax = max(320, room - 360)
            let browserWidth = showsTerminal ? clamp(browserShare * room, 320, browserMax) : room
            let shownTerminalWidth: Double? = showsTerminal ? (browser == nil ? room : room - browserWidth - 1) : nil
            // Panels appear and disappear without animation, so switching
            // between Windows with and without a Browser is instant.
            HStack(spacing: 0) {
                if store.sidebarShown {
                    SidebarView(store: store, typography: store.config.sidebarTypography)
                        .frame(width: sidebar)
                        .chrome(theme: store.theme, material: .sidebar)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("sidebar-panel")
                    PanelResizeHandle(width: sidebar, range: 180...420, edge: .leading) { sidebarWidth = $0 }
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
        .overlay(alignment: .top) {
            ConfigProblemsBanner(store: store, configStore: configStore)
        }
        .padding(.top, headerHeight)
        // An overlay, so it is above everything for clicks: scroll views below
        // (sidebar list, tab strip) reach up under the title bar area and would
        // otherwise swallow clicks on the toggles.
        .overlay(alignment: .top) {
            HeaderBar(store: store, keybinds: store.config.keybinds, height: headerHeight)
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
            if let message = store.wakeToast {
                Text(message).padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(16).accessibilityIdentifier("wake-toast")
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

    }

    private var headerHeight: CGFloat { CGFloat(store.config.headerHeight) }

    private func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(max(value, low), high)
    }
}

/// Session and Window navigation beside the traffic lights, with Git, Environment and panel controls on the right.
private struct HeaderBar: View {
    let store: WorkspaceStore
    let keybinds: Keybinds
    let height: CGFloat

    var body: some View {
        HStack(spacing: 2) {
            if store.config.statusLineHeader, let window = store.selectedWindow,
               store.topics.emptyTopic == nil, !store.topicSelection.showsEmptyNoTopic {
                Text(window.sessionName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    // Keep the full name whenever it fits. The Window list can collapse first;
                    // only the remaining titlebar width, not a fixed cap, truncates the name.
                    .layoutPriority(1)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(window.sessionName)
                    .accessibilityIdentifier("header-session-name")
                HeaderWindowSelector(store: store, current: window)
                    .padding(.leading, 8)
            }
            Spacer(minLength: 12)
            if let window = store.selectedWindow, store.topics.emptyTopic == nil, !store.topicSelection.showsEmptyNoTopic {
                HeaderGitButton(store: store, window: window,
                                help: help(store.currentGitView?.isOpen == true ? "Hide Git View" : "Show Git View", .toggleGitView))
                    .id("\(window.sourceID):\(window.path)")
                    .padding(.trailing, 8)
            }
            EnvironmentSelector(environments: store.remoteEnvironments, activeEnvironment: store.activeEnvironment,
                                isConnected: store.isConnected, hasConnectionError: store.terminalMessage != nil,
                                status: store.environmentStatus, onSelect: store.selectEnvironment)
                .accessibilityIdentifier("header-environment-selector")
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
                isOn: layout.shows(.terminal),
                action: { store.toggle(.terminal) }
            )
            .disabled(!store.canToggle(.terminal))
            .accessibilityIdentifier("toggle-terminal")
            TitlebarButton(
                systemName: "sidebar.right",
                help: help(layout.shows(.browser) ? "Hide Browser" : "Show Browser", .toggleBrowser),
                isOn: layout.shows(.browser),
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
    }

    private func help(_ title: String, _ action: ConfigAction) -> String {
        keybinds.firstTrigger(for: action).map { "\(title) (\($0.symbol))" } ?? title
    }
}

/// Lists the Config values Muxify skipped, or the syntax error that keeps
/// the last good Config, until the user closes it or the Config reloads: the
/// local Config's, and a Remote Environment's own Config's.
private struct ConfigProblemsBanner: View {
    let store: WorkspaceStore
    let configStore: ConfigStore

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
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 4) {
                Text("Problems in the Muxify Config")
                    .font(.callout.weight(.semibold))
                if !store.sessionPathWarningsDismissed {
                    ForEach(store.sessionPathWarnings, id: \.self) { warning in
                        Text(warning).font(.caption).textSelection(.enabled)
                    }
                }
                ForEach(Array((remote + local).enumerated()), id: \.offset) { _, problem in
                    Text("\((problem.path as NSString).abbreviatingWithTildeInPath):\(problem.line): \(problem.message)")
                        .font(.caption.monospaced())
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
                .font(.caption)
            }
            Spacer(minLength: 0)
            Button {
                configStore.problemsDismissed = true
                store.remoteProblemsDismissed = true
                store.sessionPathWarningsDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(10)
        .frame(maxWidth: 560)
        .chrome(theme: theme, material: .popover)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(nsColor: theme?.separator ?? .separatorColor))
        )
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
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

private struct TerminalArea: View {
    let store: WorkspaceStore
    @Environment(\.colorScheme) private var systemColorScheme

    var body: some View {
        ZStack {
            TerminalHostRepresentable(host: store.terminalHost)
            if store.surface == nil { placeholder }
            if let topic = store.topics.emptyTopic { emptyTopic(topic) }
            if store.topicSelection.showsEmptyNoTopic {
                VStack(spacing: 12) {
                    Text("No Topic").font(.title2)
                    Text("No Sessions outside Topics").foregroundStyle(.secondary)
                    Button("New Session") { store.newSession() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
                .accessibilityIdentifier("empty-no-topic")
            }
            if let gitView = store.currentGitView {
                GitViewOverlay(gitView: gitView, config: store.config.gitView, placement: .terminal)
            }
        }
    }

    private func emptyTopic(_ topic: TopicsModel.Row) -> some View {
        VStack(spacing: 12) {
            Image(systemName: offersReopen(topic) ? "clock.arrow.circlepath" : "folder.badge.plus")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(topic.title).font(.title2.weight(.semibold))
                .accessibilityIdentifier("empty-topic-title")
            if case .topic(let id) = topic.id {
                switch (store.reopening(id, .reopen), store.reopening(id, .startFresh)) {
                case (.success(let reopen)?, .success(let startFresh)?) where !reopen.sessions.isEmpty && topic.remembersSessions:
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
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: store.theme?.background ?? .windowBackgroundColor))
        .environment(\.colorScheme, store.theme.map { $0.isDark ? .dark : .light } ?? systemColorScheme)
    }

    /// A Settled Topic, or a Dormant one that remembers a Session, offers Reopen; an empty open Topic offers Add a Session.
    private func offersReopen(_ topic: TopicsModel.Row) -> Bool {
        if case .settled = topic.kind { return true }
        guard topic.remembersSessions, case .topic(let id) = topic.id, case .success(let reopening)? = store.reopening(id, .reopen) else { return false }
        return !reopening.sessions.isEmpty
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            if let message = store.terminalMessage {
                Text(message).foregroundStyle(.secondary).textSelection(.enabled)
                if store.isRemote {
                    Text(store.environmentStatus).font(.caption).foregroundStyle(.secondary)
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
}

struct TitlebarButton<Icon: View>: View {
    let help: String
    var isOn = false
    let action: () -> Void
    @ViewBuilder let icon: () -> Icon

    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    init(help: String, isOn: Bool = false, action: @escaping () -> Void, @ViewBuilder icon: @escaping () -> Icon) {
        self.help = help
        self.isOn = isOn
        self.action = action
        self.icon = icon
    }

    var body: some View {
        Button(action: action) {
            icon()
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                .opacity(isEnabled ? 1 : 0.4)
                .frame(width: 28, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovering ? Color.primary.opacity(0.08) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityValue(isOn ? "on" : "off")
        .actsOnFirstClick()
    }
}

extension TitlebarButton where Icon == Image {
    init(systemName: String, help: String, isOn: Bool = false, action: @escaping () -> Void) {
        self.init(help: help, isOn: isOn, action: action) { Image(systemName: systemName) }
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
