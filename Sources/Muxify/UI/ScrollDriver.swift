import AppKit
import SwiftUI

/// Scrolls the SwiftUI scroll view that `ScrollDriverView` sits in by points: while a lifted card's pointer rests at an
/// edge, each tick, with no gesture event to drive it, and by the distance a card moved in a layout, before that layout
/// is drawn. `ScrollViewReader` scrolls to a view, and only within the content's height of the last layout. It is the
/// same NSClipView move that the TestDriver's Reveal makes.
@MainActor final class ScrollDriver {
    private weak var scrollView: NSScrollView?
    private weak var document: NSView?
    private var pointer: CGFloat?
    private var area: (CGFloat) -> ClosedRange<CGFloat> = { _ in 0...0 }
    private var dwell = EdgeAutoScroll.Dwell()
    private var loop: Task<Void, Never>?

    /// Follows a lifted card's pointer, its y in the viewport, until it is nil. `area` gives, for a scroll offset, the
    /// part of the viewport whose edges scroll.
    func autoScroll(pointer: CGFloat?, area: @escaping (CGFloat) -> ClosedRange<CGFloat>) {
        self.pointer = pointer
        self.area = area
        guard pointer != nil else {
            loop?.cancel()
            loop = nil
            dwell = EdgeAutoScroll.Dwell()
            return
        }
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled, let driver = self {
                driver.tick()
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    /// Moves the content `delta` points up. In the layout that makes the content taller, SwiftUI reports the new
    /// geometry before AppKit gives the scroll view its new height, so a move past the old end waits: the rest is
    /// moved when the content's frame changes, in the same pass of the run loop, before it is drawn. What is left at the
    /// end of that pass is dropped.
    func scroll(by delta: CGFloat) {
        pending = move(by: delta)
        guard pending != 0, waits == nil else { return }
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, 3_000_000) {
            [weak self] _, _ in
            self?.pending = 0
            self?.waits = nil
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        waits = observer
    }

    private var pending: CGFloat = 0
    private var waits: CFRunLoopObserver?
    private var resizes: NSObjectProtocol?

    fileprivate func attach(_ scrollView: NSScrollView) {
        guard scrollView !== self.scrollView || scrollView.documentView !== document else { return }
        self.scrollView = scrollView
        document = scrollView.documentView
        if let resizes { NotificationCenter.default.removeObserver(resizes) }
        document?.postsFrameChangedNotifications = true
        resizes = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: document,
                                                         queue: nil) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.pending != 0 else { return }
                self.pending = self.move(by: self.pending)
            }
        }
    }

    /// Moves the content `delta` points within its scroll range, and returns the part of `delta` it could not move.
    private func move(by delta: CGFloat) -> CGFloat {
        guard let scrollView, let document = scrollView.documentView else { return 0 }
        let clip = scrollView.contentView
        let end = max(0, document.bounds.height - clip.bounds.height)
        let offset = document.isFlipped ? clip.bounds.origin.y : end - clip.bounds.origin.y
        let y = min(max(0, offset + delta), end)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: document.isFlipped ? y : end - y))
        scrollView.reflectScrolledClipView(clip)
        return offset + delta - y
    }

    private func tick() {
        guard let scrollView, let document = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let end = max(0, document.bounds.height - clip.bounds.height)
        let offset = document.isFlipped ? clip.bounds.origin.y : end - clip.bounds.origin.y
        let step = EdgeAutoScroll.step(pointer: pointer, in: area(offset), offset: offset, end: end)
        let delta = dwell.pass(step, at: ProcessInfo.processInfo.systemUptime)
        if delta != 0 { _ = move(by: delta) }
    }
}

/// A view of no size in a scroll view's content that hands its scroll view to `driver`.
struct ScrollDriverView: NSViewRepresentable {
    let driver: ScrollDriver

    final class Anchor: NSView {
        var driver: ScrollDriver?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let scrollView = enclosingScrollView { driver?.attach(scrollView) }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> Anchor {
        let view = Anchor()
        view.driver = driver
        return view
    }

    func updateNSView(_ view: Anchor, context: Context) {
        view.driver = driver
        if let scrollView = view.enclosingScrollView { driver.attach(scrollView) }
    }
}
