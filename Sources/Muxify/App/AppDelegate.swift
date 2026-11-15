import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Nil in the tests, which drive the launch queue and the termination flow alone.
    private let windows: AppWindows?
    /// The Sparkle updater, kept for the app's life. The tests build without Sparkle.
    private let updater: AnyObject?
    private var mainMenu: MainMenu?
    /// Installed once the first App Window opens.
    var shutdown: ((@escaping () -> Void) -> Void)?
    var openURLs: (([URL]) -> Void)? {
        didSet { deliverURLs() }
    }
    private var pendingURLs: [URL] = []
    private var isTerminating = false
    private var hasReplied = false

    init(windows: AppWindows? = nil, updater: AnyObject? = nil) {
        self.windows = windows
        self.updater = updater
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard let windows else { return }
        let menu = MainMenu(windows: windows)
        NSApp.mainMenu = menu.menu
        mainMenu = menu
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let windows else { return }
        shutdown = windows.shutdown
        windows.openFirstWindow()
        openURLs = { $0.forEach(windows.handle) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        // The GUI is exiting; surviving tmux jobs must not keep its Dock item alive.
        NSApplication.shared.setActivationPolicy(.prohibited)
        BrowserHistory.shared.flush()
    }

    /// URLs that arrive at launch wait here until the App Windows can route them.
    func application(_ application: NSApplication, open urls: [URL]) {
        pendingURLs += urls
        deliverURLs()
    }

    private func deliverURLs() {
        guard let openURLs, !pendingURLs.isEmpty else { return }
        let urls = pendingURLs
        pendingURLs.removeAll()
        openURLs(urls)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        requestTermination { sender.reply(toApplicationShouldTerminate: true) }
    }

    /// AppKit must keep the process alive for asynchronous cleanup. A task
    /// launched from willTerminate would otherwise be abandoned during exit.
    func requestTermination(reply: @escaping () -> Void) -> NSApplication.TerminateReply {
        precondition(Thread.isMainThread)
        guard let shutdown else { return .terminateNow }
        guard !isTerminating else { return hasReplied ? .terminateNow : .terminateLater }
        isTerminating = true
        shutdown {
            // Even an immediate completion must wait until terminateLater has
            // been returned; reply once, on the main thread, after cleanup.
            DispatchQueue.main.async {
                guard !self.hasReplied else { return }
                self.hasReplied = true
                reply()
            }
        }
        return .terminateLater
    }
}
