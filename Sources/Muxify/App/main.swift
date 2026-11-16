import AppKit
import MuxifyCore

// What the app does before AppKit runs, in this order: the process environment is fixed before libghostty and the
// first tmux call, which inherit it. Then the app delegate takes over (ADR 0083).
let appDelegate = MainActor.assumeIsolated {
    CommandLineToolForwarding.forwardIfNeeded()
    #if DEBUG
    TestDriver.startIfRequested()
    #endif
    AppEnvironment.prepare()
    PTYWatch.start()
    let configStore = ConfigStore(appliesAppSettings: true)
    configStore.start()
    // The imports of the old Topic records, Muxify Worktree record and Browser History files name each entry they
    // could not move in the Diagnostics log.
    StateDatabase.reportProblem = { Diagnostics.report("state: \($0)") }
    let windows = AppWindows(configStore: configStore, visitStore: VisitStore(paths: MuxifyPaths()))
    // Nil in a build without a feed, such as Debug or `make install` (UpdateFeed).
    let updater = SparkleUpdater.startIfConfigured(update: configStore.config.update)
    GhosttyRuntime.shared.delegate = windows
    return AppDelegate(windows: windows, updater: updater)
}
NSApplication.shared.delegate = appDelegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)

enum AppEnvironment {
    /// Process environment fixes that must happen before libghostty and the
    /// first tmux invocation, since both are inherited by child processes.
    static func prepare() {
        // Launched from inside tmux (e.g. `open` in a pane), tmux refuses to nest.
        unsetenv("TMUX")
        unsetenv("TMUX_PANE")

        // Finder-launched apps get no locale; tmux then draws Unicode as `_`.
        if getenv("LANG") == nil { setenv("LANG", "en_US.UTF-8", 1) }

        // Finder-launched apps get a minimal PATH; make Homebrew tools visible.
        var path = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            .split(separator: ":").map(String.init)
        for dir in ["/usr/local/bin", "/opt/homebrew/sbin", "/opt/homebrew/bin"] where !path.contains(dir) {
            path.insert(dir, at: 0)
        }
        if let resources = Bundle.main.resourceURL {
            let bin = resources.appendingPathComponent("bin").path
            if let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent().path {
                path.removeAll { $0 == executableDirectory }
            }
            path.removeAll { $0 == bin }
            path.insert(bin, at: 0)
            setenv("GHOSTTY_BIN_DIR", bin, 1)
        }
        setenv("PATH", path.joined(separator: ":"), 1)

        // libghostty finds terminfo/themes inside our bundle (copied at build
        // time). If they are missing, borrow them from an installed Ghostty.app.
        let fm = FileManager.default
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("terminfo/78/xterm-ghostty").path ?? ""
        let installed = "/Applications/Ghostty.app/Contents/Resources/ghostty"
        if fm.fileExists(atPath: bundled), let resources = Bundle.main.resourceURL {
            setenv("GHOSTTY_RESOURCES_DIR", resources.appendingPathComponent("ghostty").path, 1)
        } else if getenv("GHOSTTY_RESOURCES_DIR") == nil, fm.fileExists(atPath: installed) {
            setenv("GHOSTTY_RESOURCES_DIR", installed, 1)
        }
    }
}
