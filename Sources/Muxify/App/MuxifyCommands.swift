import SwiftUI
import MuxifyCore

/// App-wide menus act on the focused App Window, never on the last workspace
/// to start a terminal or reconnect.
@MainActor struct MuxifyCommands: Commands {
    let windows: AppWindows
    private var store: WorkspaceStore? { windows.focusedStore }
    private var configStore: ConfigStore { windows.configStore }
    /// The focused App Window's, which may come from its Remote Environment.
    private var config: Config { store?.config ?? configStore.config }
    private var keybinds: Keybinds { config.keybinds }
    private var remoteActionDisabled: Bool {
        guard let store else { return true }
        return store.isRemote && !store.isConnected
    }

    private var activeTabHasPage: Bool { store?.currentBrowser?.activeTab?.hasPage == true }

    /// Topics live on this Mac, so only a Local App Window offers them.
    private var topicsAvailable: Bool {
        guard let store else { return false }
        return !store.isRemote && !store.changingTopic
    }

    var body: some Commands {
        CommandGroup(replacing: .sidebar) {
            // The key monitor acts before the menu; the shortcut is shown here.
            Button(store?.sidebarShown == true ? "Hide Sidebar" : "Show Sidebar") { store?.toggleSidebar() }
                .keyboardShortcut(keybinds.firstTrigger(for: .toggleSidebar)?.shortcut)
                .disabled(store == nil)
            Toggle("Show Sessions", isOn: Binding(get: { store?.sessionsVisible ?? true }, set: { store?.sessionsVisible = $0 }))
                .disabled(store == nil)
            Toggle("Show Agents", isOn: Binding(get: { store?.agentsVisible ?? true }, set: { store?.agentsVisible = $0 }))
                .disabled(store.map { config.sidebar.agents[$0.shownSidebarMode] != nil } ?? true)
            Toggle("Show Panes", isOn: Binding(get: { store?.panesVisible ?? false }, set: { store?.panesVisible = $0 }))
                .disabled(store == nil || config.sidebar.panes != nil)
            Button(store?.currentGitView?.isOpen == true ? "Hide Git View" : "Show Git View") { store?.toggleGitView() }
                .keyboardShortcut(keybinds.firstTrigger(for: .toggleGitView)?.shortcut)
                .disabled(store?.selectedWindow == nil)
            Divider()
            // The Command Palettes; their keybindings act in the key monitor.
            ForEach(config.commandPalettes) { palette in
                Button(palette.name) { store?.palette.toggle(palette) }
                    .keyboardShortcut(palette.triggers.first?.shortcut)
                    .disabled(store == nil)
            }
        }
        CommandGroup(replacing: .newItem) {
            Button("New Muxify Window") { windows.newWindow() }
                .keyboardShortcut(keybinds.firstTrigger(for: .newAppWindow)?.shortcut)
            Divider()
            Button("New Topic…") { store?.presentNewTopic() }
                .keyboardShortcut(keybinds.firstTrigger(for: .newTopic)?.shortcut)
                .disabled(!topicsAvailable)
            Button("Move Pane…") { store?.presentMovePane(nil) }
                .keyboardShortcut(keybinds.firstTrigger(for: .movePane)?.shortcut)
                .disabled(!topicsAvailable || store?.selectedWindow == nil)
            Button("Move Window…") { store?.presentMoveWindow() }
                .keyboardShortcut(keybinds.firstTrigger(for: .moveWindow)?.shortcut)
                .disabled(!topicsAvailable || store?.topics.topicsEnabled != true || store?.selectedWindow == nil)
            Button("Move Session…") { store?.presentMoveSession() }
                .keyboardShortcut(keybinds.firstTrigger(for: .moveSession)?.shortcut)
                .disabled(!topicsAvailable || store?.topics.topicsEnabled != true || store?.selectedWindow == nil)
            Button("Add a Session to Topic…") { store?.presentAddSession() }
                .keyboardShortcut(keybinds.firstTrigger(for: .addSessionToTopic)?.shortcut)
                .disabled(!topicsAvailable || store?.activeTopicID == nil)
            Button("Settle Topic…") { store?.presentSettleTopic() }
                .keyboardShortcut(keybinds.firstTrigger(for: .settleTopic)?.shortcut)
                .disabled(!topicsAvailable || store?.activeTopicID == nil)
            Button(store?.topicWatcher.zen == nil ? "Zen…" : "End Zen") { store?.toggleZenOfActiveTopic() }
                .keyboardShortcut(keybinds.firstTrigger(for: .toggleZen)?.shortcut)
                .disabled(!topicsAvailable || store?.topics.topicsEnabled != true || store?.canToggleZenOfActiveTopic != true)
            Divider()
            Button("Mark Read") { store?.changeRead(.read, in: store?.currentReadTarget) }
                .keyboardShortcut(keybinds.firstTrigger(for: .markRead)?.shortcut)
                .disabled(store?.canChangeRead(.read, in: store?.currentReadTarget) != true)
            Button("Mark Unread") { store?.changeRead(.unread, in: store?.currentReadTarget) }
                .keyboardShortcut(keybinds.firstTrigger(for: .markUnread)?.shortcut)
                .disabled(store?.canChangeRead(.unread, in: store?.currentReadTarget) != true)
            Button("Mark All as Read") { store?.changeRead(.read, in: .environment) }
                .keyboardShortcut(keybinds.firstTrigger(for: .markAllRead)?.shortcut)
                .disabled(store?.canChangeRead(.read, in: .environment) != true)
            Divider()
            Button("New Tab") { store?.browserCommand(opensBrowser: true) { $0.newTab() } }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(store == nil)
            Button("New tmux Window") { store?.newWindow() }
                .disabled(remoteActionDisabled)
            Button("New tmux Session") { store?.newSession() }
                .disabled(remoteActionDisabled)
        }
        // Browser shortcuts act outside the terminal; in the terminal the
        // user's Ghostty/tmux bindings own these keys.
        CommandMenu("Browser") {
            Button(store?.panelLayout.shows(.browser) == true ? "Hide Browser" : "Show Browser") { store?.toggle(.browser) }
                .keyboardShortcut(keybinds.firstTrigger(for: .toggleBrowser)?.shortcut)
                .disabled(store?.canToggle(.browser) != true)
            Button(store?.panelLayout.shows(.terminal) == true ? "Hide Terminal" : "Show Terminal") { store?.toggle(.terminal) }
                .keyboardShortcut(keybinds.firstTrigger(for: .toggleTerminal)?.shortcut)
                .disabled(store?.canToggle(.terminal) != true)
            Button(store?.panelLayout.maximized == nil ? "Maximize" : "Restore") { store?.toggleMaximize() }
                .keyboardShortcut(keybinds.firstTrigger(for: .toggleMaximize)?.shortcut)
                .disabled(store?.canToggleMaximize != true)
            maximizeToggle("Maximize Terminal", .terminal, .toggleMaximizeTerminal)
            maximizeToggle("Maximize Browser", .browser, .toggleMaximizeBrowser)
            Divider()
            Button("Open Location…") { store?.browserCommand(opensBrowser: true) { _ in store?.focusAddressBar() } }
                .keyboardShortcut("l", modifiers: .command)
            Divider()
            Button("Find…") { store?.browserCommand { $0.activeTab?.showFind() } }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(!activeTabHasPage)
            Button("Find Next") { store?.browserCommand { $0.activeTab?.findNext() } }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(!activeTabHasPage)
            Button("Find Previous") { store?.browserCommand { $0.activeTab?.findPrevious() } }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(!activeTabHasPage)
            Divider()
            Button("Close Tab") { store?.browserCommand { $0.closeActiveTab() } }
                .keyboardShortcut("w", modifiers: .command)
            Button("Show Next Tab") { store?.browserCommand { $0.selectTab(offset: 1) } }
                .keyboardShortcut(keybinds.firstTrigger(for: .selectNextTab)?.shortcut)
            Button("Show Previous Tab") { store?.browserCommand { $0.selectTab(offset: -1) } }
                .keyboardShortcut(keybinds.firstTrigger(for: .selectPrevTab)?.shortcut)
            Divider()
            Button("Back") { store?.browserCommand { $0.activeTab?.goBack() } }
                .keyboardShortcut(keybinds.firstTrigger(for: .browserBack)?.shortcut)
            Button("Forward") { store?.browserCommand { $0.activeTab?.goForward() } }
                .keyboardShortcut(keybinds.firstTrigger(for: .browserForward)?.shortcut)
            Button("Reload Page") { store?.browserCommand { $0.activeTab?.reloadOrStop() } }
                .keyboardShortcut("r", modifiers: .command)
            Button("Copy URL") { store?.browserCommand { $0.activeTab?.copyURL() } }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(!activeTabHasPage)
            Button("Show Developer Tools") { store?.browserCommand { $0.activeTab?.showDeveloperTools() } }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(store?.panelLayout.shows(.browser) != true || store?.currentBrowser?.activeTab?.hasPage != true)
            Divider()
            Button("Focus Terminal") { store?.focus(.terminal) }
                .keyboardShortcut(keybinds.firstTrigger(for: .focusTerminal)?.shortcut)
                .disabled(store?.currentBrowser == nil)
            Button("Focus Browser") { store?.focus(.browser) }
                .keyboardShortcut(keybinds.firstTrigger(for: .focusBrowser)?.shortcut)
                .disabled(store?.currentBrowser == nil)
        }
        CommandGroup(after: .appSettings) {
            Button("Open Config") {
                if let store { store.openConfig() } else { configStore.openInEditor() }
            }
            Button("Reload Config") { windows.reloadConfig() }
                .keyboardShortcut(",", modifiers: [.command, .shift])
            Button("Install Extensions") { ExtensionInstaller.run() }
                .disabled(store?.isRemote == true)
            Button("Install Command Line Tool") { CommandLineToolInstaller.run() }
        }
    }

    private func maximizeToggle(_ title: String, _ side: PanelLayout.Side, _ action: ConfigAction) -> some View {
        Toggle(title, isOn: Binding(get: { store?.panelLayout.maximized == side }, set: { _ in store?.toggleMaximize(side) }))
            .keyboardShortcut(keybinds.firstTrigger(for: action)?.shortcut)
            .disabled(store?.canMaximize(side) != true)
    }
}
