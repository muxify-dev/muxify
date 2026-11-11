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

    // MARK: The scroll

    /// A list of closed cards in a window 400 points high, with its scroll view.
    private func list() -> (list: SessionsListView, scroll: NSScrollView, window: NSWindow) {
        let list = SessionsListView(store: WorkspaceStore(configStore: ConfigStore(path: "/nonexistent/muxify/config.yaml")),
                                    environment: SessionsListEnvironment())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = list
        let scroll = list.subviews.compactMap { $0 as? NSScrollView }.first!
        return (list, scroll, window)
    }

    private func scroll(_ scroll: NSScrollView, to y: CGFloat) {
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private let sessions = (1...20).map { "$\($0)" }
    private let closed = SessionCardContent(title: "atlas", summary: "1 Window")

    func testTheListKeepsItsOffsetInsideTheNewScrollRangeWhenItsContentChangesHeight() {
        let (list, scrollView, window) = list()
        defer { window.contentView = nil }
        let clip = scrollView.contentView
        list.show(sessions.map { ($0, closed) })
        scroll(scrollView, to: 300)

        // A card above the rows that show opens, and closes again.
        var open = closed
        open.isOpen = true
        open.moreCount = 3
        list.show(sessions.map { ($0, $0 == "$1" ? open : closed) })
        XCTAssertEqual(clip.bounds.minY, 300, "the list moved when a card above opened")
        list.show(sessions.map { ($0, closed) })
        XCTAssertEqual(clip.bounds.minY, 300, "the list moved when a card above closed")

        // Sessions end, and the content gets shorter than the offset: the list stands at the end of its new range.
        list.show(sessions.prefix(8).map { ($0, closed) })
        let height = scrollView.documentView?.frame.height ?? 0
        // 8 cards of 50 points, 7 gaps of 6 and the insets of 4.
        XCTAssertEqual(height, 450)
        XCTAssertEqual(clip.bounds.minY, height - 400)
    }

    func testTheHeaderOfAnOpenCardSticksToTheTopWhileItsRowsScrollUnder() throws {
        let (list, scrollView, window) = list()
        defer { window.contentView = nil }
        var open = closed
        open.isOpen = true
        open.moreCount = 3
        list.show(sessions.map { ($0, $0 == "$2" ? open : closed) })
        let card = try XCTUnwrap(scrollView.documentView?.subviews.compactMap { $0 as? SessionCardView }
            .first { $0.sessionID == "$2" })
        let header = try XCTUnwrap(card.subviews.first { $0.accessibilityIdentifier() == "session-$2" })
        let headerHeight = header.frame.height
        XCTAssertEqual(card.frame.minY, 60)

        scroll(scrollView, to: 50)
        XCTAssertEqual(header.frame.minY, 0, "the card's top shows, and its header moved")
        scroll(scrollView, to: 70)
        XCTAssertEqual(header.frame.minY, 10, "the header did not stay at the top of the list")
        scroll(scrollView, to: 300)
        XCTAssertEqual(header.frame.minY, card.frame.height - headerHeight - StuckHeader.gap, "the header passed the card's last row")
        XCTAssertEqual(card.accessibilityChildrenInNavigationOrder()?.first as? NSView, header,
                       "the header is not first for VoiceOver")
        let above = try XCTUnwrap(card.subviews.firstIndex(of: header))
        let rows = try XCTUnwrap(card.subviews.firstIndex { $0.subviews.contains { $0.accessibilityIdentifier() == "session-$2-more" } })
        XCTAssertGreaterThan(above, rows, "the header is not above the rows")

        // A closed card's header stands at its top.
        list.show(sessions.map { ($0, closed) })
        XCTAssertEqual(header.frame.minY, 0)
    }

    // MARK: The Hints

    private let windowRow = WindowRowContent(
        window: TmuxWindow(id: "@1", sessionID: "$1", sessionName: "atlas", index: 0, name: "editor", paneTitle: "editor",
                           path: "/work/app", command: "zsh", isActive: true, paneCount: 1, hasBell: false,
                           sessionActivity: 0, agent: "", storedBrowser: StoredBrowser(), openRequests: []),
        formatted: SidebarFormats.WindowRowContent(text: .init(title: "editor", summary: ""), left: nil, right: nil))

    /// The Hints of a list with the card `$1` and its Window `@1` first, while the user holds `modifiers`. Cards show
    /// their keys at all times, and Window rows when `windows` says so.
    private func environment(holding modifiers: KeyTrigger.Modifiers?, windows: Bool = false) -> SessionsListEnvironment {
        var config = Config.Hints()
        config.windows.always = windows
        var environment = SessionsListEnvironment()
        environment.hints = HintPresentation(
            modifiers: modifiers, keybinds: .defaults,
            targets: QuickSwitchTargets(cards: [.session("$1")], windows: [.window("@1")], topicWindows: [], tabs: [], sessions: [], topics: []),
            sidebar: true, browser: false, terminal: false, config: config)
        return environment
    }

    private func child(_ identifier: String, of card: SessionCardView) -> NSView? {
        (card.accessibilityChildren() as? [NSView])?.first { $0.accessibilityIdentifier() == identifier }
    }

    func testWhileTheBadgeShowsTheLockHidesAndTheTitleKeepsItsLines() throws {
        func shown(holding modifiers: KeyTrigger.Modifiers?) -> SessionCardView {
            let environment = environment(holding: modifiers)
            let card = card(SessionCardContent(title: "a Session whose title is long enough to wrap", isLocked: true,
                                               hint: CardHint(.session("$1"), in: environment.hints)), environment: environment)
            card.frame = NSRect(x: 0, y: 0, width: 200, height: card.height(width: 200))
            return card
        }
        let rest = shown(holding: nil), held = shown(holding: .control)

        XCTAssertGreaterThan(rest.titleFrame.height, 20, "the title does not wrap, so the test proves nothing")
        XCTAssertEqual(held.titleFrame, rest.titleFrame, "the title wraps again when the badge shows")
        XCTAssertEqual(held.height(width: 200), rest.height(width: 200))
        XCTAssertEqual(rest.markOpacity, 1)
        XCTAssertEqual(held.markOpacity, 0, "the lock shows while the badge shows")

        let key = try XCTUnwrap(child("hint-session-$1", of: rest))
        let badge = try XCTUnwrap(child("hint-session-$1", of: held))
        XCTAssertEqual(key.accessibilityValue() as? String, "1")
        XCTAssertEqual(badge.accessibilityValue() as? String, "⌃1")
        XCTAssertEqual(badge.frame.maxX, key.frame.maxX, "the badge does not end where the key at rest ends")
        XCTAssertEqual(badge.frame.midY, key.frame.midY)
        XCTAssertGreaterThan(badge.frame.width, key.frame.width, "the badge does not grow over the title")
        XCTAssertEqual((held.accessibilityChildren() as? [NSView])?.filter { $0.accessibilityIdentifier() == "hint-session-$1" }.count, 1,
                       "the key at rest stays beside the badge")
    }

    func testACardWithNoHintKeepsNoRoomForOne() {
        let hinted = card(SessionCardContent(title: "atlas", hint: CardHint(.session("$1"), in: environment(holding: nil).hints)))
        let bare = card(SessionCardContent(title: "atlas"))
        hinted.frame = NSRect(x: 0, y: 0, width: 248, height: hinted.height(width: 248))
        bare.frame = hinted.frame

        XCTAssertNil(CardHint(.session("$9"), in: environment(holding: nil).hints))
        XCTAssertNil(child("hint-session-$1", of: bare))
        XCTAssertNotNil(child("hint-session-$1", of: hinted))
    }

    func testAWindowRowsHintStandsInTheRoomBeforeItsIconWhileTheCardIsOpen() throws {
        for (modifiers, value) in [(nil, "1"), (KeyTrigger.Modifiers.command, "⌘1")] {
            let environment = environment(holding: modifiers, windows: true)
            let card = card(SessionCardContent(title: "atlas", isOpen: true, rows: [.window(windowRow)]), environment: environment)
            card.frame = NSRect(x: 0, y: 0, width: 248, height: card.height(width: 248))

            let hint = try XCTUnwrap(child("hint-window-@1", of: card), "no Hint for the Window row while holding \(String(describing: modifiers))")
            XCTAssertEqual(hint.accessibilityValue() as? String, value)
            let row = try XCTUnwrap(child("session-window-@1", of: card)?.superview)
            let corner = row.convert(NSPoint.zero, to: card)
            XCTAssertEqual(hint.frame.origin, NSPoint(x: corner.x + WindowHintMetrics.inset, y: corner.y + WindowHintMetrics.inset))
            XCTAssertEqual((card.accessibilityChildren() as? [NSView])?.suffix(2).map { $0.accessibilityIdentifier() },
                           ["session-$1", "hint-window-@1"], "the Hint is not after the header")

            card.show(SessionCardContent(title: "atlas", rows: []), environment: environment)
            XCTAssertNil(child("hint-window-@1", of: card), "a closed card shows the Hint of a Window row")
        }
    }

    // MARK: The empty state, the Sidebar font family and the theme

    /// The labels under `view` that show `text`.
    private func labels(_ text: String, in view: NSView) -> [SidebarLabel] {
        ((view as? SidebarLabel).flatMap { $0.text == text ? [$0] : nil } ?? []) + view.subviews.flatMap { labels(text, in: $0) }
    }

    private func rgb(_ color: CGColor?) throws -> [CGFloat] {
        let color = try XCTUnwrap(color?.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil))
        return (color.components ?? []).prefix(3).map { ($0 * 255).rounded() }
    }

    func testWithNoWindowTheListSaysSoInItsMiddleInTheFontOfAWindowRowsTitle() throws {
        let (list, _, window) = list()
        defer { window.contentView = nil }
        var environment = SessionsListEnvironment()
        environment.typography = SidebarTypography(fontSize: InterfaceFontSize(18))
        list.environment = environment

        let label = try XCTUnwrap(labels("No windows", in: list).first, "a store with no Window does not say so")
        XCTAssertEqual(label.font, environment.typography.nsFont(for: .title))
        XCTAssertEqual(label.ink, .secondary)
        XCTAssertEqual(label.accessibilityRole(), .staticText)
        XCTAssertEqual(label.accessibilityValue() as? String, "No windows")
        XCTAssertEqual(label.frame.midX, 130, accuracy: 0.5)
        XCTAssertEqual(label.frame.midY, 200, accuracy: 0.5)
        XCTAssertEqual(label.frame.height, label.lineHeight, "the text does not show on one line")
    }

    func testTheTitlesOfACardAndOfItsWindowRowsFollowTheSidebarFontFamily() throws {
        let family = "Helvetica Neue"
        var environment = SessionsListEnvironment()
        environment.typography = SidebarTypography(fontSize: InterfaceFontSize(18), fontFamily: family)
        var row = windowRow
        row.isSelected = true
        let card = card(SessionCardContent(title: "atlas", isOpen: true, holdsSelection: true, rows: [.window(row)]),
                        environment: environment)
        card.frame = NSRect(x: 0, y: 0, width: 248, height: card.height(width: 248))

        for (text, role) in [("atlas", SidebarTypography.Role.session), ("editor", .title)] {
            let label = try XCTUnwrap(labels(text, in: card).first, text)
            XCTAssertEqual(label.font.familyName, family, text)
            // The font of the SwiftUI list's text: `font(for:)` looks the family up as `nsFont(for:)` does, for the
            // nearest weight it has.
            XCTAssertEqual(label.font, environment.typography.nsFont(for: role), text)
            XCTAssertEqual(label.font.pointSize, environment.typography.size(for: role), text)
        }
    }

    func testTheListTakesTheLightnessOfTheGhosttyThemeAndFollowsAChange() throws {
        let (list, _, window) = list()
        defer { window.contentView = nil }
        window.appearance = NSAppearance(named: .aqua)
        let dark = TerminalTheme(background: NSColor(srgbRed: 0.1, green: 0.1, blue: 0.12, alpha: 1), foreground: .white)
        let light = TerminalTheme(background: NSColor(srgbRed: 0.96, green: 0.96, blue: 0.95, alpha: 1), foreground: .black)
        let label = try XCTUnwrap(labels("No windows", in: list).first)
        var environment = SessionsListEnvironment()
        for (theme, isDark) in [(dark, true), (light, false), (dark, true)] {
            environment.chromeTheme = theme
            list.environment = environment
            XCTAssertEqual(label.effectiveAppearance.isDark, isDark, "the list does not follow a change to a \(isDark ? "dark" : "light") theme")
        }
        // Without a theme, the list takes the system's appearance, which the App Window has.
        environment.chromeTheme = nil
        list.environment = environment
        XCTAssertFalse(label.effectiveAppearance.isDark)
        window.appearance = NSAppearance(named: .darkAqua)
        XCTAssertTrue(label.effectiveAppearance.isDark, "the list does not follow the system appearance")
    }

    func testTheFillAndTheAgentColoursOfACardFollowAChangeOfTheAppearance() throws {
        let (list, _, window) = list()
        defer { window.contentView = nil }
        var environment = SessionsListEnvironment()
        environment.agentColors.working = .pair(light: .rgb(red: 255, green: 0, blue: 0), dark: .rgb(red: 0, green: 0, blue: 255))
        list.environment = environment
        list.show([("$1", SessionCardContent(title: "atlas", isOpen: true, mark: .agent(.working)))])
        func find(_ view: NSView) -> SessionCardView? { (view as? SessionCardView) ?? view.subviews.lazy.compactMap(find).first }
        let card = try XCTUnwrap(find(list))
        let fill = try XCTUnwrap(card.subviews.compactMap { $0 as? CardFillView }.first?.layer?.sublayers?.first)
        let spine = try XCTUnwrap(card.subviews.compactMap { $0 as? CardSpineView }.first?.layer?.sublayers?.first)

        window.appearance = NSAppearance(named: .aqua)
        XCTAssertEqual(try rgb(spine.backgroundColor), [255, 0, 0], "the light appearance shows the light colour of the pair")
        XCTAssertEqual(try rgb(fill.backgroundColor), [0, 0, 0], "the light appearance fills the card with dark text's colour")
        window.appearance = NSAppearance(named: .darkAqua)
        XCTAssertEqual(try rgb(spine.backgroundColor), [0, 0, 255], "the dark appearance shows the dark colour of the pair")
        XCTAssertEqual(try rgb(fill.backgroundColor), [255, 255, 255], "the dark appearance fills the card with light text's colour")
    }
}

extension TerminalTheme {
    /// A theme of two colours, as a Ghostty config with only `background` and `foreground` gives it.
    init(background: NSColor, foreground: NSColor) {
        self.background = background
        self.foreground = foreground
        ansi = []
    }
}
