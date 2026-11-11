import Foundation
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

/// Where the updater checks: `MUXIFY_UPDATE_FEED_URL`, which a verify suite sets in any build, or the stable feed
/// under the feed base URL that packaging stamps into a Release's or a Tip Build's Info.plist. Nil without either:
/// a Debug or `make install` build has no updater (docs/adr/0077-an-update-shows-in-the-header-not-in-the-palette.md).
enum UpdateFeed {
    static let environmentKey = "MUXIFY_UPDATE_FEED_URL"
    static let baseURLKey = "MuxifyUpdateFeedBaseURL"
    /// The Update Channel that this build reads; the Config chooses it later.
    static let channel = "stable"

    static func url(info: [String: Any]?, environment: [String: String]) -> URL? {
        if let override = environment[environmentKey], !override.isEmpty {
            return URL(string: override)
        }
        guard let base = info?[baseURLKey] as? String, !base.isEmpty else { return nil }
        return URL(string: base + channel + ".xml")
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

    // MARK: What the driver reports

    func checking() {
        state = .checking
    }

    func found(_ offer: UpdateOffer, reply: @escaping (UpdateChoice) -> Void) {
        log("update: found \(offer.version) (build \(offer.build))")
        self.reply = reply
        state = .available(offer)
    }

    func notFound(acknowledge: @escaping () -> Void) {
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
