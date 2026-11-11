import XCTest
import MuxifyCore

/// The update model, fed the events that its Sparkle driver sends, as the Update Button shows them.
@MainActor final class UpdateModelTests: XCTestCase {
    private var logged: [String] = []
    private var checks = 0

    private func model() -> UpdateModel {
        let model = UpdateModel(log: { [unowned self] in logged.append($0) })
        model.startCheck = { [unowned self] in checks += 1 }
        return model
    }

    private let offer = UpdateOffer(version: "0.2.0", build: "101", size: 12_345_678,
                                    released: Date(timeIntervalSince1970: 1_790_000_000),
                                    notes: URL(string: "https://github.com/muxify-dev/muxify/releases/tag/v0.2.0"))

    func testIdleHidesTheButton() {
        let model = model()
        XCTAssertEqual(model.state, .idle)
        XCTAssertNil(model.buttonText)
        XCTAssertNil(model.symbol)
    }

    func testCheckForUpdatesStartsACheckAndLogsIt() {
        let model = model()
        model.check()
        XCTAssertEqual(checks, 1)
        model.checking()
        XCTAssertEqual(model.buttonText, "Checking for Updates…")
        XCTAssertEqual(model.symbol, "arrow.triangle.2.circlepath")
        XCTAssertFalse(model.opensPopover)
        XCTAssertEqual(logged, ["update: check for updates, asked by the user"])
    }

    func testFoundShowsTheVersionAndOpensThePopover() {
        let model = model()
        model.checking()
        model.found(offer) { _ in }
        XCTAssertEqual(model.state, .available(offer))
        XCTAssertEqual(model.buttonText, "Update Available: 0.2.0")
        XCTAssertEqual(model.symbol, "shippingbox.fill")
        XCTAssertTrue(model.opensPopover)
        XCTAssertEqual(logged.last, "update: found 0.2.0 (build 101)")
    }

    func testOfferTextsForTheUpdatePopover() {
        XCTAssertEqual(offer.notesTitle, "View Release Notes")
        XCTAssertEqual(offer.sizeText, ByteCountFormatter.string(fromByteCount: 12_345_678, countStyle: .file))
        XCTAssertEqual(offer.releasedText, offer.released?.formatted(date: .abbreviated, time: .omitted))
        var tip = offer
        tip.notes = URL(string: "https://github.com/muxify-dev/muxify/commit/a1b2c3d")
        XCTAssertEqual(tip.notesTitle, "View GitHub Commit")
        tip.notes = nil
        tip.size = 0
        XCTAssertNil(tip.notesTitle)
        XCTAssertNil(tip.sizeText)
        tip.version = ""
        let model = model()
        model.found(tip) { _ in }
        XCTAssertEqual(model.buttonText, "Update Available")
    }

    func testSkipAnswersSkipAndHidesTheButton() {
        let model = model()
        var choices: [UpdateChoice] = []
        model.found(offer) { choices.append($0) }
        model.skip()
        XCTAssertEqual(choices, [.skip])
        XCTAssertEqual(model.state, .idle)
        XCTAssertNil(model.buttonText)
        XCTAssertEqual(logged.last, "update: skipped 0.2.0 (build 101)")
        // A second answer to the same offer never reaches Sparkle.
        model.later()
        XCTAssertEqual(choices, [.skip])
    }

    func testLaterAnswersLaterAndHidesTheButton() {
        let model = model()
        var choices: [UpdateChoice] = []
        model.found(offer) { choices.append($0) }
        model.later()
        XCTAssertEqual(choices, [.later])
        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(logged.last, "update: later for 0.2.0 (build 101)")
    }

    func testInstallAnswersInstall() {
        let model = model()
        var choices: [UpdateChoice] = []
        model.found(offer) { choices.append($0) }
        model.install()
        XCTAssertEqual(choices, [.install])
    }

    func testNotFoundShowsForFiveSecondsThenHides() {
        let model = model()
        XCTAssertEqual(model.notFoundSeconds, 5)
        model.notFoundSeconds = 0.05
        var acknowledged = 0
        model.checking()
        model.notFound { acknowledged += 1 }
        XCTAssertEqual(model.buttonText, "No Updates Available")
        XCTAssertEqual(model.symbol, "info.circle")
        XCTAssertFalse(model.opensPopover)
        XCTAssertEqual(logged.last, "update: no newer build")
        let hidden = expectation(description: "hidden")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { hidden.fulfill() }
        wait(for: [hidden], timeout: 2)
        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(acknowledged, 1)
    }

    func testAClickHidesNoUpdatesAvailableAtOnce() {
        let model = model()
        var acknowledged = 0
        model.notFound { acknowledged += 1 }
        model.clickWithoutPopover()
        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(acknowledged, 1)
        // The five seconds' timer then leaves a later state alone.
        model.checking()
        XCTAssertEqual(model.state, .checking)
    }

    func testAFailureShowsUpdateFailedWithItsMessage() {
        let model = model()
        model.checking()
        model.failed("An error occurred in retrieving update information.", detail: "NSURLErrorDomain -1004: Could not connect",
                     acknowledge: {})
        XCTAssertEqual(model.state, .failed("An error occurred in retrieving update information."))
        XCTAssertEqual(model.buttonText, "Update Failed")
        XCTAssertEqual(model.symbol, "exclamationmark.triangle.fill")
        XCTAssertTrue(model.opensPopover)
        XCTAssertEqual(logged.last, "update: failed: An error occurred in retrieving update information. "
                       + "(NSURLErrorDomain -1004: Could not connect)")
    }

    func testOKAcknowledgesTheFailureAndHidesTheButton() {
        let model = model()
        var acknowledged = 0
        model.failed("Offline", acknowledge: { acknowledged += 1 })
        model.dismissFailure()
        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(acknowledged, 1)
        XCTAssertEqual(checks, 0)
    }

    func testRetryAcknowledgesTheFailureAndChecksAgain() {
        let model = model()
        var acknowledged = 0
        model.failed("Offline", acknowledge: { acknowledged += 1 })
        model.retry()
        XCTAssertEqual(acknowledged, 1)
        XCTAssertEqual(checks, 1)
        model.checking()
        XCTAssertEqual(model.buttonText, "Checking for Updates…")
        model.found(offer) { _ in }
        XCTAssertEqual(model.buttonText, "Update Available: 0.2.0")
    }

    func testCheckForUpdatesFinishesAShownResultFirst() {
        let model = model()
        var acknowledged = 0
        model.notFound { acknowledged += 1 }
        model.check()
        XCTAssertEqual(acknowledged, 1)
        XCTAssertEqual(checks, 1)
        XCTAssertEqual(model.state, .idle)
    }

    func testSparkleEndingTheSessionHidesTheButton() {
        let model = model()
        model.checking()
        model.dismissed()
        XCTAssertEqual(model.state, .idle)
        XCTAssertNil(model.buttonText)
    }

    // MARK: Install and Relaunch

    private func installingModel() -> (UpdateModel, () -> [UpdateChoice]) {
        let model = model()
        var choices: [UpdateChoice] = []
        model.found(offer) { choices.append($0) }
        model.install()
        return (model, { choices })
    }

    func testInstallLogsItAndTheDownloadShowsItsProgress() {
        let (model, choices) = installingModel()
        XCTAssertEqual(choices(), [.install])
        XCTAssertEqual(logged.last, "update: install and relaunch 0.2.0 (build 101)")
        model.downloadStarted()
        XCTAssertEqual(model.state, .downloading(received: 0, expected: nil))
        XCTAssertEqual(model.buttonText, "Downloading…")
        XCTAssertEqual(model.symbol, "arrow.down.circle")
        XCTAssertFalse(model.opensPopover)
        XCTAssertEqual(logged.last, "update: downloading 0.2.0 (build 101)")
        model.downloadExpects(1000)
        XCTAssertEqual(model.buttonText, "Downloading: 0%")
        XCTAssertEqual(logged.last, "update: download size 1000 bytes")
        model.downloadReceived(420)
        XCTAssertEqual(model.buttonText, "Downloading: 42%")
        model.downloadReceived(579)
        XCTAssertEqual(model.buttonText, "Downloading: 99%")
        model.downloadReceived(1)
        XCTAssertEqual(model.buttonText, "Downloading: 100%")
        // More bytes than the server announced never read past 100%.
        model.downloadReceived(500)
        XCTAssertEqual(model.buttonText, "Downloading: 100%")
    }

    func testADownloadWithoutASizeShowsDownloadingWithoutAPercentage() {
        let (model, _) = installingModel()
        model.downloadStarted()
        model.downloadExpects(0)
        model.downloadReceived(4096)
        XCTAssertEqual(model.buttonText, "Downloading…")
    }

    func testPreparingThenInstallingThenRelaunching() {
        let (model, _) = installingModel()
        model.downloadStarted()
        model.downloadExpects(2048)
        model.downloadReceived(2048)
        model.preparingStarted()
        XCTAssertEqual(logged.last, "update: downloaded 2048 bytes")
        XCTAssertEqual(model.buttonText, "Preparing: 0%")
        XCTAssertEqual(model.symbol, "shippingbox")
        model.preparing(0.425)
        XCTAssertEqual(model.buttonText, "Preparing: 42%")
        XCTAssertFalse(model.opensPopover)
        model.installStarted(applicationTerminated: false)
        XCTAssertEqual(model.state, .installing)
        XCTAssertEqual(model.buttonText, "Installing…")
        XCTAssertEqual(model.symbol, "power.circle")
        XCTAssertFalse(model.opensPopover)
        XCTAssertEqual(logged.last, "update: installing 0.2.0 (build 101), quitting Muxify")
        // Sparkle can report the install twice; the log says it once.
        model.installStarted(applicationTerminated: true)
        XCTAssertEqual(logged.filter { $0.hasPrefix("update: installing") }.count, 1)
        model.installed(relaunched: true)
        XCTAssertEqual(logged.last, "update: installed 0.2.0 (build 101), relaunching")
    }

    func testCheckForUpdatesWhileAnUpdateInstallsStartsNoCheck() {
        let (model, _) = installingModel()
        model.downloadStarted()
        model.check()
        XCTAssertEqual(checks, 0)
        XCTAssertEqual(model.buttonText, "Downloading…")
    }

    private func sparkleError(_ code: Int, _ message: String, underlying: NSError? = nil) -> NSError {
        var info: [String: Any] = [NSLocalizedDescriptionKey: message]
        info[NSUnderlyingErrorKey] = underlying
        return NSError(domain: "SUSparkleErrorDomain", code: code, userInfo: info)
    }

    private func assertFailure(after progress: (UpdateModel) -> Void, error: NSError, shows message: String,
                               line: UInt = #line) {
        let (model, _) = installingModel()
        progress(model)
        var acknowledged = 0
        model.failed(error, acknowledge: { acknowledged += 1 })
        XCTAssertEqual(model.state, .failed(message), line: line)
        XCTAssertEqual(model.buttonText, "Update Failed", line: line)
        XCTAssertTrue(model.opensPopover, line: line)
        XCTAssertTrue(logged.last?.hasPrefix("update: failed: \(message) (SUSparkleErrorDomain \(error.code)") == true,
                      "\(logged.last ?? "")", line: line)
        // Retry acknowledges the failure and checks again, so the update shows again.
        model.retry()
        XCTAssertEqual(acknowledged, 1, line: line)
        XCTAssertEqual(checks, 1, line: line)
        checks = 0
    }

    func testAFailedDownloadShowsUpdateFailedWithSparklesMessage() {
        let offline = NSError(domain: NSURLErrorDomain, code: -1004, userInfo: [NSLocalizedDescriptionKey: "Could not connect"])
        assertFailure(after: { $0.downloadStarted(); $0.downloadExpects(100); $0.downloadReceived(10) },
                      error: sparkleError(2001, "An error occurred while downloading the update.", underlying: offline),
                      shows: "An error occurred while downloading the update.")
        XCTAssertTrue(logged.contains { $0.hasSuffix("(SUSparkleErrorDomain 2001; NSURLErrorDomain -1004: Could not connect)") },
                      "\(logged)")
    }

    func testABadSignatureShowsUpdateFailedWithSparklesMessage() {
        assertFailure(after: { $0.downloadStarted(); $0.preparingStarted(); $0.preparing(0.5) },
                      error: sparkleError(4005, "The update is improperly signed and could not be validated."),
                      shows: "The update is improperly signed and could not be validated.")
    }

    func testAFailedInstallShowsUpdateFailedWithSparklesMessage() {
        assertFailure(after: { $0.downloadStarted(); $0.preparingStarted(); $0.installStarted(applicationTerminated: false) },
                      error: sparkleError(4004, "An error occurred while relaunching Muxify, but the new version will be available next time you run Muxify."),
                      shows: "An error occurred while relaunching Muxify, but the new version will be available next time you run Muxify.")
    }

    func testATranslocatedOrReadOnlyCopySaysToMoveMuxifyToApplications() {
        for code in [1005, 1003] {
            let model = model()
            model.check()
            model.checking()
            model.failed(sparkleError(code, "Muxify can’t be updated."), acknowledge: {})
            XCTAssertEqual(model.state, .failed("Move Muxify to Applications to update it."))
            XCTAssertEqual(model.buttonText, "Update Failed")
            XCTAssertTrue(model.opensPopover)
        }
        // Another domain's error with the same code keeps its own message.
        XCTAssertEqual(UpdateModel.message(for: NSError(domain: NSCocoaErrorDomain, code: 1005,
                                                        userInfo: [NSLocalizedDescriptionKey: "Other"])), "Other")
    }

    func testSparkleEndingTheSessionAfterAFailedInstallHidesTheButton() {
        let (model, _) = installingModel()
        model.downloadStarted()
        model.failed(sparkleError(2001, "Download failed"), acknowledge: {})
        model.dismissFailure()
        model.dismissed()
        XCTAssertEqual(model.state, .idle)
        XCTAssertNil(model.buttonText)
    }

    func testOnlyABuildWithAFeedHasAnUpdater() {
        // A plain Debug or make install build: no stamp and no variable.
        XCTAssertNil(UpdateFeed(info: ["CFBundleVersion": "1"], environment: [:]))
        XCTAssertNil(UpdateFeed(info: ["MuxifyUpdateFeedBaseURL": ""], environment: ["MUXIFY_UPDATE_FEED_URL": ""]))
        let base = "https://github.com/muxify-dev/muxify/releases/download/appcast/"
        let stamped = UpdateFeed(info: ["MuxifyUpdateFeedBaseURL": base], environment: [:])
        XCTAssertEqual(stamped?.url(for: .stable)?.absoluteString, base + "stable.xml")
        XCTAssertEqual(stamped?.url(for: .tip)?.absoluteString, base + "tip.xml")
        // The variable turns the updater on in any build and replaces the feed, whatever the channel.
        let local = "http://127.0.0.1:8123/feed.xml"
        let overridden = UpdateFeed(info: ["MuxifyUpdateFeedBaseURL": base], environment: ["MUXIFY_UPDATE_FEED_URL": local])
        XCTAssertEqual(overridden?.url(for: .stable)?.absoluteString, local)
        XCTAssertEqual(overridden?.url(for: .tip)?.absoluteString, local)
        XCTAssertNotNil(UpdateFeed(info: nil, environment: ["MUXIFY_UPDATE_FEED_URL": local]))
        // The test bundle, like a plain Debug build, has none, so it offers no Check for Updates.
        XCTAssertNil(UpdateModel.shared)
    }

    // MARK: Background checks

    private var backgroundChecks = 0
    private var clock = Date(timeIntervalSince1970: 1_790_000_000)

    private func backgroundModel(starts: Bool = true) -> UpdateModel {
        let model = model()
        model.startBackgroundCheck = { [unowned self] in
            backgroundChecks += 1
            return starts
        }
        model.now = { [unowned self] in clock }
        return model
    }

    private let noUpdate = NSError(domain: "SUSparkleErrorDomain", code: 1001,
                                   userInfo: [NSLocalizedDescriptionKey: "You're up to date!"])
    private let offline = NSError(domain: "SUSparkleErrorDomain", code: 2001,
                                  userInfo: [NSLocalizedDescriptionKey: "An error occurred in retrieving update information."])

    func testTheLaunchRunsABackgroundCheckWhenTheConfigTurnsThemOn() {
        let model = backgroundModel()
        XCTAssertEqual(model.channel, .stable)
        model.apply(Config.Update())
        XCTAssertEqual(backgroundChecks, 1)
        XCTAssertEqual(checks, 0)
        XCTAssertTrue(model.checksInBackground)
        XCTAssertEqual(logged, ["update: background checks on, every 24 hours, stable channel",
                                "update: background check, stable channel"])
        // Sparkle's scheduled driver never says it is checking; the button stays hidden.
        model.checking()
        XCTAssertEqual(model.state, .idle)
        XCTAssertNil(model.buttonText)
    }

    func testCheckOffRunsNoBackgroundCheckButCheckForUpdatesStillWorks() {
        let model = backgroundModel()
        model.apply(Config.Update(check: false))
        clock += 3 * 24 * 60 * 60
        model.backgroundCheckIfDue()
        XCTAssertEqual(backgroundChecks, 0)
        XCTAssertEqual(logged, ["update: background checks off, stable channel"])
        model.check()
        XCTAssertEqual(checks, 1)
        model.checking()
        XCTAssertEqual(model.buttonText, "Checking for Updates…")
    }

    func testABackgroundCheckRunsAgainEvery24Hours() {
        let model = backgroundModel()
        model.apply(Config.Update())
        model.backgroundCheckFinished(noUpdate)
        clock += 23 * 60 * 60
        model.backgroundCheckIfDue()
        XCTAssertEqual(backgroundChecks, 1)
        clock += 60 * 60
        model.backgroundCheckIfDue()
        XCTAssertEqual(backgroundChecks, 2)
        model.backgroundCheckFinished(noUpdate)
        clock += 24 * 60 * 60
        model.backgroundCheckIfDue()
        XCTAssertEqual(backgroundChecks, 3)
    }

    func testABackgroundCheckThatFindsAnUpdateShowsOnlyUpdateAvailable() {
        let model = backgroundModel()
        model.apply(Config.Update())
        var answers: [UpdateChoice] = []
        model.found(offer) { answers.append($0) }
        XCTAssertEqual(model.buttonText, "Update Available: 0.2.0")
        XCTAssertEqual(logged.last, "update: found 0.2.0 (build 101), background check")
        // Later hides it until the next background check finds it again.
        model.later()
        XCTAssertEqual(answers, [.later])
        XCTAssertNil(model.buttonText)
        model.backgroundCheckFinished(nil)
        clock += 24 * 60 * 60
        model.backgroundCheckIfDue()
        XCTAssertEqual(backgroundChecks, 2)
        model.found(offer) { _ in }
        XCTAssertEqual(model.buttonText, "Update Available: 0.2.0")
    }

    func testABackgroundCheckThatFindsNothingOrFailsShowsNothingAndLogsIt() {
        let model = backgroundModel()
        model.apply(Config.Update())
        model.backgroundCheckFinished(noUpdate)
        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(logged.last, "update: no newer build, background check")
        clock += 24 * 60 * 60
        model.backgroundCheckIfDue()
        model.backgroundCheckFinished(offline)
        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(logged.last, "update: background check failed: An error occurred in retrieving update information."
                       + " (SUSparkleErrorDomain 2001)")
        XCTAssertFalse(model.checksInBackground)
        // The driver's not-found and error calls in a background check are acknowledged at once, never shown.
        clock += 24 * 60 * 60
        model.backgroundCheckIfDue()
        var acknowledged = 0
        model.notFound { acknowledged += 1 }
        XCTAssertEqual(model.state, .idle)
        model.backgroundCheckFinished(noUpdate)
        clock += 24 * 60 * 60
        model.backgroundCheckIfDue()
        model.failed(offline) { acknowledged += 1 }
        XCTAssertEqual(model.state, .idle)
        XCTAssertNil(model.buttonText)
        XCTAssertEqual(acknowledged, 2)
        XCTAssertEqual(logged.filter { $0.hasPrefix("update: no newer build") }.count, 2)
        XCTAssertFalse(logged.contains { $0.hasPrefix("update: failed") })
    }

    func testAFailedDownloadAfterABackgroundCheckShowsUpdateFailed() {
        let model = backgroundModel()
        model.apply(Config.Update())
        model.found(offer) { _ in }
        model.install()
        model.downloadStarted()
        model.failed(offline) {}
        XCTAssertEqual(model.buttonText, "Update Failed")
        // Sparkle ends the session after the user's OK; the background check logs nothing more.
        let count = logged.count
        model.dismissFailure()
        model.backgroundCheckFinished(offline)
        XCTAssertEqual(logged.count, count)
    }

    func testACheckTheUserStartedAfterABackgroundCheckShowsEveryState() {
        let model = backgroundModel()
        model.apply(Config.Update())
        model.backgroundCheckFinished(noUpdate)
        model.check()
        model.checking()
        XCTAssertEqual(model.buttonText, "Checking for Updates…")
        model.notFound {}
        XCTAssertEqual(model.buttonText, "No Updates Available")
        XCTAssertEqual(logged.last, "update: no newer build")
    }

    func testNoBackgroundCheckWhileTheButtonShowsSomethingOrASessionRuns() {
        let model = backgroundModel()
        model.apply(Config.Update(check: false))
        model.check()
        model.checking()
        model.apply(Config.Update())
        XCTAssertEqual(backgroundChecks, 0)
        XCTAssertEqual(logged.last, "update: no background check, the Update Button shows Checking for Updates…")
        model.notFound {}
        clock += 24 * 60 * 60
        model.backgroundCheckIfDue()
        XCTAssertEqual(backgroundChecks, 0)

        let busy = backgroundModel(starts: false)
        busy.apply(Config.Update())
        XCTAssertEqual(backgroundChecks, 1)
        XCTAssertFalse(busy.checksInBackground)
        XCTAssertEqual(logged.last, "update: no background check, a check is running")
    }

    func testAConfigReloadTurnsBackgroundChecksOffAndOn() {
        let model = backgroundModel()
        model.apply(Config.Update())
        model.backgroundCheckFinished(noUpdate)
        // The same section again, as a reload of another section applies it, changes nothing.
        model.apply(Config.Update())
        XCTAssertEqual(backgroundChecks, 1)
        model.apply(Config.Update(check: false))
        clock += 24 * 60 * 60
        model.backgroundCheckIfDue()
        XCTAssertEqual(backgroundChecks, 1)
        // Turning them on starts the schedule with a check at once.
        model.apply(Config.Update(check: true))
        XCTAssertEqual(backgroundChecks, 2)
        XCTAssertEqual(logged.last, "update: background check, stable channel")
    }

    func testAChannelChangeChecksAtOnceOnTheNewChannel() {
        let model = backgroundModel()
        model.apply(Config.Update())
        model.backgroundCheckFinished(noUpdate)
        model.apply(Config.Update(channel: .tip))
        XCTAssertEqual(model.channel, .tip)
        XCTAssertEqual(backgroundChecks, 2)
        XCTAssertEqual(logged.suffix(2), ["update: channel tip", "update: background check, tip channel"])
        model.backgroundCheckFinished(noUpdate)
        // With background checks off, a channel change checks nothing but still picks the feed.
        model.apply(Config.Update(check: false, channel: .tip))
        model.apply(Config.Update(check: false, channel: .stable))
        XCTAssertEqual(model.channel, .stable)
        XCTAssertEqual(backgroundChecks, 2)
    }
}
