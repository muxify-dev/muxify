import AppKit
import os

/// On while the Config's `diagnostics.enabled` is true. Then it writes to ~/Library/Logs/Muxify/muxify.log what
/// helps explain a freeze, a crash or a slow app: each freeze, with a sample of the process taken during it; CPU
/// and memory each minute; Muxify's own messages and the errors the system logs for it; crash and hang reports
/// left since the last run; and the app, window, Space and sleep changes around them. See "Diagnostics" in
/// docs/development.md.
enum Diagnostics {
    /// Any thread writes; the main thread opens and closes it.
    private static let log = OSAllocatedUnfairLock<DiagnosticsLog?>(initialState: nil)
    private static var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private static var screensAsleep = false
    /// The first Config load is at launch.
    private static var configured = false

    /// ~/Library/Logs/Muxify, or in a verify run the sandbox's logs folder, so a run never writes into the user's logs.
    static let folder: URL = {
        #if DEBUG
        if let driver = ProcessInfo.processInfo.environment["MUXIFY_TEST_DRIVER"] {
            return URL(fileURLWithPath: driver).deletingLastPathComponent().appendingPathComponent("logs", isDirectory: true)
        }
        #endif
        return FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Muxify", isDirectory: true)
    }()

    /// Follows the Config's `diagnostics.enabled`, at launch and on each reload of the Config.
    static func setEnabled(_ enabled: Bool) {
        defer { configured = true }
        if enabled { start() } else { stop() }
    }

    private static func start() {
        guard log.withLock({ $0 }) == nil else { return }
        let opened: DiagnosticsLog
        do { opened = try DiagnosticsLog(folder: folder) } catch {
            NSLog("muxify: cannot open the diagnostics log in %@: %@", folder.path, "\(error)")
            return
        }
        log.withLock { $0 = opened }
        let info = Bundle.main.infoDictionary
        write("\(configured ? "on" : "launch"): pid \(getpid()), Muxify \(info?["CFBundleShortVersionString"] as? String ?? "-") "
            + "(\(info?["CFBundleVersion"] as? String ?? "-")), macOS \(ProcessInfo.processInfo.operatingSystemVersionString), "
            + "\(NSScreen.screens.count) screens")
        let since = opened.previousWrite ?? Date().addingTimeInterval(-7 * 24 * 3600)
        for report in reports(named: Bundle.main.executableURL?.lastPathComponent ?? "MuxifyApp", since: since) {
            write("report since the last run: \(report.path)")
        }
        observeAppState()
        FreezeWatch.start()
        ResourceMonitor.start()
        DisplayLinkProbe.start()
    }

    /// A sample that already runs still finishes into the folder.
    private static func stop() {
        guard log.withLock({ $0 }) != nil else { return }
        write("off")
        DisplayLinkProbe.stop()
        ResourceMonitor.stop()
        FreezeWatch.stop()
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
        log.withLock { $0 = nil }
    }

    static func write(_ text: String) {
        log.withLock { $0 }?.write(text)
    }

    /// Muxify's own messages: to the system log, as NSLog does, and to the diagnostics log when it is on.
    static func report(_ message: String) {
        NSLog("muxify: %@", message)
        write(message)
    }

    /// The crash, hang and resource reports macOS wrote for the app since `date`.
    static func reports(named prefix: String, since date: Date, in folders: [URL] = [
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/DiagnosticReports"),
        URL(fileURLWithPath: "/Library/Logs/DiagnosticReports"),
    ]) -> [URL] {
        folders.flatMap { folder -> [URL] in
            let files = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            return files.filter { file in
                guard file.lastPathComponent.hasPrefix(prefix) else { return false }
                let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                return modified.map { $0 > date } ?? false
            }
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// One line on the app and `window`: whether they are active, visible, covered or on another Space.
    static func describe(_ window: NSWindow?) -> String {
        var text = "app \(NSApp.isActive ? "active" : "inactive")\(NSApp.isHidden ? " hidden" : "")"
        if screensAsleep { text += ", screens asleep" }
        guard let window else { return text + ", window -" }
        text += ", window \(address(window)) \(type(of: window))"
        text += window.isVisible ? " visible" : " not-visible"
        text += window.occlusionState.contains(.visible) ? " unoccluded" : " occluded"
        text += window.isOnActiveSpace ? " active-space" : " other-space"
        if window.isKeyWindow { text += " key" }
        if window.isMiniaturized { text += " minimized" }
        if window.styleMask.contains(.fullScreen) { text += " full-screen" }
        text += " screen \(window.screen.map { "\"\($0.localizedName)\"" } ?? "-")"
        return text
    }

    static func address(_ object: AnyObject?) -> String {
        guard let object else { return "nil" }
        return "0x" + String(UInt(bitPattern: Unmanaged.passUnretained(object).toOpaque()), radix: 16)
    }

    static func seconds(_ value: TimeInterval) -> String {
        String(format: "%.3fs", value)
    }

    private static func observeAppState() {
        let workspace = NSWorkspace.shared.notificationCenter
        func on(_ name: Notification.Name, in center: NotificationCenter = .default, _ text: @escaping (Notification) -> String?) {
            observers.append((center, center.addObserver(forName: name, object: nil, queue: .main) { text($0).map(write) }))
        }
        /// Hover labels are panels; their windows come and go on every hover.
        func app(_ notification: Notification) -> NSWindow? {
            (notification.object as? NSWindow).flatMap { $0 is NSPanel ? nil : $0 }
        }
        on(NSApplication.didBecomeActiveNotification) { _ in "app active\(DisplayLinkProbe.summary)" }
        on(NSApplication.didResignActiveNotification) { _ in "app inactive" }
        on(NSApplication.willTerminateNotification) { _ in "quit" }
        on(NSApplication.didChangeScreenParametersNotification) { _ in "screen parameters changed: \(NSScreen.screens.count) screens" }
        on(NSWindow.didChangeOcclusionStateNotification) { app($0).map { "occlusion changed: \(describe($0))" } }
        on(NSWindow.didChangeScreenNotification) { app($0).map { "window screen changed: \(describe($0))" } }
        on(NSWindow.didEnterFullScreenNotification) { app($0).map { "entered full screen: \(describe($0))" } }
        on(NSWindow.didExitFullScreenNotification) { app($0).map { "exited full screen: \(describe($0))" } }
        on(NSWorkspace.activeSpaceDidChangeNotification, in: workspace) { _ in "active Space changed\(DisplayLinkProbe.summary)" }
        on(NSWorkspace.screensDidSleepNotification, in: workspace) { _ in screensAsleep = true; return "screens asleep" }
        on(NSWorkspace.screensDidWakeNotification, in: workspace) { _ in screensAsleep = false; return "screens awake" }
        on(NSWorkspace.willSleepNotification, in: workspace) { _ in "system will sleep" }
        on(NSWorkspace.didWakeNotification, in: workspace) { _ in "system woke" }
        on(NSWorkspace.sessionDidResignActiveNotification, in: workspace) { _ in "user session inactive" }
        on(NSWorkspace.sessionDidBecomeActiveNotification, in: workspace) { _ in "user session active" }
    }
}
