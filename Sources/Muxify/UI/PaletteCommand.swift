import AppKit
import MuxifyCore

enum PaletteCommand: String, CaseIterable {
    case newTopic = "New Topic"
    case markRead = "Mark Read"
    case markUnread = "Mark Unread"
    case markAllRead = "Mark All as Read"
    case movePane = "Move Pane"
    case moveWindow = "Move Window"
    case moveSession = "Move Session"
    case movePaneWithTab = "Move Pane with Active Tab"
    case addSession = "Add a Session"
    case snoozeTopics = "Snooze Topics…"
    case snoozeTopic = "Snooze Topic"
    case settleTopic = "Settle Topic"
    case removeSessionFromTopic = "Remove Session from Topic"
    case forgetTopic = "Forget Topic"
    case renameTopic = "Rename Topic"
    case editTags = "Edit Tags…"
    case moveTopicUp = "Move Topic Up"
    case moveTopicDown = "Move Topic Down"
    case pinTopic = "Pin Topic"
    case unpinTopic = "Unpin Topic"
    case unsnoozeTopics = "Unsnooze Topics…"
    case unsnoozeTopic = "Unsnooze Topic"
    case lockSession = "Lock Session"
    case unlockSession = "Unlock Session"
    case zen = "Zen"
    case endZen = "End Zen"
    case maximize = "Maximize"
    case restore = "Restore"
    case maximizeTerminal = "Maximize Terminal"
    case maximizeBrowser = "Maximize Browser"
    case focusTerminal = "Focus Terminal"
    case focusBrowser = "Focus Browser"
    case showSidebar = "Show Sidebar"
    case hideSidebar = "Hide Sidebar"
    case showTerminal = "Show Terminal"
    case hideTerminal = "Hide Terminal"
    case showBrowser = "Show Browser"
    case hideBrowser = "Hide Browser"
    case nextSession = "Show Next Session"
    case previousSession = "Show Previous Session"
    case nextTopic = "Show Next Topic"
    case previousTopic = "Show Previous Topic"
    case newAppWindow = "New Muxify Window"
    case newWindow = "New tmux Window"
    case newSession = "New tmux Session"
    case openConfig = "Open Config"
    case reloadConfig = "Reload Config"
    case installExtensions = "Install Extensions"
    case installCLI = "Install Command Line Tool"
    case newTab = "New Tab"
    case closeTab = "Close Tab"
    case openLocation = "Open Location"
    case nextTab = "Show Next Tab"
    case previousTab = "Show Previous Tab"
    case back = "Back"
    case forward = "Forward"
    case reloadPage = "Reload Page"
    case copyURL = "Copy URL"
    case developerTools = "Show Developer Tools"

    /// The keybinding that does what this Command does, so the row shows its shortcut.
    var keybinding: ConfigAction? {
        switch self {
        case .newTopic: .newTopic
        case .markRead: .markRead
        case .markUnread: .markUnread
        case .markAllRead: .markAllRead
        case .movePane: .movePane
        case .moveWindow: .moveWindow
        case .moveSession: .moveSession
        case .addSession: .addSessionToTopic
        case .snoozeTopic: .snoozeTopic
        case .snoozeTopics: .snoozeTopics
        case .settleTopic: .settleTopic
        case .removeSessionFromTopic: .removeSessionFromTopic
        case .forgetTopic: .forgetTopic
        case .renameTopic: .renameTopic
        case .zen, .endZen: .toggleZen
        case .lockSession, .unlockSession: .toggleLock
        case .moveTopicUp: .moveTopicUp
        case .moveTopicDown: .moveTopicDown
        case .pinTopic, .unpinTopic: .togglePinTopic
        case .unsnoozeTopic: .unsnoozeTopic
        case .unsnoozeTopics: .unsnoozeTopics
        case .newAppWindow: .newAppWindow
        case .maximize, .restore: .toggleMaximize
        case .maximizeTerminal: .toggleMaximizeTerminal
        case .maximizeBrowser: .toggleMaximizeBrowser
        case .focusTerminal: .focusTerminal
        case .focusBrowser: .focusBrowser
        case .showSidebar, .hideSidebar: .toggleSidebar
        case .showTerminal, .hideTerminal: .toggleTerminal
        case .showBrowser, .hideBrowser: .toggleBrowser
        case .nextSession: .selectNextSession
        case .previousSession: .selectPrevSession
        case .nextTopic: .selectNextTopic
        case .previousTopic: .selectPrevTopic
        default: nil
        }
    }

    /// What ⌘↩ on the row does in place of ↩, for a Command whose stronger form stops processes (ADR 0014).
    var commandReturnTitle: String? {
        switch self {
        case .removeSessionFromTopic: "Remove and Kill…"
        default: nil
        }
    }

    /// Commands that change the layout or move Focus. They run as their
    /// keybinding does, after the palette gives Focus back.
    var isLayout: Bool {
        switch self {
        case .maximize, .restore, .maximizeTerminal, .maximizeBrowser, .focusTerminal, .focusBrowser,
             .showSidebar, .hideSidebar, .showTerminal, .hideTerminal, .showBrowser, .hideBrowser: true
        default: false
        }
    }
}

extension CommandPalette {
    var commands: [PaletteCommand] {
        guard let store else { return [] }
        let canChangeTopics = !store.isRemote && !store.changingTopic && store.topics.topicsEnabled
        let hasOpenTopic = store.topicWatcher.records.contains { $0.id == store.activeTopicID && $0.settledAt == nil }
        return PaletteCommand.allCases.filter { command in
            switch command {
            case .markRead: return store.canChangeRead(.read, in: store.currentReadTarget)
            case .markUnread: return store.canChangeRead(.unread, in: store.currentReadTarget)
            case .markAllRead: return store.canChangeRead(.read, in: .environment)
            case .newTopic: return !store.isRemote && !store.changingTopic
            case .movePane, .moveWindow, .moveSession: return canChangeTopics && store.selectedWindow != nil
            case .movePaneWithTab: return canChangeTopics && store.selectedWindow != nil && store.currentBrowser?.activeTab != nil
            case .addSession, .snoozeTopic, .settleTopic: return canChangeTopics && hasOpenTopic
            case .editTags: return canChangeTopics && hasOpenTopic && store.topicConfig.tags != nil
            case .forgetTopic, .renameTopic: return canChangeTopics && hasOpenTopic && store.topics.mode == .topics
            case .removeSessionFromTopic:
                return canChangeTopics && hasOpenTopic && store.topics.mode == .topics
                    && store.selectedWindow?.topicID == store.activeTopicID
            case .snoozeTopics: return canChangeTopics && store.topicWatcher.records.contains { $0.settledAt == nil }
            case .moveTopicUp: return canChangeTopics && store.activeCardMove(.previous) != nil
            case .moveTopicDown: return canChangeTopics && store.activeCardMove(.next) != nil
            case .pinTopic, .unpinTopic:
                guard canChangeTopics, let topic = store.pinnableActiveTopic else { return false }
                return topic.isPinned == (command == .unpinTopic)
            case .unsnoozeTopic, .unsnoozeTopics: return canChangeTopics && !store.topics.snoozedRows.isEmpty
            case .lockSession, .unlockSession:
                guard canChangeTopics, let id = store.selectedWindow?.sessionID, let locked = store.lockState(ofSession: id) else { return false }
                return locked == (command == .unlockSession)
            case .zen: return canChangeTopics && hasOpenTopic && store.topicWatcher.zen == nil && store.topics.mode == .topics
            case .endZen: return !store.isRemote && !store.changingTopic && store.topicWatcher.zen != nil
            case .installExtensions: return !store.isRemote
            case .nextSession, .previousSession, .nextTopic, .previousTopic:
                guard let step = command.keybinding?.step else { return false }
                return store.stepTarget(step.level, step.direction) != nil
            case .closeTab, .nextTab, .previousTab: return store.currentBrowser?.activeTab != nil
            case .back: return store.currentBrowser?.activeTab?.canGoBack == true
            case .forward: return store.currentBrowser?.activeTab?.canGoForward == true
            case .reloadPage, .copyURL, .developerTools: return store.currentBrowser?.activeTab?.hasPage == true
            case .maximize: return store.panelLayout.maximized == nil && store.canToggleMaximize
            case .restore: return store.currentBrowser != nil && store.panelLayout.maximized != nil
            case .maximizeTerminal: return store.panelLayout.maximized != .terminal && store.canMaximize(.terminal)
            case .maximizeBrowser: return store.panelLayout.maximized != .browser && store.canMaximize(.browser)
            case .focusTerminal, .focusBrowser: return store.currentBrowser != nil
            case .showSidebar: return !store.sidebarShown
            case .hideSidebar: return store.sidebarShown
            case .showTerminal: return !store.panelLayout.shows(.terminal) && store.canToggle(.terminal)
            case .hideTerminal: return store.panelLayout.shows(.terminal) && store.canToggle(.terminal)
            case .showBrowser: return !store.panelLayout.shows(.browser) && store.canToggle(.browser)
            case .hideBrowser: return store.panelLayout.shows(.browser) && store.canToggle(.browser)
            default: return true
            }
        }
    }

    func shortcut(for command: PaletteCommand) -> String? {
        if let action = command.keybinding { return store?.config.keybinds.firstTrigger(for: action)?.symbol }
        switch command {
        case .newTab: return "⌘T"
        case .closeTab: return "⌘W"
        case .openLocation: return "⌘L"
        case .nextTab: return "⇧⌘]"
        case .previousTab: return "⇧⌘["
        case .back: return "⌘["
        case .forward: return "⌘]"
        case .reloadPage: return "⌘R"
        case .copyURL: return "⇧⌘C"
        case .developerTools: return "⌥⌘I"
        case .reloadConfig: return "⇧⌘,"
        default: return nil
        }
    }

    func run(_ command: PaletteCommand) {
        guard let store, commands.contains(command) else { return }
        if command.isLayout, let action = command.keybinding {
            close()
            // close() gives Focus back in a main-queue block; this one runs after it.
            DispatchQueue.main.async { store.perform(action) }
            return
        }
        switch command {
        case .newTopic, .movePane, .moveWindow, .moveSession, .movePaneWithTab, .addSession, .snoozeTopic, .snoozeTopics, .settleTopic, .zen,
             .forgetTopic, .renameTopic, .editTags, .unsnoozeTopic, .unsnoozeTopics: break
        default: close(restoringFocus: false)
        }
        switch command {
        case .markRead: store.changeRead(.read, in: store.currentReadTarget)
        case .markUnread: store.changeRead(.unread, in: store.currentReadTarget)
        case .markAllRead: store.changeRead(.read, in: .environment)
        case .newTopic: store.presentNewTopic(keepingHistory: true)
        case .movePane: store.presentMovePane(nil, keepingHistory: true)
        case .movePaneWithTab: store.presentMovePane(nil, includesTab: true, keepingHistory: true)
        case .moveWindow: store.presentMoveWindow(keepingHistory: true)
        case .moveSession: store.presentMoveSession(keepingHistory: true)
        case .addSession: store.presentAddSession(keepingHistory: true)
        case .snoozeTopic: if let id = store.activeTopicID { store.presentSnooze(id, keepingHistory: true) }
        case .snoozeTopics: store.presentCheck(CheckDraft(action: .snooze), keepingHistory: true)
        case .unsnoozeTopics: store.presentCheck(CheckDraft(action: .unsnooze), keepingHistory: true)
        case .settleTopic: store.presentSettleTopic(keepingHistory: true)
        case .removeSessionFromTopic: if let window = store.selectedWindow { store.removeFromTopic(window) }
        case .forgetTopic: if let id = store.activeTopicID { store.presentForgetTopic(id, keepingHistory: true) }
        case .renameTopic: store.presentRenameTopic(keepingHistory: true)
        case .editTags: if let id = store.activeTopicID { store.presentEditTags(of: id, keepingHistory: true) }
        case .zen: store.toggleZenOfActiveTopic(keepingHistory: true)
        case .endZen: store.endZen()
        case .lockSession, .unlockSession: store.toggleLockOfCurrentSession()
        case .moveTopicUp: store.moveActiveCard(.previous)
        case .moveTopicDown: store.moveActiveCard(.next)
        case .pinTopic, .unpinTopic: store.togglePinOfActiveTopic()
        case .unsnoozeTopic: store.presentUnsnoozeTopic(keepingHistory: true)
        case .nextSession, .previousSession, .nextTopic, .previousTopic:
            if let step = command.keybinding?.step { store.step(step.level, step.direction) }
        case .newAppWindow: store.onNewAppWindow?()
        case .newWindow: store.newWindow()
        case .newSession: store.newSession()
        case .openConfig: store.openConfig()
        case .reloadConfig: store.reloadConfig()
        case .installExtensions: ExtensionInstaller.run()
        case .installCLI: CommandLineToolInstaller.run()
        case .newTab: store.browserCommand(opensBrowser: true) { $0.newTab() }
        case .closeTab: store.currentBrowser?.closeActiveTab()
        case .openLocation: store.browserCommand(opensBrowser: true) { _ in store.focusAddressBar() }
        case .nextTab: store.currentBrowser?.selectTab(offset: 1)
        case .previousTab: store.currentBrowser?.selectTab(offset: -1)
        case .back: store.currentBrowser?.activeTab?.goBack()
        case .forward: store.currentBrowser?.activeTab?.goForward()
        case .reloadPage: store.currentBrowser?.activeTab?.reloadOrStop()
        case .copyURL: store.currentBrowser?.activeTab?.copyURL()
        case .developerTools: store.currentBrowser?.activeTab?.showDeveloperTools()
        case .maximize, .restore, .maximizeTerminal, .maximizeBrowser, .focusTerminal, .focusBrowser,
             .showSidebar, .hideSidebar, .showTerminal, .hideTerminal, .showBrowser, .hideBrowser: break
        }
    }

    /// ⌘↩ on a Command row: its `commandReturnTitle` form.
    func runCommandReturn(_ command: PaletteCommand) {
        guard let store, commands.contains(command) else { return }
        switch command {
        case .removeSessionFromTopic:
            if let window = store.selectedWindow { begin(.confirm(PaletteConfirmation(.removeAndKill(window))), keepingHistory: true) }
        default: break
        }
    }
}
