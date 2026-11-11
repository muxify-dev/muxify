import XCTest

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

    func testOnlyABuildWithAFeedHasAnUpdater() {
        // A plain Debug or make install build: no stamp and no variable.
        XCTAssertNil(UpdateFeed.url(info: ["CFBundleVersion": "1"], environment: [:]))
        XCTAssertNil(UpdateFeed.url(info: ["MuxifyUpdateFeedBaseURL": ""], environment: ["MUXIFY_UPDATE_FEED_URL": ""]))
        let base = "https://github.com/muxify-dev/muxify/releases/download/appcast/"
        XCTAssertEqual(UpdateFeed.url(info: ["MuxifyUpdateFeedBaseURL": base], environment: [:])?.absoluteString,
                       base + "stable.xml")
        // The variable turns the updater on in any build and replaces the feed.
        XCTAssertEqual(UpdateFeed.url(info: ["MuxifyUpdateFeedBaseURL": base],
                                      environment: ["MUXIFY_UPDATE_FEED_URL": "http://127.0.0.1:8123/feed.xml"])?.absoluteString,
                       "http://127.0.0.1:8123/feed.xml")
        XCTAssertNotNil(UpdateFeed.url(info: nil, environment: ["MUXIFY_UPDATE_FEED_URL": "http://127.0.0.1:8123/feed.xml"]))
        // The test bundle, like a plain Debug build, has none, so it offers no Check for Updates.
        XCTAssertNil(UpdateModel.shared)
    }
}
