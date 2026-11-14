import AppKit
import MuxifyCore

/// The menu bar, built in code (ADR 0083). The menus whose items follow state fill again as they open, and as AppKit
/// looks in them for a key equivalent, from the focused App Window's store and Config: never from the last workspace
/// to start a terminal or reconnect. The key monitor in WorkspaceStore acts on a keybind before the menu sees the key;
/// the menu shows the shortcut.
@MainActor final class MainMenu: NSObject, NSMenuDelegate {
    let menu = NSMenu()
    private let windows: AppWindows
    private var fills: [ObjectIdentifier: () -> [NSMenuItem]] = [:]
    /// The items that each fill placed last, which the next fill replaces.
    private var filled: [ObjectIdentifier: [NSMenuItem]] = [:]
    /// Placed again by each fill of the app menu; its submenu is the one macOS fills with services.
    private let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")

    private var store: WorkspaceStore? { windows.focusedStore }
    /// The focused App Window's, which may come from its Remote Environment.
    private var config: Config { store?.config ?? windows.configStore.config }
    private var keybinds: Keybinds { config.keybinds }

    init(windows: AppWindows) {
        self.windows = windows
        super.init()
        services.submenu = NSMenu(title: "Services")
        NSApp.servicesMenu = services.submenu
        add("Muxify", fill: { [unowned self] in appItems() })
        add("File", fill: { [unowned self] in fileItems() })
        add("Edit", items: [
            standard("Undo", Selector(("undo:")), "z"),
            standard("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            standard("Cut", #selector(NSText.cut(_:)), "x"),
            standard("Copy", #selector(NSText.copy(_:)), "c"),
            standard("Paste", #selector(NSText.paste(_:)), "v"),
            standard("Delete", #selector(NSText.delete(_:))),
            standard("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        add("View", fill: { [unowned self] in viewItems() })
        add("Browser", fill: { [unowned self] in browserItems() })
        NSApp.windowsMenu = add("Window", items: [
            standard("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            standard("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            standard("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
        ])
        NSApp.helpMenu = add("Help", items: [standard("Muxify Help", #selector(NSApplication.showHelp(_:)), "?")])
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let fill = fills[ObjectIdentifier(menu)] else { return }
        // AppKit adds items of its own to some menus as they open, such as View › Enter Full Screen. They stay.
        for item in filled[ObjectIdentifier(menu)] ?? [] where item.menu === menu { menu.removeItem(item) }
        let items = fill()
        for (index, item) in items.enumerated() { menu.insertItem(item, at: index) }
        filled[ObjectIdentifier(menu)] = items
    }

    @discardableResult
    private func add(_ title: String, items: [NSMenuItem] = [], fill: (() -> [NSMenuItem])? = nil) -> NSMenu {
        let submenu = NSMenu(title: title)
        items.forEach(submenu.addItem)
        if let fill {
            fills[ObjectIdentifier(submenu)] = fill
            submenu.delegate = self
            menuNeedsUpdate(submenu)
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        menu.addItem(item)
        return submenu
    }

    private func appItems() -> [NSMenuItem] {
        let store = self.store
        var items = [standard("About Muxify", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))]
        // Only a build with an updater has it (UpdateFeed).
        if let updates = UpdateModel.shared {
            items.append(item("Check for Updates…") { updates.check() })
        }
        return items + [
            .separator(),
            item("Open Config") { [windows] in
                if let store { store.openConfig() } else { windows.configStore.openInEditor() }
            },
            item("Reload Config", KeyTrigger(modifiers: [.command, .shift], key: .character(","))) { [windows] in windows.reloadConfig() },
            item("Install Extensions", enabled: store?.link.isOnThisMac != false) { ExtensionInstaller.run() },
            item("Install Command Line Tool") { CommandLineToolInstaller.run() },
            item("Settings…", KeyTrigger(modifiers: .command, key: .character(","))) { [windows] in windows.showSettings() },
            .separator(),
            services,
            .separator(),
            standard("Hide Muxify", #selector(NSApplication.hide(_:)), "h"),
            standard("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            standard("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            standard("Quit Muxify", #selector(NSApplication.terminate(_:)), "q"),
        ]
    }

    private func fileItems() -> [NSMenuItem] {
        let store = self.store
        /// Only an App Window whose Environment serves Topics offers them.
        let topicsAvailable = store.map { $0.link.features.contains(.topics) && !$0.changingTopic } ?? false
        let topicsEnabled = store?.topics.topicsEnabled == true
        let hasWindow = store?.selectedWindow != nil
        let remoteActionEnabled = store.map { $0.link.isOnThisMac || $0.isConnected } ?? false
        return [
            item("New Muxify Window", keybinds.firstTrigger(for: .newAppWindow)) { [windows] in windows.newWindow() },
            .separator(),
            item("New Topic…", keybinds.firstTrigger(for: .newTopic), enabled: topicsAvailable) { store?.presentNewTopic() },
            item("Move Pane…", keybinds.firstTrigger(for: .movePane), enabled: topicsAvailable && hasWindow) {
                store?.presentMovePane(nil)
            },
            item("Move Window…", keybinds.firstTrigger(for: .moveWindow), enabled: topicsAvailable && topicsEnabled && hasWindow) {
                store?.presentMoveWindow()
            },
            item("Move Session…", keybinds.firstTrigger(for: .moveSession), enabled: topicsAvailable && topicsEnabled && hasWindow) {
                store?.presentMoveSession()
            },
            item("Add a Session to Topic…", keybinds.firstTrigger(for: .addSessionToTopic),
                 enabled: topicsAvailable && store?.activeTopicID != nil) { store?.presentAddSession() },
            item("Settle Topic…", keybinds.firstTrigger(for: .settleTopic), enabled: topicsAvailable && store?.activeTopicID != nil) {
                store?.presentSettleTopic()
            },
            .separator(),
            // Enabled with any current target, so the shortcut always reaches `markCurrentRead` and its Pill.
            item("Mark Read", keybinds.firstTrigger(for: .markRead), enabled: store?.currentReadTarget != nil) {
                store?.markCurrentRead()
            },
            item("Mark Unread", keybinds.firstTrigger(for: .markUnread),
                 enabled: store?.canChangeRead(.unread, in: store?.currentReadTarget) == true) {
                store?.changeRead(.unread, in: store?.currentReadTarget)
            },
            item("Mark All as Read", keybinds.firstTrigger(for: .markAllRead), enabled: store?.canChangeRead(.read, in: .environment) == true) {
                store?.changeRead(.read, in: .environment)
            },
            .separator(),
            item("New Tab", KeyTrigger(modifiers: .command, key: .character("t")), enabled: store != nil) {
                store?.browserCommand(opensBrowser: true) { $0.newTab() }
            },
            item("New tmux Window", enabled: remoteActionEnabled) { store?.newWindow() },
            item("New tmux Session", enabled: remoteActionEnabled) { store?.newSession() },
            // Two separators, as the SwiftUI shell had them. AppKit adds Close All (⌥⌘W) as Close's alternate.
            .separator(),
            .separator(),
            standard("Close", #selector(NSWindow.performClose(_:)), "w"),
        ]
    }

    private func viewItems() -> [NSMenuItem] {
        let store = self.store
        let config = self.config
        return [
            item(store?.sidebarShown == true ? "Hide Sidebar" : "Show Sidebar", keybinds.firstTrigger(for: .toggleSidebar),
                 enabled: store != nil) { store?.toggleSidebar() },
            item(store?.sidebarModeSwitchTitle ?? "Switch to Sessions", keybinds.firstTrigger(for: .toggleSidebarMode),
                 enabled: store.map { $0.sidebarModeSwitchRefusal == nil } ?? false) { store?.toggleSidebarMode() },
            item("Show Sessions", enabled: store != nil, checked: store?.sessionsVisible ?? true) { store?.sessionsVisible.toggle() },
            item("Show Agents", enabled: store.map { config.sidebar.agents[$0.shownSidebarMode] == nil } ?? false,
                 checked: store?.agentsVisible ?? true) { store?.agentsVisible.toggle() },
            item("Show Panes", enabled: store != nil && config.sidebar.panes == nil, checked: store?.panesVisible ?? false) {
                store?.panesVisible.toggle()
            },
            item(store?.topics.isBenchShown == true ? "Hide Bench" : "Show Bench", keybinds.firstTrigger(for: .toggleBench),
                 enabled: store?.topics.isBenchShown != nil) { store?.toggleBench() },
            item(store?.currentGitView?.isOpen == true ? "Hide Git View" : "Show Git View", keybinds.firstTrigger(for: .toggleGitView),
                 enabled: store.map { $0.selectedWindow != nil && $0.gitViewRefusal == nil } ?? false) { store?.toggleGitView() },
            .separator(),
        ] + config.commandPalettes.map { palette in
            // The Command Palettes; their keybindings act in the key monitor.
            item(palette.name, palette.triggers.first, enabled: store != nil) { store?.palette.toggle(palette) }
        }
    }

    /// Browser shortcuts act outside the terminal; in the terminal the user's Ghostty/tmux bindings own these keys.
    private func browserItems() -> [NSMenuItem] {
        let store = self.store
        let activeTabHasPage = store?.currentBrowser?.activeTab?.hasPage == true
        let hasBrowser = store?.currentBrowser != nil
        return [
            item(store?.panelLayout.shows(.browser) == true ? "Hide Browser" : "Show Browser", keybinds.firstTrigger(for: .toggleBrowser),
                 enabled: store?.canToggle(.browser) == true) { store?.toggle(.browser) },
            item(store?.panelLayout.shows(.terminal) == true ? "Hide Terminal" : "Show Terminal", keybinds.firstTrigger(for: .toggleTerminal),
                 enabled: store?.canToggle(.terminal) == true) { store?.toggle(.terminal) },
            item(store?.panelLayout.maximized == nil ? "Maximize" : "Restore", keybinds.firstTrigger(for: .toggleMaximize),
                 enabled: store?.canToggleMaximize == true) { store?.toggleMaximize() },
            item("Maximize Terminal", keybinds.firstTrigger(for: .toggleMaximizeTerminal), enabled: store?.canMaximize(.terminal) == true,
                 checked: store?.panelLayout.maximized == .terminal) { store?.toggleMaximize(.terminal) },
            item("Maximize Browser", keybinds.firstTrigger(for: .toggleMaximizeBrowser), enabled: store?.canMaximize(.browser) == true,
                 checked: store?.panelLayout.maximized == .browser) { store?.toggleMaximize(.browser) },
            .separator(),
            item("Open Location…", KeyTrigger(modifiers: .command, key: .character("l"))) {
                store?.browserCommand(opensBrowser: true) { _ in store?.focusAddressBar() }
            },
            .separator(),
            item("Find…", keybinds.firstTrigger(for: .findInPage), enabled: activeTabHasPage) {
                store?.browserCommand { $0.activeTab?.showFind() }
            },
            item("Find Next", enabled: activeTabHasPage) { store?.browserCommand { $0.activeTab?.findNext() } },
            item("Find Previous", enabled: activeTabHasPage) { store?.browserCommand { $0.activeTab?.findPrevious() } },
            .separator(),
            item("Close Tab", keybinds.firstTrigger(for: .closeTab)) { store?.browserCommand { $0.closeActiveTab() } },
            item("Reopen Closed Tab", keybinds.firstTrigger(for: .reopenClosedTab), enabled: store?.currentBrowser?.canReopenClosedTab == true) {
                store?.currentBrowser?.reopenClosedTab()
            },
            item("Show Next Tab", keybinds.firstTrigger(for: .selectNextTab)) { store?.browserCommand { $0.selectTab(offset: 1) } },
            item("Show Previous Tab", keybinds.firstTrigger(for: .selectPrevTab)) { store?.browserCommand { $0.selectTab(offset: -1) } },
            .separator(),
            item("Back", keybinds.firstTrigger(for: .browserBack)) { store?.browserCommand { $0.activeTab?.goBack() } },
            item("Forward", keybinds.firstTrigger(for: .browserForward)) { store?.browserCommand { $0.activeTab?.goForward() } },
            item("Reload Page", KeyTrigger(modifiers: .command, key: .character("r"))) {
                store?.browserCommand { $0.activeTab?.reloadOrStop() }
            },
            item("Copy URL", KeyTrigger(modifiers: [.command, .shift], key: .character("c")), enabled: activeTabHasPage) {
                store?.browserCommand { $0.activeTab?.copyURL() }
            },
            item("Show Developer Tools", KeyTrigger(modifiers: [.command, .option], key: .character("i")),
                 enabled: store?.panelLayout.shows(.browser) == true && activeTabHasPage) {
                store?.browserCommand { $0.activeTab?.showDeveloperTools() }
            },
            .separator(),
            item("Focus Terminal", keybinds.firstTrigger(for: .focusTerminal), enabled: hasBrowser) { store?.focus(.terminal) },
            item("Focus Browser", keybinds.firstTrigger(for: .focusBrowser), enabled: hasBrowser) { store?.focus(.browser) },
            item("Toggle Focus", keybinds.firstTrigger(for: .toggleFocus), enabled: hasBrowser) { store?.toggleFocus() },
        ]
    }

    /// An item that runs `action`, as its menu showed it when the menu last filled.
    private func item(_ title: String, _ trigger: KeyTrigger? = nil, enabled: Bool = true, checked: Bool = false,
                      _ action: @escaping () -> Void) -> NSMenuItem {
        let target = MenuAction(isEnabled: enabled, action: action)
        let item = NSMenuItem(title: title, action: #selector(MenuAction.choose(_:)), keyEquivalent: "")
        item.target = target
        // An item holds its target weakly.
        item.representedObject = target
        item.state = checked ? .on : .off
        trigger?.show(in: item)
        return item
    }

    /// An item that sends its action to the first responder that takes it, as AppKit's own items do.
    private func standard(_ title: String, _ action: Selector, _ key: String = "",
                          _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }
}

/// What a filled item does, and whether it could act when its menu filled.
@MainActor private final class MenuAction: NSObject, NSMenuItemValidation {
    let isEnabled: Bool
    let action: () -> Void

    init(isEnabled: Bool, action: @escaping () -> Void) {
        self.isEnabled = isEnabled
        self.action = action
    }

    @objc func choose(_ sender: NSMenuItem) { action() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { isEnabled }
}
