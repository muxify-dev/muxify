import AppKit
import Sparkle

/// Muxify's updater: Sparkle's `SPUUpdater` with Muxify's own user driver, which reports every step to the app's one
/// `UpdateModel`. Sparkle's own windows and its "check automatically?" prompt never show; the Update Button in each
/// App Window's header does (docs/adr/0077-an-update-shows-in-the-header-not-in-the-palette.md).
/// The unit tests do not link Sparkle, so only this file imports it.
@MainActor final class SparkleUpdater: NSObject, SPUUpdaterDelegate {
    let model: UpdateModel
    private let feed: URL
    private let driver: UpdateUserDriver
    private var updater: SPUUpdater!
    private var started = false
    /// A check the user asked for while the last session was still ending, such as Retry right after its OK.
    private var checksWhenSessionEnds = false

    /// The updater, when this build has a feed (`UpdateFeed`); it also sets `UpdateModel.shared`.
    static func startIfConfigured() -> SparkleUpdater? {
        guard let feed = UpdateFeed.url(info: Bundle.main.infoDictionary, environment: ProcessInfo.processInfo.environment)
        else { return nil }
        let updater = SparkleUpdater(feed: feed, model: UpdateModel())
        UpdateModel.shared = updater.model
        updater.start()
        return updater
    }

    private init(feed: URL, model: UpdateModel) {
        self.feed = feed
        self.model = model
        driver = UpdateUserDriver(model: model)
        super.init()
        updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
        model.startCheck = { [weak self] in self?.check() }
    }

    private func start() {
        do {
            try updater.start()
            started = true
            Diagnostics.write("update: updater started, feed \(feed.absoluteString)")
        } catch {
            Diagnostics.report("update: the updater did not start: \(error.localizedDescription)")
        }
    }

    /// A check that the user started, which shows every state and a skipped version too.
    private func check() {
        if !started {
            start()
            guard started else {
                model.failed("The updater did not start.", acknowledge: { [weak self] in self?.model.dismissed() })
                return
            }
        }
        if updater.sessionInProgress {
            // Sparkle shows an update it already offers again through showUpdateInFocus, which the Update Button
            // already does; a session that is ending takes the check when it ends.
            if case .available = model.state { return }
            checksWhenSessionEnds = true
            return
        }
        updater.checkForUpdates()
    }

    // MARK: SPUUpdaterDelegate

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        MainActor.assumeIsolated { feed.absoluteString }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        MainActor.assumeIsolated {
            guard checksWhenSessionEnds else { return }
            checksWhenSessionEnds = false
            DispatchQueue.main.async { [weak self] in self?.check() }
        }
    }
}

/// Turns Sparkle's user-driver calls into `UpdateModel` events. Sparkle calls it on the main thread.
private final class UpdateUserDriver: NSObject, SPUUserDriver {
    private let model: UpdateModel

    init(model: UpdateModel) {
        self.model = model
    }

    private func onMain(_ body: @MainActor (UpdateModel) -> Void) {
        MainActor.assumeIsolated { body(model) }
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Info.plist turns the prompt off; the Config owns the checks.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        onMain { $0.checking() }
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let offer = UpdateOffer(version: appcastItem.displayVersionString, build: appcastItem.versionString,
                                size: appcastItem.contentLength > 0 ? appcastItem.contentLength : nil,
                                released: appcastItem.date, notes: appcastItem.infoURL)
        onMain {
            $0.found(offer) { choice in
                switch choice {
                case .install: reply(.install)
                case .skip: reply(.skip)
                case .later: reply(.dismiss)
                }
            }
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        onMain { $0.notFound(acknowledge: acknowledgement) }
    }

    /// A failed check, download or install, a zip whose signature does not verify, or a translocated or read-only
    /// copy (`SURunningTranslocated`, `SURunningFromDiskImageError`).
    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        onMain { $0.failed(error as NSError, acknowledge: acknowledgement) }
    }

    // The download starts only after Install and Relaunch: Info.plist turns Sparkle's automatic download off.
    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        onMain { $0.downloadStarted() }
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        onMain { $0.downloadExpects(expectedContentLength) }
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        onMain { $0.downloadReceived(length) }
    }

    func showDownloadDidStartExtractingUpdate() {
        onMain { $0.preparingStarted() }
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        onMain { $0.preparing(progress) }
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        // The user chose Install and Relaunch already, so Muxify installs without asking again.
        reply(.install)
    }

    /// Sparkle's installer then sends Muxify a quit Apple event, which goes through `applicationShouldTerminate`
    /// and `AppDelegate.requestTermination` as ⌘Q does; Muxify never cancels it, so there is nothing to retry.
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {
        onMain { $0.installStarted(applicationTerminated: applicationTerminated) }
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        onMain { $0.installed(relaunched: relaunched) }
        acknowledgement()
    }

    func showUpdateInFocus() {}

    func dismissUpdateInstallation() {
        onMain { $0.dismissed() }
    }
}
