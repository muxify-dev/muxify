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

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
        onMain {
            $0.failed(error.localizedDescription, detail: underlying.map { "\($0.domain) \($0.code): \($0.localizedDescription)" },
                      acknowledge: acknowledgement)
        }
    }

    // The download, extraction and install show on the Update Button in a later change; until then the button
    // stays hidden while they run.
    func showDownloadInitiated(cancellation: @escaping () -> Void) {}

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}

    func showDownloadDidReceiveData(ofLength length: UInt64) {}

    func showDownloadDidStartExtractingUpdate() {}

    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        // The user chose Install and Relaunch already.
        reply(.install)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {}

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func showUpdateInFocus() {}

    func dismissUpdateInstallation() {
        onMain { $0.dismissed() }
    }
}
