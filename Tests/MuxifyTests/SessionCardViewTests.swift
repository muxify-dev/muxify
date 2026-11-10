import AppKit
import XCTest
@testable import MuxifyCore

/// The motion of the cards of the AppKit Sessions list (ADR 0074), which no picture and no dump of the end-to-end
/// harness shows: the turn of the border's colours, the fade of the Working mark's spine and the glide of a card that
/// opens or closes.
@MainActor final class SessionCardViewTests: XCTestCase {
    private func card(_ content: SessionCardContent, environment: SessionsListEnvironment = SessionsListEnvironment()) -> SessionCardView {
        let card = SessionCardView(sessionID: "$1")
        card.show(content, environment: environment)
        return card
    }

    private func controlPoints(_ timing: CAMediaTimingFunction?) -> [Float] {
        (1...2).flatMap { index -> [Float] in
            var point: [Float] = [0, 0]
            timing?.getControlPoint(at: index, values: &point)
            return point
        }
    }

    func testTheBorderTurnsOnceWhenTheLocationComesToTheCard() throws {
        let card = card(SessionCardContent(title: "atlas"))
        XCTAssertNil(card.turnAnimation)

        card.show(SessionCardContent(title: "atlas", holdsSelection: true), environment: SessionsListEnvironment())

        let turn = try XCTUnwrap(card.turnAnimation as? CABasicAnimation)
        XCTAssertEqual(turn.keyPath, "transform.rotation.z")
        XCTAssertEqual(try XCTUnwrap(turn.fromValue as? Double), -150 * .pi / 180, accuracy: 0.0001)
        XCTAssertEqual(turn.toValue as? Double, 0)
        XCTAssertEqual(turn.duration, 0.9)
        XCTAssertEqual(turn.repeatCount, 0)
        XCTAssertEqual(controlPoints(turn.timingFunction), [0.18, 0.85, 0.25, 1])
    }

    func testTheBorderDoesNotTurnOnACardThatShowsWithTheLocationOnIt() {
        XCTAssertNil(card(SessionCardContent(title: "atlas", holdsSelection: true)).turnAnimation)
    }

    func testTheBorderDoesNotTurnWithReduceMotion() {
        var still = SessionsListEnvironment()
        still.reduceMotion = true
        let card = card(SessionCardContent(title: "atlas"), environment: still)

        card.show(SessionCardContent(title: "atlas", holdsSelection: true), environment: still)

        XCTAssertNil(card.turnAnimation)
    }

    func testTheSpineOfTheWorkingMarkFadesOnTheSharedClock() throws {
        let card = card(SessionCardContent(title: "atlas", mark: .agent(.working)))

        let fade = try XCTUnwrap(card.spineFade as? CAKeyframeAnimation)
        XCTAssertEqual(fade.keyPath, "opacity")
        XCTAssertEqual(fade.duration, 1.6)
        XCTAssertEqual(fade.repeatCount, .infinity)
        let values = try XCTUnwrap(fade.values as? [Double])
        XCTAssertEqual(try XCTUnwrap(values.max()), 1, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(values.min()), 0.35, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(values.first), 1, accuracy: 0.0001)
        // Where the fade stands in its period now is where the time since the reference date stands in it.
        let place = (CACurrentMediaTime() - fade.beginTime + fade.timeOffset).truncatingRemainder(dividingBy: 1.6)
        let clock = Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6)
        XCTAssertLessThan(min(abs(place - clock), 1.6 - abs(place - clock)), 0.05)
    }

    func testEverySpineFadesOnOneClock() throws {
        let first = try XCTUnwrap(card(SessionCardContent(title: "atlas", mark: .agent(.working))).spineFade)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let second = try XCTUnwrap(card(SessionCardContent(title: "birch", mark: .agent(.working))).spineFade)

        XCTAssertEqual(first.beginTime, second.beginTime)
        XCTAssertEqual(first.timeOffset, second.timeOffset)
    }

    func testTheSpineStaysStillWithoutPulseWithReduceMotionAndForAnotherMark() {
        var noPulse = SessionsListEnvironment()
        noPulse.pulses = false
        var reduced = SessionsListEnvironment()
        reduced.reduceMotion = true
        XCTAssertNil(card(SessionCardContent(title: "atlas", mark: .agent(.working)), environment: noPulse).spineFade)
        XCTAssertNil(card(SessionCardContent(title: "atlas", mark: .agent(.working)), environment: reduced).spineFade)
        XCTAssertNil(card(SessionCardContent(title: "atlas", mark: .agent(.blocked))).spineFade)
        XCTAssertNil(card(SessionCardContent(title: "atlas")).spineFade)
    }

    func testTheSpineStopsItsFadeWhenTheMarkIsNoLongerWorkingOrPulseGoesOff() {
        let card = card(SessionCardContent(title: "atlas", mark: .agent(.working)))
        XCTAssertNotNil(card.spineFade)

        card.show(SessionCardContent(title: "atlas", mark: .agent(.done)), environment: SessionsListEnvironment())
        XCTAssertNil(card.spineFade)

        card.show(SessionCardContent(title: "atlas", mark: .agent(.working)), environment: SessionsListEnvironment())
        XCTAssertNotNil(card.spineFade)
        var noPulse = SessionsListEnvironment()
        noPulse.pulses = false
        card.show(SessionCardContent(title: "atlas", mark: .agent(.working)), environment: noPulse)
        XCTAssertNil(card.spineFade)
    }

    func testAnOpenCardIsItsHeaderAndTheRoomForItsRows() {
        let closed = card(SessionCardContent(title: "atlas", summary: "1 Window"))
        let open = card(SessionCardContent(title: "atlas", summary: "1 Window", isOpen: true))
        let bare = card(SessionCardContent(title: "atlas"))

        // The title's line is 17 points high at 12, and the Summary's 14.
        XCTAssertEqual(closed.height(width: 248), 7 + 17 + 2 + 2 + 1 + 14 + 7)
        XCTAssertEqual(open.height(width: 248), 7 + 17 + 2 + 3 + 3 + 5)
        XCTAssertEqual(bare.height(width: 248), 7 + 17 + 2 + 7)
    }

    // MARK: The glide

    func testAGlideMovesTheLayersThatChangedFromWhereTheyStood() throws {
        let root = CALayer(), moved = CALayer(), still = CALayer()
        root.addSublayer(moved)
        root.addSublayer(still)
        moved.frame = CGRect(x: 0, y: 10, width: 100, height: 50)
        still.frame = CGRect(x: 0, y: 70, width: 100, height: 50)
        let from = (position: moved.position, bounds: moved.bounds)

        LayerGlide.run(under: root, duration: 0.15, timing: CAMediaTimingFunction(name: .easeOut)) {
            moved.frame = CGRect(x: 0, y: 40, width: 100, height: 80)
            moved.opacity = 0
        }

        for (key, value) in [("position", from.position as Any), ("bounds", from.bounds), ("opacity", Float(1))] {
            let glide = try XCTUnwrap(moved.animation(forKey: "glide-" + key) as? CABasicAnimation, key)
            XCTAssertEqual(glide.keyPath, key)
            XCTAssertEqual(glide.duration, 0.15)
            XCTAssertEqual(controlPoints(glide.timingFunction), controlPoints(CAMediaTimingFunction(name: .easeOut)))
            XCTAssertNil(glide.toValue, "the glide ends where the layer now is")
            switch value {
            case let point as CGPoint: XCTAssertEqual(glide.fromValue as? CGPoint, point)
            case let rect as CGRect: XCTAssertEqual(glide.fromValue as? CGRect, rect)
            default: XCTAssertEqual(glide.fromValue as? Float, 1)
            }
        }
        XCTAssertEqual(moved.frame, CGRect(x: 0, y: 40, width: 100, height: 80))
        XCTAssertNil(still.animationKeys())
    }

    func testAGlideLeavesTheAnimationsOfALayerThatDidNotMove() {
        let root = CALayer(), fading = CALayer()
        root.addSublayer(fading)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.35
        fade.duration = 10
        fading.add(fade, forKey: "fade")

        LayerGlide.run(under: root, duration: 0.15, timing: CAMediaTimingFunction(name: .easeOut)) { root.frame.size.height = 40 }

        XCTAssertEqual(fading.animationKeys(), ["fade"])
    }

    func testACardThatOpensGlidesAndTheCardsBelowMoveWithIt() throws {
        let saved = UserDefaults.standard.object(forKey: "expandedSessions")
        defer { UserDefaults.standard.set(saved, forKey: "expandedSessions") }
        let list = SessionsListView(store: WorkspaceStore(configStore: ConfigStore(path: "/nonexistent/muxify/config.yaml")),
                                    environment: SessionsListEnvironment())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = list
        list.wantsLayer = true
        defer { window.contentView = nil }
        func card(_ id: String) throws -> SessionCardView {
            func find(_ view: NSView) -> SessionCardView? {
                (view as? SessionCardView).flatMap { $0.sessionID == id ? $0 : nil } ?? view.subviews.lazy.compactMap(find).first
            }
            return try XCTUnwrap(find(list), id)
        }
        let closed = SessionCardContent(title: "atlas", summary: "1 Window")
        list.show([("$1", closed), ("$2", closed), ("$3", closed)])
        let tops = try ["$1", "$2", "$3"].map { try card($0).frame.minY }
        XCTAssertEqual(tops, [4, 60, 116])
        XCTAssertNil(try card("$3").layer?.animationKeys(), "cards that show for the first time stand in their places at once")
        // AppKit makes the layers of the hierarchy when the window draws.
        window.displayIfNeeded()

        var open = closed
        open.isOpen = true
        list.show([("$1", closed), ("$2", open), ("$3", closed)])

        // The open card has no rows yet, so it is lower than a closed one: 37 points in place of 50.
        XCTAssertEqual(try card("$2").frame, NSRect(x: 6, y: 60, width: 248, height: 37))
        XCTAssertEqual(try card("$3").frame.minY, 103)
        let grows = try XCTUnwrap(try card("$2").layer?.animation(forKey: "glide-bounds") as? CABasicAnimation)
        let moves = try XCTUnwrap(try card("$3").layer?.animation(forKey: "glide-position") as? CABasicAnimation)
        XCTAssertEqual((grows.fromValue as? CGRect)?.height, 50)
        XCTAssertEqual((moves.fromValue as? CGPoint)?.y, 116)
        for glide in [grows, moves] {
            XCTAssertEqual(glide.duration, 0.15)
            XCTAssertEqual(controlPoints(glide.timingFunction), controlPoints(CAMediaTimingFunction(name: .easeOut)))
        }
        XCTAssertNil(try card("$1").layer?.animation(forKey: "glide-position"), "the card above does not move")
    }
}
