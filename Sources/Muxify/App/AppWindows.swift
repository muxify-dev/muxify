import AppKit
import GhosttyKit
import MuxifyCore
import Observation

/// One process/Config, with independent workspaces and owned connections for
/// each native App Window. Closing a window cleans only that workspace.
@MainActor @Observable
final class AppWindows {
    let configStore: ConfigStore
    /// Where the App Windows and their stores remember view state across launches. The app passes `.standard`;
    /// a test, a suite of its own.
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let initialEnvironmentName: String?
    private(set) var focusedID: UUID?
    /// Opens the App Window of a request in a window controller of its own. A test replaces it to see what would open.
    @ObservationIgnored lazy var openWindow: (AppWindowRequest) -> Void = { [weak self] in self?.makeWindow(for: $0) }
    /// The Settings window's draft, kept while the window is closed (ADR 0074).
    @ObservationIgnored let settings: SettingsModel
    @ObservationIgnored private lazy var settingsWindow = SettingsWindowController(model: settings)
    @ObservationIgnored private var catalog = AppWindowCatalog()
    @ObservationIgnored private var stores: [UUID: WorkspaceStore] = [:]
    @ObservationIgnored private var controllers: [UUID: AppWindowController] = [:]
    @ObservationIgnored private var nativeWindows: [UUID: NSWindow] = [:]
    @ObservationIgnored private var observers: [UUID: [NSObjectProtocol]] = [:]
    @ObservationIgnored private var isQuitting = false

    var focusedStore: WorkspaceStore? { focusedID.flatMap { stores[$0] } }
    @ObservationIgnored private(set) lazy var browserAgent = BrowserAgentService { [weak self] in self?.localStores ?? [] }

    /// The stores that show the Local Environment, the one that consumes `@muxify_open` first.
    private var localStores: [WorkspaceStore] {
        let first = catalog.window(forEnvironment: nil).flatMap { stores[$0.id] }
        return (first.map { [$0] } ?? []) + stores.values.filter { $0 !== first && $0.activeEnvironment == nil }
    }

    init(configStore: ConfigStore, defaults: UserDefaults = .standard) {
        self.configStore = configStore
        self.defaults = defaults
        settings = SettingsModel(configStore: configStore)
        let remembered = defaults.string(forKey: "selectedEnvironment")
        let name = configStore.config.remoteEnvironments.first { $0.name == remembered }?.name
        initialEnvironmentName = name
        Diagnostics.moving = { [weak self] in self?.movingState() ?? MovingState() }
    }

    /// What was moving in the focused App Window, for the Diagnostics `minute` record: the window, the Working
    /// marks of its Environment's Agents, the Sidebar mode shown and the Topic cards and Session rows it lists.
    private func movingState() -> MovingState {
        guard let id = focusedID ?? stores.keys.first, let store = stores[id] else { return MovingState() }
        let model = store.topics
        let window = nativeWindows[id].map { window in
            AppWindowState(visible: window.isVisible && window.occlusionState.contains(.visible) && !window.isMiniaturized,
                           active: NSApp.isActive && (window.isKeyWindow || window.isMainWindow))
        }
        return MovingState(window: window, workingMarks: model.agentMarks.values.filter { $0 == .working }.count,
                           marksMove: configStore.config.pulse && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                           sidebar: model.mode, topicCards: model.list.filter { $0.cardID != nil }.count, sessionRows: store.sessions.count)
    }

    deinit {
        for tokens in observers.values { tokens.forEach(NotificationCenter.default.removeObserver) }
    }

    /// The App Window that launch opens, on the Environment that was focused last, when AppKit restored none.
    func openFirstWindow() {
        guard catalog.requests.isEmpty else { return }
        openWindow(catalog.openEnvironment(named: initialEnvironmentName))
    }

    private func makeWindow(for request: AppWindowRequest) {
        controller(for: request).showWindow(nil)
    }

    /// The window of an App Window that AppKit restores at launch. AppKit puts it back where it was and shows it.
    func restoreWindow(for request: AppWindowRequest) -> NSWindow? {
        controller(for: request).window
    }

    /// Each App Window request gets one window controller, and with it one store.
    private func controller(for request: AppWindowRequest) -> AppWindowController {
        if let controller = controllers[request.id] { return controller }
        let controller = AppWindowController(request: request, store: store(for: request), windows: self)
        controllers[request.id] = controller
        return controller
    }

    func showSettings() {
        settingsWindow.showWindow(nil)
    }

    func store(for request: AppWindowRequest) -> WorkspaceStore {
        if let store = stores[request.id] { return store }
        let environment = configStore.config.remoteEnvironments.first { $0.name == request.environmentName }
        let store = WorkspaceStore(configStore: configStore, environment: environment, defaults: defaults)
        stores[request.id] = store
        catalog.register(request)
        catalog.updateEnvironment(request.id, name: environment?.name)
        store.onSelectEnvironment = { [weak self] name in self?.selectEnvironment(named: name) }
        store.onNewAppWindow = { [weak self] in self?.newWindow() }
        store.onOpenSettings = { [weak self] in self?.showSettings() }
        // The last App Window to close quits the app.
        store.onCloseAppWindow = { [weak self] in self?.nativeWindows[request.id]?.close() }
        store.shouldConsumeOpenRequests = { [weak self, weak store] in
            guard let self, let store else { return false }
            return self.catalog.window(forEnvironment: store.activeEnvironment?.name)?.id == request.id
        }
        store.serveBrowserAgent = { [weak self] socket in
            self?.browserAgent.serve(tmuxSocket: socket)
        }
        // A Host's Browser commands come through this App Window's own Host Server, so its own Browsers serve them.
        store.serveBrowserRequest = { [weak self, weak store] request in
            guard let self, let store else { return .failure("Muxify is quitting") }
            return await self.browserAgent.handle(request, in: [store])
        }
        store.onBringToFront = { [weak self] in self?.bringToFront(request.id) }
        return store
    }

    /// Reload Config: the local Config, and each Remote Environment's own.
    func reloadConfig() {
        configStore.reload()
        for store in stores.values { store.reloadEnvironmentConfig() }
    }

    func newWindow() {
        guard !isQuitting else { return }
        openWindow(catalog.newLocalWindow())
    }

    func selectEnvironment(named name: String?) {
        guard !isQuitting, name == nil || configStore.config.remoteEnvironments.contains(where: { $0.name == name }) else { return }
        let request = catalog.openEnvironment(named: name)
        if let window = nativeWindows[request.id] {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            focus(request.id)
        } else {
            openWindow(request)
        }
    }

    /// Unqualified tmux IDs/session names in macOS URLs belong to Local, not
    /// a remote server with possibly identical IDs. Deliver once per process.
    func handle(_ url: URL) {
        guard !isQuitting, url.scheme == "muxify" else { return }
        if url.host == "toggle-browser" { focusedStore?.handle(url); return }
        guard ["select", "open", "topic"].contains(url.host ?? "") else { return }
        let request = catalog.openEnvironment(named: nil)
        store(for: request).handle(url)
        selectEnvironment(named: nil)
    }

    func register(_ window: NSWindow, for id: UUID) {
        guard !isQuitting else { return }
        if let existing = nativeWindows[id] {
            if existing !== window { Diagnostics.report("refusing duplicate App Window identity \(id)") }
            return
        }
        nativeWindows[id] = window
        window.tabbingMode = .disallowed
        // The verify checks find the traffic lights by these. Accessibility sees each button's cell, not the button.
        for (button, identifier) in [(NSWindow.ButtonType.closeButton, "traffic-light-close"),
                                     (.miniaturizeButton, "traffic-light-minimize"), (.zoomButton, "traffic-light-zoom")] {
            window.standardWindowButton(button)?.cell?.setAccessibilityIdentifier(identifier)
        }
        let center = NotificationCenter.default
        observers[id] = [
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.focus(id)
                    self?.stores[id]?.readActiveTopicOnEntry()
                    self?.stores[id]?.refresh()
                }
            },
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stores[id]?.stopReadingTerminal() }
            },
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close(id) }
            },
        ]
        // An app launched in the background gets no key window, and its menus need one to act on.
        if window.isKeyWindow || focusedID == nil { focus(id) }
    }

    func updateEnvironment(for id: UUID) {
        guard let store = stores[id] else { return }
        catalog.updateEnvironment(id, name: store.activeEnvironment?.name)
        nativeWindows[id]?.invalidateRestorableState()
        if focusedID == id { remember(store.activeEnvironment?.name) }
        updateOpenConsumers()
    }

    private func focus(_ id: UUID) {
        guard !isQuitting, let store = stores[id], nativeWindows[id] != nil else { return }
        catalog.focus(id)
        focusedID = id
        remember(store.activeEnvironment?.name)
        updateOpenConsumers()
    }

    /// Which App Window consumes `@muxify_open` follows focus, and on a Host its Host Server names its own socket in
    /// `@muxify_browser_socket` (ADR 0091), so each store hears at once whether it is the one.
    private func updateOpenConsumers() {
        for store in stores.values { store.updateOpenConsumer() }
    }

    /// Shows the App Window in front, as `open muxify://select` does locally, after a program on its Host asked it
    /// to show something. A verify run never takes focus from the user.
    private func bringToFront(_ id: UUID) {
        guard !isQuitting, let window = nativeWindows[id] else { return }
        #if DEBUG
        if TestDriver.isRunning { return }
        #endif
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        focus(id)
    }

    private func remember(_ name: String?) {
        if let name { defaults.set(name, forKey: "selectedEnvironment") }
        else { defaults.removeObject(forKey: "selectedEnvironment") }
    }

    private func close(_ id: UUID) {
        nativeWindows[id] = nil
        catalog.close(id)
        if focusedID == id { focusedID = nil }
        updateOpenConsumers()
        guard let store = stores[id] else { return }
        store.shutdown { [weak self] in
            guard let self else { return }
            self.stores[id] = nil
            self.controllers[id] = nil
            self.observers.removeValue(forKey: id)?.forEach(NotificationCenter.default.removeObserver)
        }
    }

    func shutdown(completion: @escaping () -> Void) {
        isQuitting = true
        let pending = DispatchGroup()
        // Closed windows stay in stores until their asynchronous cleanup has
        // finished, so quit also waits for retirement already in flight.
        for store in stores.values {
            pending.enter()
            store.shutdown { pending.leave() }
        }
        pending.notify(queue: .main) { [weak self] in
            self?.browserAgent.stop()
            completion()
        }
    }
}

extension AppWindows: @preconcurrency GhosttyRuntimeDelegate {
    func ghosttyOpenURL(_ url: URL) { focusedStore?.ghosttyOpenURL(url) }
    func ghosttyNewTab() { focusedStore?.ghosttyNewTab() }
    func ghosttyNewWindow() { newWindow() }
    func ghosttyNewSplit(_ direction: ghostty_action_split_direction_e) { focusedStore?.ghosttyNewSplit(direction) }
    func ghosttyGotoSplit(_ direction: ghostty_action_goto_split_e) { focusedStore?.ghosttyGotoSplit(direction) }
    func ghosttyToggleSplitZoom() { focusedStore?.ghosttyToggleSplitZoom() }
    func ghosttyStartSearch() { focusedStore?.ghosttyStartSearch() }
    func ghosttyEqualizeSplits() { focusedStore?.ghosttyEqualizeSplits() }
    func ghosttyGotoTab(_ tab: Int32) { focusedStore?.ghosttyGotoTab(tab) }
    func ghosttySurfaceClosed(_ view: TerminalSurfaceView) { view.delegate?.ghosttySurfaceClosed(view) }
    func ghosttyThemeChanged(_ theme: TerminalTheme) { stores.values.forEach { $0.ghosttyThemeChanged(theme) } }
    func ghosttyReloadConfig() { reloadConfig() }
}
