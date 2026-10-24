import AppKit
import SwiftUI
import MuxifyCore

/// PROTOTYPE: does a finger-following, Arc-style pager feel right between the existing Sidebar views?
/// Both lists stay mounted so their scroll positions and opened cards survive a swipe. Only the committed
/// mode uses the app's existing preference; the gesture and its preview live entirely in memory.
struct SidebarSwipePrototype<Topics: View, Sessions: View>: View {
    @Binding private var mode: SidebarMode
    private let acceptsGestures: Bool
    private let topics: Topics
    private let sessions: Sessions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var position: CGFloat
    @State private var origin: CGFloat?
    @State private var input = SidebarSwipeProbe()

    init(mode: Binding<SidebarMode>, acceptsGestures: Bool,
         @ViewBuilder topics: () -> Topics, @ViewBuilder sessions: () -> Sessions) {
        _mode = mode
        self.acceptsGestures = acceptsGestures
        _position = State(initialValue: mode.wrappedValue == .topics ? 0 : 1)
        self.topics = topics()
        self.sessions = sessions()
    }

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            let displayedPosition = reduceMotion ? (mode == .topics ? CGFloat(0) : 1) : position
            VStack(spacing: 0) {
                selector
                ZStack(alignment: .topLeading) {
                    page(topics, mode: .topics, index: 0, width: width)
                        .offset(x: -displayedPosition * width)
                    page(sessions, mode: .sessions, index: 1, width: width)
                        .offset(x: (1 - displayedPosition) * width)
                }
                .frame(width: width)
                .frame(maxHeight: .infinity, alignment: .topLeading)
                .clipped()
                .contentShape(Rectangle())
            }
            .background {
                SidebarSwipeInput(probe: input, isEnabled: acceptsGestures, onChange: { translation in
                    if origin == nil { origin = mode == .topics ? 0 : 1 }
                    let proposed = (origin ?? 0) - translation / width
                    // A little resistance at either end, rather than wrapping the two views around.
                    position = proposed < 0 ? rubberBand(proposed) : proposed > 1 ? 1 + rubberBand(proposed - 1) : proposed
                }, onEnd: { translation, velocity, cancelled in
                    let start = origin ?? (mode == .topics ? 0 : 1)
                    let travel = -translation / width
                    let projected = travel - velocity * 0.16 / width
                    let advances = !cancelled && abs(travel) > 0.035 && abs(projected) > 0.22
                    let destination = advances ? min(1, max(0, start + (projected > 0 ? 1 : -1))) : start
                    origin = nil
                    select(destination == 0 ? .topics : .sessions)
                })
            }
        }
        .onChange(of: mode) { _, newMode in
            origin = nil
            settle(newMode)
        }
    }

    private var selector: some View {
        HStack(spacing: 4) {
            viewButton(.topics)
            viewButton(.sessions)
        }
        .background {
            GeometryReader { proxy in
                let half = (proxy.size.width - 4) / 2
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.primary.opacity(0.1))
                    .frame(width: half)
                    .offset(x: min(1, max(0, position)) * (half + 4))
            }
        }
        .padding(6)
        .help("Swipe left or right with two fingers to switch Topics and Sessions")
        .overlay(alignment: .bottomTrailing) {
            #if DEBUG
            if TestDriver.isRunning {
                Color.clear.frame(width: 1, height: 1)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Sidebar swipe input " + String(format: "%.3f", Double(position)))
                    .accessibilityIdentifier("sidebar-swipe-input")
                    .accessibilityActions {
                        ForEach(SidebarSwipeInputView.verificationNames, id: \.self) { name in
                            Button(name) { input.view?.verify(name) }
                        }
                    }
            }
            #endif
        }
    }

    private func viewButton(_ target: SidebarMode) -> some View {
        Button { origin = nil; select(target) } label: {
            Text(target.rawValue)
                .font(.system(size: 11, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sidebar-view-" + target.rawValue.lowercased())
        .accessibilityValue(mode == target ? "selected" : "")
    }

    private func page<Content: View>(_ content: Content, mode target: SidebarMode, index: CGFloat, width: CGFloat) -> some View {
        content
            .frame(width: width)
            .scaleEffect(reduceMotion ? 1 : 1 - min(1, abs(position - index)) * 0.025)
            .opacity(reduceMotion ? 1 : 1 - min(1, abs(position - index)) * 0.18)
            .allowsHitTesting(mode == target && origin == nil)
            .accessibilityHidden(mode != target)
    }

    private func rubberBand(_ distance: CGFloat) -> CGFloat {
        distance * 0.25 / (1 + abs(distance) * 4)
    }

    private func select(_ target: SidebarMode) {
        // Keep the store change out of the animation transaction: only the pager should move, not its rows.
        if mode != target { mode = target }
        settle(target)
    }

    private func settle(_ target: SidebarMode) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.86)) {
            position = target == .topics ? 0 : 1
        }
    }
}

/// A weak link for the sandbox's input samples, without retaining the AppKit view through its callbacks.
private final class SidebarSwipeProbe {
    weak var view: SidebarSwipeInputView?
}

/// List scroll views own vertical scrolling. Observe scroll events before AppKit dispatches them, and keep
/// only a precise, horizontally locked gesture that began inside this panel in this App Window.
private struct SidebarSwipeInput: NSViewRepresentable {
    let probe: SidebarSwipeProbe
    let isEnabled: Bool
    let onChange: (CGFloat) -> Void
    let onEnd: (CGFloat, CGFloat, Bool) -> Void

    func makeNSView(context: Context) -> SidebarSwipeInputView {
        let view = SidebarSwipeInputView()
        probe.view = view
        return view
    }

    func updateNSView(_ view: SidebarSwipeInputView, context: Context) {
        view.onChange = onChange
        view.onEnd = onEnd
        view.isEnabled = isEnabled
    }
}

private final class SidebarSwipeInputView: NSView {
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
            guard isEnabled, !isHiddenOrHasHiddenAncestor, visibleRect.contains(convert(event.locationInWindow, from: nil)),
                  window.attachedSheet == nil else { return event }
            begin(at: event.timestamp)
        }
        guard tracking else { return event }
        let consumed = receive(x: event.scrollingDeltaX, y: event.scrollingDeltaY, time: event.timestamp,
                               ended: event.phase.contains(.ended), cancelled: event.phase.contains(.cancelled))
        return consumed ? nil : event
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
    /// The existing verify driver reaches the same axis lock, tracking and release path without moving the user's
    /// pointer or taking focus. This input element exists only inside a throwaway Sandbox, never in a normal launch.
    private static let verificationSamples: [(name: String, x: CGFloat, y: CGFloat, duration: TimeInterval, cancelled: Bool)] = [
        ("Swipe left", -0.65, 0, 0.3, false), ("Swipe right", 0.65, 0, 0.3, false),
        ("Short swipe left", -0.08, 0, 0.6, false), ("Short swipe right", 0.08, 0, 0.6, false),
        ("Flick left", -0.12, 0, 0.04, false), ("Flick right", 0.12, 0, 0.04, false),
        ("Cancel swipe left", -0.65, 0, 0.3, true), ("Cancel swipe right", 0.65, 0, 0.3, true),
        ("Vertical scroll", -0.1, -0.8, 0.3, false)
    ]

    static var verificationNames: [String] {
        verificationSamples.map(\.name) + ["Begin swipe left", "Cancel current swipe", "Vertical then horizontal"]
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
