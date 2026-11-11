import AppKit
import SwiftUI
import MuxifyCore

/// Where the Sidebar pager's pages are: 0 shows Topics, 1 shows Sessions, and a value past either end is the rubber
/// band. It lives in AppKit, and a swipe and the settle after it move only layers, so SwiftUI hears only the committed
/// mode (docs/adr/0074-motion-that-runs-every-frame-goes-through-core-animation.md).
@MainActor
final class SidebarSlide {
    weak var pages: SidebarPagesView?
    weak var highlight: SidebarSelectorHighlightView?
    weak var input: SidebarSwipeInputView?
    /// The mode SwiftUI last committed.
    private(set) var mode: SidebarMode
    private(set) var motionEnabled = true
    /// Where the pages are, or where the running settle takes them.
    private(set) var position: CGFloat
    /// Where the swipe that tracks began.
    private(set) var origin: CGFloat?
    /// The number of the settle that runs.
    private var settling: Int?
    private var motions = 0
    #if DEBUG
    /// How many times SwiftUI updated the pages container: the verify driver bounds it per swipe.
    var updates = 0
    #endif

    init(mode: SidebarMode) {
        self.mode = mode
        position = mode.rest
    }

    /// A swipe tracks or a settle runs. SwiftUI geometry, hit-testing and accessibility frames do not see a layer
    /// transform, so neither page takes a click or hover while it moves.
    var isMoving: Bool { origin != nil || settling != nil }

    private var width: CGFloat { max(1, pages?.bounds.width ?? 1) }

    /// SwiftUI's committed mode and `motionEnabled`, from each update of the pages container.
    func update(mode newMode: SidebarMode, motionEnabled newMotion: Bool) {
        let modeChanged = newMode != mode
        let motionChanged = newMotion != motionEnabled
        mode = newMode
        motionEnabled = newMotion
        if modeChanged {
            origin = nil
            settle(newMode)
        } else if motionChanged {
            settle(newMode)
        }
    }

    /// The swipe moved by `translation` points since it began.
    func track(_ translation: CGFloat) {
        if origin == nil { origin = mode.rest }
        defer { refreshInput() }
        guard motionEnabled else { return }
        let proposed = (origin ?? 0) - translation / width
        // A little resistance at either end, rather than wrapping the two views around.
        position = proposed < 0 ? Self.rubberBand(proposed) : proposed > 1 ? 1 + Self.rubberBand(proposed - 1) : proposed
        settling = nil
        render(.jump)
    }

    /// The mode the swipe ends on: the next one when it went far or fast enough, else the one it began on.
    func release(translation: CGFloat, velocity: CGFloat, cancelled: Bool) -> SidebarMode {
        let start = origin ?? mode.rest
        let travel = -translation / width
        let projected = travel - velocity * 0.16 / width
        let advances = !cancelled && abs(travel) > 0.035 && abs(projected) > 0.22
        let destination = advances ? min(1, max(0, start + (projected > 0 ? 1 : -1))) : start
        origin = nil
        return destination == 0 ? .topics : .sessions
    }

    /// A press of a header button ends the swipe that tracks.
    func stopTracking() {
        origin = nil
        refreshInput()
    }

    /// Slides the pages to `target`: a Core Animation spring with motion, at once without it.
    func settle(_ target: SidebarMode) {
        let destination = target.rest
        defer { refreshInput() }
        // A press settles twice, from select and from the mode change. The second has nothing to move, and its
        // animation would end at once while the first still slides.
        guard position != destination else {
            // Motion turned off mid-settle: the pages are at rest at once.
            if !motionEnabled, settling != nil {
                settling = nil
                render(.jump)
            }
            return
        }
        let from = presentedPosition
        position = destination
        motions += 1
        let number = motions
        #if DEBUG
        let motion = SidebarPagerMotion.begin(self, animated: motionEnabled)
        #endif
        guard motionEnabled else {
            settling = nil
            render(.jump)
            return
        }
        settling = number
        CATransaction.begin()
        // Runs when the springs end, or when a swipe or a later settle removes them.
        CATransaction.setCompletionBlock { [weak self] in
            #if DEBUG
            SidebarPagerMotion.end(motion)
            #endif
            guard let self, self.settling == number else { return }
            self.settling = nil
            // At rest: the shown page's frame is the view, and no page keeps a transform.
            self.render(.keep)
            self.refreshInput()
        }
        render(.spring(from: from))
        CATransaction.commit()
    }

    /// The position the pages show now, mid-settle included.
    var presentedPosition: CGFloat {
        guard settling != nil, let pages, let layer = pages.hosts.first?.layer, let shown = layer.presentation() else {
            return position
        }
        let translation = shown.transform.m41 - (1 - shown.transform.m11) * SidebarPagesView.center(of: layer).x
        // Adding zero turns -0, which would print as "-0.000", into 0.
        return CGFloat(pages.restPage) - translation / width + 0
    }

    /// The pages and the header's highlight follow `position` again after a layout.
    func layOut() {
        render(.keep)
        refreshInput()
    }

    enum Motion: Equatable {
        /// Puts the layers at `position` at once, and stops a running settle.
        case jump
        /// Springs the layers from `from` to `position`.
        case spring(from: CGFloat)
        /// Puts the layers at `position` and leaves a running settle alone, as a layout does.
        case keep
    }

    private func render(_ motion: Motion) {
        withoutActions {
            pages?.place(at: position, motion)
            highlight?.place(at: position, motion)
        }
    }

    private func refreshInput() {
        pages?.refreshInput(shownPage: isMoving ? nil : Int(position.rounded()))
    }

    /// How a page looks at `distance` from the position, in pages. It shrinks a little and fades as it slides away,
    /// and is whole again once it is all out of view, so the page that does not show is never shrunk: it rests one
    /// width to the side at scale 1 and opacity 1. SwiftUI once scaled the page itself, and its list then scrolled on a
    /// grid of 1.95 pixels a point that SwiftUI's animated scrollTo never reached (`DisplayLinkProbe`). A layer
    /// transform is invisible to the scroll view, so that cannot come back, but a page at rest still shows whole.
    static func look(distance: CGFloat) -> (scale: CGFloat, opacity: CGFloat) {
        guard distance < 1 else { return (1, 1) }
        return (1 - distance * 0.025, 1 - min(1, distance) * 0.18)
    }

    /// The look a settle springs a page to: a page that leaves the view shrinks and fades all the way out, and is
    /// whole again only when the spring ends. A page that was already out of view stays whole.
    static func target(distance: CGFloat, from start: CGFloat) -> (scale: CGFloat, opacity: CGFloat) {
        guard distance >= 1, start < 1 else { return look(distance: distance) }
        return (1 - 0.025, 1 - 0.18)
    }

    /// SwiftUI's `.spring(response: 0.34, dampingFraction: 0.86)`, as a Core Animation spring of unit mass.
    static func spring(_ keyPath: String, from: Any, to: Any) -> CASpringAnimation {
        let spring = CASpringAnimation(keyPath: keyPath)
        spring.mass = 1
        spring.stiffness = pow(2 * .pi / response, 2)
        spring.damping = 2 * dampingFraction * sqrt(spring.stiffness)
        spring.fromValue = from
        spring.toValue = to
        spring.duration = spring.settlingDuration
        return spring
    }

    static let response: CGFloat = 0.34
    static let dampingFraction: CGFloat = 0.86

    private static func rubberBand(_ distance: CGFloat) -> CGFloat {
        distance * 0.25 / (1 + abs(distance) * 4)
    }

    #if DEBUG
    var debugLabel: String {
        "Sidebar swipe input " + (motionEnabled ? "animated " : "instant ") + String(format: "%.3f", Double(presentedPosition))
    }
    #endif
}

extension SidebarMode {
    /// The pager's position at rest on this mode.
    var rest: CGFloat { self == .topics ? 0 : 1 }
}

/// The two Sidebar pages, each in its own `NSHostingView`, in an AppKit view that the pager places once. Each page's
/// root gets this container's whole SwiftUI environment, so a value set above the pager reaches the page unchanged.
/// Both stay mounted, so each keeps its scroll position and open cards.
struct SidebarPages<Topics: View, Sessions: View>: NSViewRepresentable {
    let slide: SidebarSlide
    let mode: SidebarMode
    let motionEnabled: Bool
    let topics: Topics
    let sessions: Sessions

    func makeNSView(context: Context) -> SidebarPagesView {
        SidebarPagesView(slide: slide)
    }

    func updateNSView(_ view: SidebarPagesView, context: Context) {
        #if DEBUG
        slide.updates += 1
        #endif
        slide.pages = view
        view.hosts[0].rootView = page(topics, .topics, context.environment)
        view.hosts[1].rootView = page(sessions, .sessions, context.environment)
        slide.update(mode: mode, motionEnabled: motionEnabled)
    }

    private func page(_ content: some View, _ target: SidebarMode, _ environment: EnvironmentValues) -> AnyView {
        AnyView(content
            .environment(\.self, environment)
            .allowsHitTesting(mode == target)
            .accessibilityHidden(mode != target))
    }
}

final class SidebarPagesView: NSView {
    let slide: SidebarSlide
    /// Topics, then Sessions.
    let hosts = [SidebarPageHost(rootView: AnyView(EmptyView())), SidebarPageHost(rootView: AnyView(EmptyView()))]

    init(slide: SidebarSlide) {
        self.slide = slide
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = true
        for host in hosts {
            // The container sets the frame; a host that measures its page for constraints only costs time.
            host.sizingOptions = []
            host.safeAreaRegions = []
            host.wantsLayer = true
            addSubview(host)
        }
        slide.pages = self
        slide.layOut()
        #if DEBUG
        if TestDriver.isRunning { addSubview(SidebarSwipeDebugView(slide: slide)) }
        #endif
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// A host may make its layer only once it is in a window, so the layers take their place again there.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layer?.masksToBounds = true
        slide.layOut()
    }

    /// SwiftUI sizes this view without asking for a layout, so a new size places the pages at once.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        placePages()
    }

    override func layout() {
        super.layout()
        placePages()
    }

    private func placePages() {
        #if DEBUG
        for view in subviews where view is SidebarSwipeDebugView {
            view.frame = NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: 1)
        }
        #endif
        slide.layOut()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        slide.isMoving ? nil : super.hitTest(point)
    }

    /// The page of the committed mode. The other one is out of the accessibility tree, as its root's
    /// `accessibilityHidden` also says.
    var accessiblePages: [SidebarPageHost] { [hosts[slide.mode == .topics ? 0 : 1]] }

    override func accessibilityChildren() -> [Any]? {
        NSAccessibility.unignoredChildren(from: accessiblePages + subviews.filter { !($0 is SidebarPageHost) })
    }

    /// Only the page at rest in view takes clicks and hover.
    func refreshInput(shownPage: Int?) {
        for (index, host) in hosts.enumerated() { host.takesInput = index == shownPage }
    }

    /// The page that rests in view. Its frame is this view's bounds, and the other page's frame is one width to the
    /// side, so a page at rest has no transform: AppKit drops a view's layer transform in some paths, such as
    /// `cacheDisplay`. It changes only at rest, so while the pages move their transforms are from these frames.
    private(set) var restPage = 0

    /// Each page translated to its place for `position`, shrunk and faded by its distance from it.
    func place(at position: CGFloat, _ motion: SidebarSlide.Motion) {
        let width = bounds.width
        if !slide.isMoving { restPage = Int(min(1, max(0, position.rounded()))) }
        // From the page's frame to where `position` shows it: the same for both pages.
        let shift = { (position: CGFloat) in (CGFloat(self.restPage) - position) * width }
        for (index, host) in hosts.enumerated() {
            let frame = bounds.offsetBy(dx: CGFloat(index - restPage) * width, dy: 0)
            if host.frame != frame { host.frame = frame }
            guard let layer = host.layer else { continue }
            let page = CGFloat(index)
            let center = Self.center(of: layer)
            let look = SidebarSlide.look(distance: abs(position - page))
            layer.transform = Self.transform(shift(position), scale: look.scale, center: center)
            layer.opacity = Float(look.opacity)
            switch motion {
            case .keep:
                break
            case .jump:
                layer.removeAnimation(forKey: "slide")
                layer.removeAnimation(forKey: "fade")
            case .spring(let from):
                let start = SidebarSlide.look(distance: abs(from - page))
                let end = SidebarSlide.target(distance: abs(position - page), from: abs(from - page))
                layer.add(SidebarSlide.spring("transform",
                                              from: NSValue(caTransform3D: Self.transform(shift(from), scale: start.scale, center: center)),
                                              to: NSValue(caTransform3D: Self.transform(shift(position), scale: end.scale, center: center))),
                          forKey: "slide")
                layer.add(SidebarSlide.spring("opacity", from: Float(start.opacity), to: Float(end.opacity)), forKey: "fade")
            }
        }
    }

    /// A translation by `x` and a scale about `center`, the layer's centre from its anchor point.
    static func transform(_ x: CGFloat, scale: CGFloat, center: CGPoint) -> CATransform3D {
        var transform = CATransform3DIdentity
        transform.m11 = scale
        transform.m22 = scale
        transform.m41 = x + (1 - scale) * center.x
        transform.m42 = (1 - scale) * center.y
        return transform
    }

    /// The layer's centre from its anchor point, where a transform applies.
    static func center(of layer: CALayer) -> CGPoint {
        CGPoint(x: (0.5 - layer.anchorPoint.x) * layer.bounds.width, y: (0.5 - layer.anchorPoint.y) * layer.bounds.height)
    }
}

/// A Sidebar page's host. Only the page at rest in view takes clicks and hover: while the pages move, their rows
/// are not where AppKit and SwiftUI think they are.
final class SidebarPageHost: NSHostingView<AnyView> {
    var takesInput = true
    override func hitTest(_ point: NSPoint) -> NSView? {
        takesInput ? super.hitTest(point) : nil
    }

    override func mouseMoved(with event: NSEvent) {
        if takesInput { super.mouseMoved(with: event) }
    }

    override func mouseEntered(with event: NSEvent) {
        if takesInput { super.mouseEntered(with: event) }
    }
}

/// The highlight behind the selected header button. It follows the swipe, so it moves as a layer, as the pages do.
struct SidebarSelectorHighlight: NSViewRepresentable {
    let slide: SidebarSlide

    func makeNSView(context: Context) -> SidebarSelectorHighlightView {
        SidebarSelectorHighlightView(slide: slide)
    }

    func updateNSView(_ view: SidebarSelectorHighlightView, context: Context) {
        slide.highlight = view
        let color = Color.primary.opacity(0.1).resolve(in: context.environment).cgColor
        if view.bar.backgroundColor != color { withoutActions { view.bar.backgroundColor = color } }
    }
}

final class SidebarSelectorHighlightView: NSView {
    let bar = CALayer()
    private let slide: SidebarSlide
    static let spacing: CGFloat = 4

    init(slide: SidebarSlide) {
        self.slide = slide
        super.init(frame: .zero)
        wantsLayer = true
        bar.cornerRadius = 5
        bar.anchorPoint = .zero
        layer?.addSublayer(bar)
        setAccessibilityElement(false)
        slide.highlight = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if bar.superlayer == nil { layer?.addSublayer(bar) }
        slide.layOut()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        placeBar()
    }

    override func layout() {
        super.layout()
        placeBar()
    }

    private func placeBar() {
        withoutActions { bar.bounds = CGRect(x: 0, y: 0, width: (bounds.width - Self.spacing) / 2, height: bounds.height) }
        slide.layOut()
    }

    /// Under the header button of `position`, held at either end through the rubber band.
    func place(at position: CGFloat, _ motion: SidebarSlide.Motion) {
        let step = bar.bounds.width + Self.spacing
        let x = min(1, max(0, position)) * step
        bar.position = CGPoint(x: x, y: 0)
        switch motion {
        case .keep:
            break
        case .jump:
            bar.removeAnimation(forKey: "slide")
        case .spring(let from):
            bar.add(SidebarSlide.spring("position.x", from: min(1, max(0, from)) * step, to: x), forKey: "slide")
        }
    }
}

#if DEBUG
/// The Debug `sidebar-swipe-input` element of the verify driver. AppKit answers its label when the driver reads it,
/// so a swipe costs SwiftUI no update. Its label is "Sidebar swipe input animated|instant <position>", the position
/// the pages show; its value is "<n> updates", how many times SwiftUI updated the pages container; and its actions
/// are the swipe samples of `SidebarSwipeInputView.verify(_:)`.
final class SidebarSwipeDebugView: NSView {
    private weak var slide: SidebarSlide?

    init(slide: SidebarSlide) {
        self.slide = slide
        super.init(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("sidebar-swipe-input")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func accessibilityLabel() -> String? { slide?.debugLabel }

    override func accessibilityValue() -> Any? { slide.map { "\($0.updates) updates" } }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        SidebarSwipeInputView.verificationNames.map { name in
            NSAccessibilityCustomAction(name: name) { [weak self] in
                self?.slide?.input?.verify(name)
                return true
            }
        }
    }
}
#endif
