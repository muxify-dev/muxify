import AppKit
import SwiftUI
import MuxifyCore

/// Switches the Sidebar between Topics and Sessions with buttons or horizontal swipes.
/// Both lists stay mounted to preserve their scroll positions and opened cards. Only the committed
/// mode is persisted; the gesture and its preview stay in memory, in AppKit: `SidebarSlide` moves the pages as layers,
/// so SwiftUI hears only where a swipe ends and which mode it commits.
struct SidebarPager<Topics: View, Sessions: View>: View {
    @Binding private var mode: SidebarMode
    private let animateSwitching: Bool
    private let acceptsGestures: Bool
    private let topics: Topics
    private let sessions: Sessions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.sidebarSwipeArea) private var swipeArea
    @Environment(\.interfaceFontSize) private var fontSize
    @State private var slide: SidebarSlide

    init(mode: Binding<SidebarMode>, animateSwitching: Bool, acceptsGestures: Bool,
         @ViewBuilder topics: () -> Topics, @ViewBuilder sessions: () -> Sessions) {
        _mode = mode
        self.animateSwitching = animateSwitching
        self.acceptsGestures = acceptsGestures
        _slide = State(initialValue: SidebarSlide(mode: mode.wrappedValue))
        self.topics = topics()
        self.sessions = sessions()
    }

    private var motionEnabled: Bool { animateSwitching && !reduceMotion }

    var body: some View {
        VStack(spacing: 0) {
            selector
            SidebarPages(slide: slide, topics: topics, sessions: sessions)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background {
            SidebarSwipeInput(slide: slide, area: swipeArea, isEnabled: acceptsGestures, onChange: { translation in
                slide.track(translation)
            }, onEnd: { translation, velocity, cancelled in
                select(slide.release(translation: translation, velocity: velocity, cancelled: cancelled))
            })
        }
        // Apart from the pages, so a new mode gives no page a new root.
        .onChange(of: mode) { _, mode in slide.update(mode: mode, motionEnabled: motionEnabled) }
        .onChange(of: motionEnabled, initial: true) { _, motion in slide.update(mode: mode, motionEnabled: motion) }
        #if DEBUG
        .onDisappear { SidebarPagerMotion.forget(slide) }
        #endif
    }

    private var selector: some View {
        HStack(spacing: SidebarSelectorHighlightView.spacing) {
            viewButton(.topics)
            viewButton(.sessions)
        }
        .background { SidebarSelectorHighlight(slide: slide) }
        .padding(6)
        .help("Swipe left or right with two fingers to switch Topics and Sessions")
    }

    private func viewButton(_ target: SidebarMode) -> some View {
        Button { slide.stopTracking(); select(target) } label: {
            Text(target.rawValue)
                .font(fontSize.font(11, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sidebar-view-" + target.rawValue.lowercased())
        .accessibilityValue(mode == target ? "selected" : "")
    }

    private func select(_ target: SidebarMode) {
        if mode != target { mode = target }
        slide.settle(target)
    }
}

/// Where a Sidebar swipe may begin: the whole Sidebar, with every section it shows, not only the pager.
/// `SidebarView` marks it; without a mark, the pager is the area.
final class SidebarSwipeArea {
    fileprivate weak var view: NSView?
}

extension EnvironmentValues {
    @Entry var sidebarSwipeArea: SidebarSwipeArea?
}

extension View {
    /// Makes this view the area that a Sidebar swipe may begin in.
    func sidebarSwipeArea(_ area: SidebarSwipeArea) -> some View {
        background(SidebarSwipeAreaMark(area: area)).environment(\.sidebarSwipeArea, area)
    }
}

private struct SidebarSwipeAreaMark: NSViewRepresentable {
    let area: SidebarSwipeArea

    func makeNSView(context: Context) -> NSView {
        let view = SidebarSwipeAreaView()
        area.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        area.view = view
    }
}

private final class SidebarSwipeAreaView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

#if DEBUG
/// The Sidebar pagers whose pages still slide to rest after a switch: from the start of a settle's Core Animation spring
/// to its end. A page takes no click or hover until it stops, so the verify driver holds a click, drag or hover until
/// no pager moves; sent mid-slide, it misses its row.
enum SidebarPagerMotion {
    /// The number of the latest animated settle of each moving pager.
    private static var moving: [ObjectIdentifier: Int] = [:]
    private static var settles = 0

    static var isMoving: Bool { !moving.isEmpty }

    /// Marks the pager as moving when its settle animates. A later settle takes over, so only the end of the
    /// latest one marks the pager at rest.
    static func begin(_ pager: AnyObject, animated: Bool) -> (pager: ObjectIdentifier, number: Int) {
        settles += 1
        moving[ObjectIdentifier(pager)] = animated ? settles : nil
        return (ObjectIdentifier(pager), settles)
    }

    static func end(_ settle: (pager: ObjectIdentifier, number: Int)) {
        if moving[settle.pager] == settle.number { moving[settle.pager] = nil }
    }

    /// A pager that leaves the window mid-slide is at rest.
    static func forget(_ pager: AnyObject) {
        moving[ObjectIdentifier(pager)] = nil
    }
}
#endif

/// List scroll views own vertical scrolling. Observe scroll events before AppKit dispatches them, and keep
/// only a precise, horizontally locked gesture that began inside this panel in this App Window.
private struct SidebarSwipeInput: NSViewRepresentable {
    let slide: SidebarSlide
    let area: SidebarSwipeArea?
    let isEnabled: Bool
    let onChange: (CGFloat) -> Void
    let onEnd: (CGFloat, CGFloat, Bool) -> Void

    func makeNSView(context: Context) -> SidebarSwipeInputView {
        let view = SidebarSwipeInputView()
        slide.input = view
        return view
    }

    func updateNSView(_ view: SidebarSwipeInputView, context: Context) {
        view.onChange = onChange
        view.onEnd = onEnd
        view.area = area
        view.isEnabled = isEnabled
    }
}

final class SidebarSwipeInputView: NSView {
    var isEnabled = true {
        didSet {
            if !isEnabled && tracking {
                if axis == .horizontal {
                    let end = onEnd
                    let distance = translation.x
                    // This property is updated by SwiftUI; cancel after its current update transaction finishes.
                    DispatchQueue.main.async { end(distance, 0, true) }
                }
                tracking = false
            }
        }
    }
    var onChange: (CGFloat) -> Void = { _ in }
    var onEnd: (CGFloat, CGFloat, Bool) -> Void = { _, _, _ in }
    var area: SidebarSwipeArea?
    private var monitor: Any?
    private enum Axis { case undecided, horizontal, vertical }
    private var axis = Axis.undecided
    private var tracking = false
    private var consumesMomentum = false
    private var translation = NSPoint.zero
    private var velocity: CGFloat = 0
    private var lastTime: TimeInterval = 0

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self else { return event }
                return self.handle(event)
            }
        } else if window == nil, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
            tracking = false
            consumesMomentum = false
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window, event.hasPreciseScrollingDeltas else { return event }
        if !event.momentumPhase.isEmpty {
            // One physical gesture changes at most one page. Its inertial tail must not reach either list.
            return consumesMomentum ? nil : event
        }
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            if tracking, axis == .horizontal { onEnd(translation.x, 0, true) }
            tracking = false
            consumesMomentum = false
            guard isEnabled, !isHiddenOrHasHiddenAncestor, covers(event.locationInWindow),
                  window.attachedSheet == nil else { return event }
            begin(at: event.timestamp)
        }
        guard tracking else { return event }
        let consumed = receive(x: event.scrollingDeltaX, y: event.scrollingDeltaY, time: event.timestamp,
                               ended: event.phase.contains(.ended), cancelled: event.phase.contains(.cancelled))
        return consumed ? nil : event
    }

    /// Only a swipe that begins over the Sidebar. A hosted view is not clipped, so its visible rectangle can
    /// cover the whole App Window: a swipe over the terminal or the browser must scroll there.
    private func covers(_ locationInWindow: NSPoint) -> Bool {
        let region = area?.view.flatMap { $0.window === window ? $0 : nil } ?? self
        let point = region.convert(locationInWindow, from: nil)
        return region.bounds.contains(point) && region.visibleRect.contains(point)
    }

    private func begin(at time: TimeInterval) {
        tracking = true
        consumesMomentum = false
        axis = .undecided
        translation = .zero
        velocity = 0
        lastTime = time
    }

    @discardableResult
    private func receive(x: CGFloat, y: CGFloat, time: TimeInterval, ended: Bool = false, cancelled: Bool = false) -> Bool {
        translation.x += x
        translation.y += y
        if axis == .undecided, max(abs(translation.x), abs(translation.y)) >= 7 {
            if abs(translation.x) > abs(translation.y) * 1.3 { axis = .horizontal }
            else if abs(translation.y) >= abs(translation.x) { axis = .vertical }
        }
        if axis == .horizontal {
            let elapsed = time - lastTime
            if !ended && !cancelled, elapsed > 0 {
                velocity = velocity * 0.35 + (x / max(0.008, elapsed)) * 0.65
            } else if elapsed > 0.08 {
                velocity = 0
            }
            onChange(translation.x)
        }
        lastTime = time
        let consumed = axis == .horizontal
        if ended || cancelled {
            tracking = false
            consumesMomentum = consumed
            if consumed { onEnd(translation.x, velocity, cancelled) }
        }
        return consumed
    }

    #if DEBUG
    /// The verify driver reaches the same axis lock, tracking and release path without moving the user's
    /// pointer or taking focus. This input element exists only inside a throwaway Sandbox, never in a normal launch.
    private static let verificationSamples: [(name: String, x: CGFloat, y: CGFloat, duration: TimeInterval, cancelled: Bool)] = [
        ("Swipe left", -0.65, 0, 0.3, false), ("Swipe right", 0.65, 0, 0.3, false),
        ("Short swipe left", -0.08, 0, 0.6, false), ("Short swipe right", 0.08, 0, 0.6, false),
        ("Flick left", -0.12, 0, 0.04, false), ("Flick right", 0.12, 0, 0.04, false),
        ("Cancel swipe left", -0.65, 0, 0.3, true), ("Cancel swipe right", 0.65, 0, 0.3, true),
        ("Vertical scroll", -0.1, -0.8, 0.3, false)
    ]

    /// Window points for samples that begin there, as a real swipe begins under the pointer.
    private var verificationLocations: [String: NSPoint] {
        let pager = convert(bounds, to: nil)
        let sidebar = area?.view.map { $0.convert($0.bounds, to: nil) } ?? pager
        // A point of the Sidebar outside the pager, such as the Agents section.
        let section = [NSPoint(x: sidebar.midX, y: sidebar.minY + 10), NSPoint(x: sidebar.midX, y: sidebar.maxY - 10)]
            .first { !pager.contains($0) }
        var locations = ["Swipe left beside the Sidebar": NSPoint(x: pager.maxX + 40, y: pager.midY)]
        locations["Swipe left below the Sidebar views"] = section
        return locations
    }

    static var verificationNames: [String] {
        verificationSamples.map(\.name) + ["Begin swipe left", "Cancel current swipe", "Vertical then horizontal",
                                           "Swipe left beside the Sidebar", "Swipe left below the Sidebar views"]
    }

    func verify(_ name: String) {
        guard isEnabled else { return }
        let time = ProcessInfo.processInfo.systemUptime
        if let sample = Self.verificationSamples.first(where: { $0.name == name }) {
            begin(at: time)
            for step in 1...12 {
                receive(x: bounds.width * sample.x / 12, y: bounds.width * sample.y / 12,
                        time: time + sample.duration * Double(step) / 12)
            }
            receive(x: 0, y: 0, time: time + sample.duration + 0.01, ended: !sample.cancelled, cancelled: sample.cancelled)
            return
        }
        if let location = verificationLocations[name] {
            if covers(location) { verify("Swipe left") }
            return
        }
        switch name {
        case "Begin swipe left":
            begin(at: time)
            receive(x: -bounds.width * 0.4, y: 0, time: time + 0.15)
        case "Cancel current swipe" where tracking:
            receive(x: 0, y: 0, time: lastTime + 0.15, cancelled: true)
        case "Vertical then horizontal":
            begin(at: time)
            receive(x: 0, y: -20, time: time + 0.02)
            receive(x: -bounds.width * 0.8, y: 0, time: time + 0.2)
            receive(x: 0, y: 0, time: time + 0.3, ended: true)
        default: break
        }
    }
    #endif
}
