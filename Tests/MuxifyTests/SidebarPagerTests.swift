import AppKit
import Observation
import SwiftUI
import XCTest
@testable import MuxifyCore

@Observable private final class PagerModel {
    var mode = SidebarMode.topics
    var animates = true
    var title = "Topics"
}

/// The pager in a borderless window that is never shown. Reduce Motion is set off: CI runners have it on.
@MainActor
final class SidebarPagerTests: XCTestCase {
    /// What each page read from its environment, by page.
    private final class Seen {
        var wraps: [String: Bool] = [:]
        var schemes: [String: ColorScheme] = [:]
        var titles: [String: String] = [:]
        /// How many times a card's body ran, on either page.
        var cards = 0
    }

    private struct Page: View {
        let id: String
        var title = ""
        let seen: Seen
        @Environment(\.wrapsCardTitles) private var wraps
        @Environment(\.colorScheme) private var scheme

        var body: some View {
            let _ = seen.wraps[id] = wraps
            let _ = seen.schemes[id] = scheme
            let _ = seen.titles[id] = title
            Button(id) {}
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier(id)
                .background {
                    VStack {
                        ForEach(0..<3) { number in Card(name: "\(id) \(number)", seen: seen) }
                        // A real Sidebar card with a Hint, which reads the Hints that change with the mode.
                        SidebarCard(isOpen: false, holdsSelection: false, mark: nil, identifier: id + "-card") {
                            CardHeader(title: id, isOpen: false, mark: nil, isPinned: true, hintTarget: Pager.hintTarget(id),
                                       summary: "") { EmptyView() }
                        } content: {
                            EmptyView()
                        } menu: {
                            EmptyView()
                        }
                    }
                }
        }
    }

    /// A card that reads the environment, as a Sidebar card does.
    private struct Card: View {
        let name: String
        let seen: Seen
        @Environment(\.wrapsCardTitles) private var wraps
        @Environment(\.colorScheme) private var scheme

        var body: some View {
            let _ = seen.cards += 1
            Text(name).lineLimit(wraps ? nil : 1).foregroundStyle(scheme == .dark ? .white : .black)
        }
    }

    private struct Pager: View {
        let model: PagerModel
        let seen: Seen

        var body: some View {
            SidebarPager(mode: Binding(get: { model.mode }, set: { model.mode = $0 }), animateSwitching: model.animates,
                         acceptsGestures: true) {
                Page(id: "topics-page", title: model.title, seen: seen)
            } sessions: {
                Page(id: "sessions-page", seen: seen)
            }
            // As in the App Window, the Hints change with the mode: the cards of the shown page have them.
            .environment(\.quickSwitchHints, hints(for: model.mode))
        }

        static func hintTarget(_ page: String) -> QuickSwitchTarget {
            page == "topics-page" ? .topic(page) : .session(page)
        }

        private func hints(for mode: SidebarMode) -> HintPresentation {
            let shown = Self.hintTarget(mode == .topics ? "topics-page" : "sessions-page")
            return HintPresentation(modifiers: .control, keybinds: .defaults,
                                    targets: QuickSwitchTargets(cards: [shown], windows: [], topicWindows: [], tabs: [],
                                                                sessions: [], topics: []),
                                    sidebar: true, browser: false, terminal: false)
        }
    }

    private static let size = NSSize(width: 200, height: 300)
    private let model = PagerModel()
    private let seen = Seen()
    private var window: NSWindow!
    private var counted = false

    override func setUp() async throws {
        _ = NSApplication.shared
        // Diagnostics turns the body counter on in the app; no Diagnostics runs here.
        counted = BodyCount.isOn
        BodyCount.isOn = true
        // Values a page reads that the window would not give it: the theme's forced scheme and a Sidebar setting.
        let root = Pager(model: model, seen: seen)
            .environment(\.wrapsCardTitles, true)
            .environment(\.colorScheme, .dark)
            .environment(\._accessibilityReduceMotion, false)
            .frame(width: Self.size.width, height: Self.size.height)
        let host = NSHostingView(rootView: root)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: .borderless, backing: .buffered,
                          defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.isReleasedWhenClosed = false
        window.contentView = host
        settle()
    }

    override func tearDown() async throws {
        window.close()
        window = nil
        BodyCount.isOn = counted
    }

    private func settle() {
        window.layoutIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        CATransaction.flush()
    }

    private var pages: SidebarPagesView { first(SidebarPagesView.self, in: window.contentView!)! }

    private func first<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        view as? T ?? view.subviews.lazy.compactMap { self.first(type, in: $0) }.first
    }

    /// Where the page shows: its frame, moved by its layer's translation.
    private func shownX(_ host: NSView) -> CGFloat {
        let layer = host.layer!
        return host.frame.minX + layer.transform.m41 - (1 - layer.transform.m11) * SidebarPagesView.center(of: layer).x
    }

    func testEachPageIsItsOwnHostingViewWithTheContainersEnvironment() {
        let hosts = pages.hosts
        XCTAssertEqual(hosts.count, 2)
        XCTAssertFalse(hosts[0] === hosts[1])
        for host in hosts { XCTAssertTrue(host.superview === pages) }
        XCTAssertEqual(hosts[0].frame, pages.bounds)
        XCTAssertEqual(hosts[1].frame, pages.bounds.offsetBy(dx: pages.bounds.width, dy: 0))
        for id in ["topics-page", "sessions-page"] {
            XCTAssertEqual(seen.wraps[id], true, "\(id) did not get the container's Sidebar setting")
            XCTAssertEqual(seen.schemes[id], .dark, "\(id) did not get the container's color scheme")
        }
    }

    func testASwipeMovesOnlyTheLayersWithoutASwiftUIUpdateOfThePages() {
        let pages = pages
        let slide = pages.slide
        let width = pages.bounds.width
        let updates = slide.updates
        for translation in [-10, -30, -55, -80] as [CGFloat] {
            slide.track(translation)
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            CATransaction.flush()
        }
        XCTAssertEqual(slide.updates, updates, "a swipe made SwiftUI update the pages container")
        XCTAssertEqual(slide.position, 0.4, accuracy: 0.0001)
        let topics = pages.hosts[0].layer!, sessions = pages.hosts[1].layer!
        XCTAssertEqual(shownX(pages.hosts[0]), -0.4 * width, accuracy: 0.001)
        XCTAssertEqual(shownX(pages.hosts[1]), 0.6 * width, accuracy: 0.001)
        XCTAssertEqual(topics.transform.m11, 1 - 0.4 * 0.025, accuracy: 0.0001)
        XCTAssertEqual(sessions.transform.m11, 1 - 0.6 * 0.025, accuracy: 0.0001)
        XCTAssertEqual(CGFloat(topics.opacity), 1 - 0.4 * 0.18, accuracy: 0.0001)
        XCTAssertEqual(CGFloat(sessions.opacity), 1 - 0.6 * 0.18, accuracy: 0.0001)
        XCTAssertNil(pages.hitTest(NSPoint(x: pages.frame.midX, y: pages.frame.midY)), "a moving page took a click")
        XCTAssertFalse(pages.hosts[0].takesInput)

        // Past the end: the rubber band holds the pages near Topics.
        slide.track(60)
        XCTAssertLessThan(slide.position, 0)
        XCTAssertGreaterThan(slide.position, -0.06)
        XCTAssertEqual(slide.updates, updates)
    }

    func testTheSettleIsTheSwiftUISpringFromWhereThePagesAre() throws {
        let pages = pages
        let slide = pages.slide
        slide.track(-80)
        let destination = slide.release(translation: -80, velocity: -2000, cancelled: false)
        XCTAssertEqual(destination, .sessions)
        slide.settle(destination)
        XCTAssertTrue(slide.isMoving)
        for host in pages.hosts {
            let layer = try XCTUnwrap(host.layer)
            let spring = try XCTUnwrap(layer.animation(forKey: "slide") as? CASpringAnimation)
            XCTAssertEqual(2 * .pi / sqrt(spring.stiffness / spring.mass), 0.34, accuracy: 0.0001)
            XCTAssertEqual(spring.damping / (2 * sqrt(spring.stiffness * spring.mass)), 0.86, accuracy: 0.0001)
            XCTAssertNotNil(layer.animation(forKey: "fade") as? CASpringAnimation)
        }
        let spring = try XCTUnwrap(pages.hosts[0].layer?.animation(forKey: "slide") as? CASpringAnimation)
        let from = try XCTUnwrap(spring.fromValue as? NSValue).caTransform3DValue
        XCTAssertEqual(from.m11, 1 - 0.4 * 0.025, accuracy: 0.0001, "the settle did not start where the swipe left the page")
        // The model is the rest it springs to: both pages whole, Topics one width to the left.
        let topics = try XCTUnwrap(pages.hosts[0].layer), sessions = try XCTUnwrap(pages.hosts[1].layer)
        XCTAssertEqual(shownX(pages.hosts[0]), -pages.bounds.width, accuracy: 0.001)
        XCTAssertEqual(shownX(pages.hosts[1]), 0, accuracy: 0.001)
        XCTAssertEqual(topics.transform.m11, 1)
        XCTAssertEqual(sessions.transform.m11, 1)
        XCTAssertEqual(topics.opacity, 1)
        XCTAssertEqual(sessions.opacity, 1)
        XCTAssertNil(pages.hitTest(NSPoint(x: pages.frame.midX, y: pages.frame.midY)), "a settling page took a click")
        #if DEBUG
        XCTAssertTrue(SidebarPagerMotion.isMoving, "the verify driver would not wait for the settle")
        #endif
        let deadline = Date().addingTimeInterval(3)
        while slide.isMoving, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertFalse(slide.isMoving, "the settle never ended")
        #if DEBUG
        XCTAssertFalse(SidebarPagerMotion.isMoving, "the pager still moves for the verify driver after the settle")
        #endif
        XCTAssertNil(pages.hosts[0].layer?.animation(forKey: "slide"))
        // At rest no page keeps a transform: the hidden page's frame is one width to the side.
        XCTAssertEqual(pages.hosts[0].frame.minX, -pages.bounds.width)
        XCTAssertEqual(pages.hosts[1].frame, pages.bounds)
        for host in pages.hosts { XCTAssertTrue(CATransform3DIsIdentity(host.layer!.transform)) }
        XCTAssertEqual(slide.presentedPosition, 1)
        XCTAssertTrue(pages.hosts[1].takesInput)
        XCTAssertFalse(pages.hosts[0].takesInput)
    }

    func testAtRestBothPagesAreWholeAndTheHiddenOneSitsAWidthAside() {
        model.animates = false
        settle()
        model.mode = .sessions
        settle()
        let pages = pages
        XCTAssertEqual(pages.slide.position, 1)
        XCTAssertFalse(pages.slide.isMoving)
        XCTAssertNil(pages.hosts[0].layer?.animation(forKey: "slide"), "the instant switch animated")
        XCTAssertEqual(pages.hosts[0].frame.minX, -pages.bounds.width)
        XCTAssertEqual(pages.hosts[1].frame, pages.bounds)
        for host in pages.hosts {
            XCTAssertTrue(CATransform3DIsIdentity(host.layer!.transform))
            XCTAssertEqual(host.layer?.opacity, 1)
        }
        // The frames reach the layers in the same turn as the transforms, so the switch shows no frame between.
        pages.slide.settle(.topics)
        XCTAssertEqual(pages.hosts[0].layer?.frame.minX, 0)
        XCTAssertEqual(pages.hosts[1].layer?.frame.minX, pages.bounds.width)
    }

    func testAnimationTurnedOffMidSwipeReturnsThePagesAtOnce() {
        let slide = pages.slide
        slide.track(-80)
        XCTAssertEqual(slide.position, 0.4, accuracy: 0.0001)
        model.animates = false
        settle()
        XCTAssertEqual(slide.position, 0)
        XCTAssertTrue(CATransform3DIsIdentity(pages.hosts[0].layer!.transform))
        slide.track(-120)
        XCTAssertEqual(slide.position, 0, "a swipe moved the pages with animation off")
    }

    /// A swipe, a committed mode and a change of motion move layers and tell AppKit which page takes input. A page's
    /// root does not depend on the mode, and a card draws the Hints that move with the mode in an overlay of its own,
    /// so no card's body runs again on either page.
    func testASwipeAndAModeCommitRunNoCardBodiesWhileNewContentStillReachesItsPage() {
        let pages = pages
        let slide = pages.slide
        let cards = seen.cards
        XCTAssertGreaterThanOrEqual(cards, 6, "the pages did not draw their cards")
        let sidebarCards = BodyCount.counts["SidebarCard", default: 0]
        XCTAssertGreaterThanOrEqual(sidebarCards, 2, "the pages did not draw their Sidebar cards")
        let updates = slide.updates
        // A swipe that commits Sessions, as `SidebarPager.select` ends it.
        for translation in [-10, -40, -80] as [CGFloat] {
            slide.track(translation)
            settle()
        }
        let destination = slide.release(translation: -80, velocity: -2000, cancelled: false)
        model.mode = destination
        slide.settle(destination)
        settle()
        // Motion turned off, then a press back to Topics.
        model.animates = false
        settle()
        model.mode = .topics
        settle()
        XCTAssertGreaterThan(slide.updates, updates, "the committed mode never reached the pages container")
        XCTAssertEqual(slide.mode, .topics)
        XCTAssertEqual(seen.cards, cards, "a swipe or a mode commit ran the cards' bodies again")
        XCTAssertEqual(BodyCount.counts["SidebarCard", default: 0], sidebarCards,
                       "the Hints that moved with the mode ran the Sidebar cards' bodies again")

        model.title = "Renamed"
        settle()
        XCTAssertEqual(seen.titles["topics-page"], "Renamed", "new content did not reach the Topics page")
    }

    /// SwiftUI builds its accessibility tree only for a client outside the app, so this checks the pages container's
    /// children, where the hidden page's tree would hang.
    func testOnlyTheShownPageIsAccessibleAndTakesHits() {
        let pages = pages
        let point = NSPoint(x: pages.bounds.midX, y: pages.bounds.midY)
        XCTAssertNil(pages.hosts[1].hitTest(pages.convert(point, to: pages.hosts[1].superview)),
                     "the hidden Sessions page took a hit-test")
        let hit = pages.hitTest(pages.convert(point, to: pages.superview))
        XCTAssertTrue(hit?.isDescendant(of: pages.hosts[0]) == true, "a click at rest did not reach the Topics page")
        XCTAssertTrue(pages.accessiblePages == [pages.hosts[0]], "the hidden Sessions page is accessible")
        XCTAssertFalse(reaches(pages.hosts[1], from: pages), "the hidden Sessions page is accessible")

        model.animates = false
        settle()
        model.mode = .sessions
        settle()
        XCTAssertNil(pages.hosts[0].hitTest(pages.convert(point, to: pages.hosts[0].superview)),
                     "the hidden Topics page took a hit-test")
        XCTAssertTrue(pages.hitTest(pages.convert(point, to: pages.superview))?.isDescendant(of: pages.hosts[1]) == true,
                      "a click at rest did not reach the Sessions page")
        XCTAssertTrue(pages.accessiblePages == [pages.hosts[1]], "the hidden Topics page is accessible")
        XCTAssertFalse(reaches(pages.hosts[0], from: pages), "the hidden Topics page is accessible")
    }

    /// Whether `view`, or an element inside it, is among the accessibility children of `container`.
    private func reaches(_ view: NSView, from container: NSView) -> Bool {
        (container.accessibilityChildren() ?? []).contains { child in
            (child as? NSView).map { $0 === view || $0.isDescendant(of: view) } ?? false
        }
    }

    #if DEBUG
    func testTheDebugElementAnswersFromAppKitWithItsLabelUpdatesAndActions() throws {
        let pages = pages
        let element = SidebarSwipeDebugView(slide: pages.slide)
        pages.addSubview(element)
        settle()
        XCTAssertTrue((pages.accessibilityChildren() ?? []).contains { ($0 as? NSView) === element },
                      "the verify driver cannot reach the Debug element")
        XCTAssertEqual(element.accessibilityIdentifier(), "sidebar-swipe-input")
        XCTAssertEqual(element.accessibilityLabel(), "Sidebar swipe input animated 0.000")
        let updates = pages.slide.updates
        pages.slide.track(-80)
        XCTAssertEqual(element.accessibilityLabel(), "Sidebar swipe input animated 0.400")
        XCTAssertEqual(element.accessibilityValue() as? String, "\(updates) updates")
        let names = element.accessibilityCustomActions()?.map(\.name) ?? []
        XCTAssertEqual(names, SidebarSwipeInputView.verificationNames)
        model.animates = false
        settle()
        XCTAssertEqual(element.accessibilityLabel(), "Sidebar swipe input instant 0.000")
    }
    #endif
}
