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
        case failed(String)
    }

    /// The app's model, when this build has an updater; nil hides the Update Button, the Command and the menu item.
    static var shared: UpdateModel?

    private(set) var state = State.idle
    /// How long "No Updates Available" stays on the Update Button unless it is clicked.
    @ObservationIgnored var notFoundSeconds: TimeInterval = 5
    /// Starts a check as the user asked for one; the updater sets it.
    @ObservationIgnored var startCheck: () -> Void = {}
    @ObservationIgnored private var reply: ((UpdateChoice) -> Void)?
    @ObservationIgnored private var acknowledge: (() -> Void)?
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
        case .failed: "Update Failed"
        }
    }

    /// Ghostty's SF Symbol for each state.
    var symbol: String? {
        switch state {
        case .idle: nil
        case .checking: "arrow.triangle.2.circlepath"
        case .available: "shippingbox.fill"
        case .notFound: "info.circle"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    /// Whether a click opens the Update Popover. A click on "No Updates Available" hides it instead.
    var opensPopover: Bool {
        switch state {
        case .available, .failed: true
        case .idle, .checking, .notFound: false
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
        case .idle, .checking, .available: break
        }
        log("update: check for updates, asked by the user")
        startCheck()
    }

    func skip() { answer(.skip, "update: skipped") }

    func later() { answer(.later, "update: later for") }

    func install() { answer(.install, "update: install and relaunch") }

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
