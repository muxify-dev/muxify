import Foundation
import MuxifyCore
import Observation

/// What the updater found, as the Update Popover shows it.
struct UpdateOffer: Equatable {
    /// Sparkle's display version: a Release's version, or a Tip Build's `<short-sha> (<yyyy-mm-dd>)`.
    var version: String
    /// The build number, `sparkle:version`, for the Diagnostics log.
    var build: String
    /// The zip's length in bytes, when the feed gives one.
    var size: UInt64?
    var released: Date?
    /// The feed item's `<link>`: a Release's page, or a Tip Build's commit.
    var notes: URL?

    /// The link row of the Update Popover: a Tip Build's feed links its commit, a Release's its release page.
    var notesTitle: String? {
        guard let notes else { return nil }
        return notes.path.contains("/commit/") ? "View GitHub Commit" : "View Release Notes"
    }

    var sizeText: String? {
        size.flatMap { $0 > 0 ? ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) : nil }
    }

    var releasedText: String? {
        released?.formatted(date: .abbreviated, time: .omitted)
    }
}

/// The answer to an update the Update Popover offers; the driver turns it into Sparkle's choice.
enum UpdateChoice: Equatable {
    case install, skip, later
}

/// Where the updater checks: `MUXIFY_UPDATE_FEED_URL`, which a verify suite sets in any build, or the Update
/// Channel's feed under the feed base URL that packaging stamps into a Release's or a Tip Build's Info.plist. Nil
/// without either: a Debug or `make install` build has no updater
/// (docs/adr/0078-muxify-updates-itself-with-sparkle-from-feeds-in-a-github-release.md).
enum UpdateFeed: Equatable, CustomStringConvertible {
    /// `MUXIFY_UPDATE_FEED_URL`, whatever the channel.
    case fixed(URL)
    /// The stamped base URL: a channel's feed is `<base>stable.xml` or `<base>tip.xml`.
    case base(String)

    static let environmentKey = "MUXIFY_UPDATE_FEED_URL"
    static let baseURLKey = "MuxifyUpdateFeedBaseURL"

    init?(info: [String: Any]?, environment: [String: String]) {
        if let override = environment[Self.environmentKey], !override.isEmpty {
            guard let url = URL(string: override) else { return nil }
            self = .fixed(url)
            return
        }
        guard let base = info?[Self.baseURLKey] as? String, !base.isEmpty, URL(string: base) != nil else { return nil }
        self = .base(base)
    }

    var description: String {
        switch self {
        case .fixed(let url): "\(url.absoluteString) from \(Self.environmentKey)"
        case .base(let base): "<channel>.xml under \(base)"
        }
    }

    /// The feed that Sparkle reads for `channel`, asked through its delegate at each check, so a channel change
    /// needs no restart.
    func url(for channel: Config.Update.Channel) -> URL? {
        switch self {
        case .fixed(let url): url
        case .base(let base): URL(string: base + channel.rawValue + ".xml")
        }
    }
}

/// The one update model of the app, which every App Window's Update Button shows. Sparkle stays behind its driver
/// (`SparkleUpdater`), which reports each step of a check here and passes the user's answer back.
@MainActor @Observable
final class UpdateModel {
    enum State: Equatable {
        case idle
        case checking
        case available(UpdateOffer)
        case notFound
        /// `received` of `expected` bytes; `expected` is nil while the size is unknown.
        case downloading(received: UInt64, expected: UInt64?)
        /// The extraction's progress, from 0 to 1.
        case preparing(Double)
        case installing
        case failed(String)
    }

    /// What a translocated copy, or one on a read-only volume, says in place of Sparkle's message.
    static let moveToApplications = "Move Muxify to Applications to update it."

    /// The app's model, when this build has an updater; nil hides the Update Button, the Command and the menu item.
    static var shared: UpdateModel?

    private(set) var state = State.idle
    /// How long "No Updates Available" stays on the Update Button unless it is clicked.
    @ObservationIgnored var notFoundSeconds: TimeInterval = 5
    /// Starts a check as the user asked for one; the updater sets it.
    @ObservationIgnored var startCheck: () -> Void = {}
    /// Starts a background check, and returns false when the updater cannot start one now; the updater sets it.
    @ObservationIgnored var startBackgroundCheck: () -> Bool = { false }
    /// How long after a background check the next one is due.
    @ObservationIgnored var backgroundCheckSeconds: TimeInterval = 24 * 60 * 60
    /// The clock that says when a background check is due. The schedule looks every hour, by the wall clock, so
    /// a Mac that slept through the 24 hours checks soon after it wakes.
    @ObservationIgnored var now: () -> Date = Date.init
    /// The local Config's `update` section, nil until the updater applies it at launch.
    @ObservationIgnored private var settings: Config.Update?
    @ObservationIgnored private var lastBackgroundCheck: Date?
    /// A background check is running and has shown nothing yet: its result goes only to the Diagnostics log.
    @ObservationIgnored private var checksInBackground = false
    @ObservationIgnored private var schedule: Timer?
    @ObservationIgnored private var reply: ((UpdateChoice) -> Void)?
    @ObservationIgnored private var acknowledge: (() -> Void)?
    /// The update that Install and Relaunch chose, for the Diagnostics log of its download and install.
    @ObservationIgnored private var installing: UpdateOffer?
    /// Each "No Updates Available" gets its own number, so a late timer leaves a newer one alone.
    @ObservationIgnored private var notFoundShown = 0
    @ObservationIgnored private let log: (String) -> Void

    init(log: @escaping (String) -> Void = { Diagnostics.write($0) }) {
        self.log = log
    }

    // MARK: The Update Button

    /// The Update Button's text, or nil while it is hidden.
    var buttonText: String? {
        switch state {
        case .idle: nil
        case .checking: "Checking for Updates…"
        case .available(let offer): offer.version.isEmpty ? "Update Available" : "Update Available: \(offer.version)"
        case .notFound: "No Updates Available"
        case .downloading(let received, let expected):
            if let expected, expected > 0 { "Downloading: \(Self.percent(Double(received) / Double(expected)))%" }
            else { "Downloading…" }
        case .preparing(let progress): "Preparing: \(Self.percent(progress))%"
        case .installing: "Installing…"
        case .failed: "Update Failed"
        }
    }

    private static func percent(_ fraction: Double) -> Int {
        Int((min(max(fraction, 0), 1) * 100).rounded(.down))
    }

    /// Ghostty's SF Symbol for each state.
    var symbol: String? {
        switch state {
        case .idle: nil
        case .checking: "arrow.triangle.2.circlepath"
        case .available: "shippingbox.fill"
        case .notFound: "info.circle"
        case .downloading: "arrow.down.circle"
        case .preparing: "shippingbox"
        case .installing: "power.circle"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    /// Whether a click opens the Update Popover. A click on "No Updates Available" hides it instead.
    var opensPopover: Bool {
        switch state {
        case .available, .failed: true
        case .idle, .checking, .notFound, .downloading, .preparing, .installing: false
        }
    }

    /// A click on the Update Button that opens no popover.
    func clickWithoutPopover() {
        if state == .notFound { finishNotFound() }
    }

    // MARK: What the user does

    /// Check for Updates, from the app menu or the Command. It shows a skipped version too.
    func check() {
        switch state {
        case .notFound: finishNotFound()
        case .failed: finishFailure()
        case .downloading, .preparing, .installing:
            // The Update Button already shows the update that installs.
            log("update: check for updates, asked by the user while an update installs")
            return
        case .idle, .checking, .available: break
        }
        log("update: check for updates, asked by the user")
        startCheck()
    }

    func skip() { answer(.skip, "update: skipped") }

    func later() { answer(.later, "update: later for") }

    /// Install and Relaunch: only now does the update download. Muxify then installs it and quits as ⌘Q does,
    /// with no further question (docs/adr/0077-an-update-shows-in-the-header-not-in-the-palette.md).
    func install() {
        guard case .available(let offer) = state, reply != nil else { return }
        installing = offer
        answer(.install, "update: install and relaunch")
    }

    /// OK on a failure.
    func dismissFailure() { finishFailure() }

    /// Retry on a failure: checks again.
    func retry() {
        finishFailure()
        check()
    }

    // MARK: Background checks

    /// The Update Channel whose feed the updater reads.
    var channel: Config.Update.Channel { settings?.channel ?? .stable }

    /// The local Config's `update` section, at launch and at each Config reload. With `check` on, a background check
    /// runs at once and then every 24 hours; turning it off stops them. A changed channel checks at once.
    func apply(_ update: Config.Update) {
        let previous = settings
        settings = update
        guard update != previous else { return }
        guard update.check else {
            log("update: background checks off, \(update.channel.rawValue) channel")
            schedule?.invalidate()
            schedule = nil
            return
        }
        if previous?.check == true {
            log("update: channel \(update.channel.rawValue)")
        } else {
            log("update: background checks on, every 24 hours, \(update.channel.rawValue) channel")
            schedule = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.backgroundCheckIfDue() }
            }
            schedule?.tolerance = 5 * 60
        }
        checkInBackground()
    }

    /// One look of the schedule: a background check when 24 hours passed since the last one.
    func backgroundCheckIfDue() {
        guard settings?.check == true else { return }
        if let lastBackgroundCheck, now().timeIntervalSince(lastBackgroundCheck) < backgroundCheckSeconds { return }
        checkInBackground()
    }

    /// A check that Muxify starts by itself. The Update Button shows only an update that it finds, which Sparkle
    /// leaves out when the user skipped that version; it never shows "Checking for Updates…", "No Updates
    /// Available" or "Update Failed", and never opens the Update Popover.
    private func checkInBackground() {
        lastBackgroundCheck = now()
        guard state == .idle else {
            log("update: no background check, the Update Button shows \(buttonText ?? "")")
            return
        }
        log("update: background check, \(channel.rawValue) channel")
        checksInBackground = true
        guard startBackgroundCheck() else {
            checksInBackground = false
            log("update: no background check, a check is running")
            return
        }
    }

    /// Sparkle ended a background check's session; `error` says why it found nothing, if it showed nothing.
    func backgroundCheckFinished(_ error: NSError?) {
        guard checksInBackground else { return }
        checksInBackground = false
        guard let error else { return }
        if error.domain == "SUSparkleErrorDomain", error.code == 1001 {
            log("update: no newer build, background check")
        } else {
            log("update: background check failed: \(error.localizedDescription) (\(error.domain) \(error.code))")
        }
    }

    // MARK: What the driver reports

    func checking() {
        guard !checksInBackground else { return }
        state = .checking
    }

    func found(_ offer: UpdateOffer, reply: @escaping (UpdateChoice) -> Void) {
        log("update: found \(offer.version) (build \(offer.build))" + (checksInBackground ? ", background check" : ""))
        // From here the user answers, so a failed download shows as after a check they started.
        checksInBackground = false
        self.reply = reply
        state = .available(offer)
    }

    func notFound(acknowledge: @escaping () -> Void) {
        if checksInBackground {
            checksInBackground = false
            log("update: no newer build, background check")
            acknowledge()
            return
        }
        log("update: no newer build")
        self.acknowledge = acknowledge
        state = .notFound
        notFoundShown += 1
        let shown = notFoundShown
        DispatchQueue.main.asyncAfter(deadline: .now() + notFoundSeconds) { [weak self] in
            guard let self, self.state == .notFound, self.notFoundShown == shown else { return }
            self.finishNotFound()
        }
    }

    func downloadStarted() {
        log("update: downloading" + installingText)
        state = .downloading(received: 0, expected: nil)
    }

    func downloadExpects(_ length: UInt64) {
        log("update: download size \(length) bytes")
        state = .downloading(received: 0, expected: length > 0 ? length : nil)
    }

    func downloadReceived(_ length: UInt64) {
        guard case .downloading(let received, let expected) = state else { return }
        state = .downloading(received: received + length, expected: expected)
    }

    func preparingStarted() {
        if case .downloading(let received, _) = state { log("update: downloaded \(received) bytes") }
        state = .preparing(0)
    }

    func preparing(_ progress: Double) {
        state = .preparing(progress)
    }

    /// The installer has the update; Muxify quits through its normal termination path while it installs.
    func installStarted(applicationTerminated: Bool) {
        if state != .installing {
            log("update: installing" + installingText + (applicationTerminated ? "" : ", quitting Muxify"))
        }
        state = .installing
    }

    func installed(relaunched: Bool) {
        log("update: installed" + installingText + (relaunched ? ", relaunching" : ""))
    }

    private var installingText: String {
        installing.map { " \($0.version) (build \($0.build))" } ?? ""
    }

    /// A Sparkle error: a translocated or read-only copy says how to fix it, any other error shows Sparkle's message.
    /// The domain and code, and the underlying error, go only to the Diagnostics log.
    func failed(_ error: NSError, acknowledge: @escaping () -> Void) {
        var detail = "\(error.domain) \(error.code)"
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            detail += "; \(underlying.domain) \(underlying.code): \(underlying.localizedDescription)"
        }
        failed(Self.message(for: error), detail: detail, acknowledge: acknowledge)
    }

    /// Sparkle's `SURunningFromDiskImageError` (1003) and `SURunningTranslocated` (1005).
    static func message(for error: NSError) -> String {
        if error.domain == "SUSparkleErrorDomain", error.code == 1003 || error.code == 1005 { return moveToApplications }
        return error.localizedDescription
    }

    /// `detail` goes only to the Diagnostics log, such as the underlying network error.
    func failed(_ message: String, detail: String? = nil, acknowledge: @escaping () -> Void) {
        if checksInBackground {
            checksInBackground = false
            log("update: background check failed: \(message)" + (detail.map { " (\($0))" } ?? ""))
            acknowledge()
            return
        }
        log("update: failed: \(message)" + (detail.map { " (\($0))" } ?? ""))
        self.acknowledge = acknowledge
        state = .failed(message)
    }

    /// Sparkle ended the update session.
    func dismissed() {
        reply = nil
        acknowledge = nil
        installing = nil
        state = .idle
    }

    private func answer(_ choice: UpdateChoice, _ verb: String) {
        guard case .available(let offer) = state, let reply else { return }
        log("\(verb) \(offer.version) (build \(offer.build))")
        self.reply = nil
        state = .idle
        reply(choice)
    }

    private func finishNotFound() {
        guard state == .notFound else { return }
        state = .idle
        takeAcknowledgement()?()
    }

    private func finishFailure() {
        guard case .failed = state else { return }
        state = .idle
        takeAcknowledgement()?()
    }

    private func takeAcknowledgement() -> (() -> Void)? {
        defer { acknowledge = nil }
        return acknowledge
    }
}
