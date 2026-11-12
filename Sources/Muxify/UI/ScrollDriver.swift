import AppKit
import SwiftUI

/// Scrolls the SwiftUI scroll view that `ScrollDriverView` sits in by points: while a lifted card's pointer rests at an
/// edge, each tick, with no gesture event to drive it; by the distance a card moved in a layout, before that layout
/// is drawn; and to a card that a pill or a Jump To reveals. `ScrollViewReader` scrolls to a view only within the
/// content's height of the last layout, and it keeps its target armed after the scroll, so the next scroll from
/// AppKit, such as a wheel's, can glide back to it. It is the same NSClipView move that the TestDriver's Reveal makes.
@MainActor final class ScrollDriver {
    private weak var scrollView: NSScrollView?
    private weak var document: NSView?
    private let edges = EdgeAutoScrollLoop()

    /// Follows a lifted card's pointer, its y in the viewport, until it is nil. `area` gives, for a scroll offset, the
    /// part of the viewport whose edges scroll.
    func autoScroll(pointer: CGFloat?, area: @escaping (CGFloat) -> ClosedRange<CGFloat>) {
        edges.follow(pointer: pointer, area: area)
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
        edges.scrollView = scrollView
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

    /// Glides the content to `offset` points from its top, within its scroll range, as a click on a pill does, with the
    /// duration and curve of the AppKit Topics list's glide.
    func scroll(to offset: CGFloat) {
        scrollView?.glide(to: offset, duration: TopicsListScroll.revealDuration, timing: TopicsListScroll.revealTiming,
                          name: "TopicsListGlide")
    }

    /// Moves the content `delta` points within its scroll range, and returns the part of `delta` it could not move.
    private func move(by delta: CGFloat) -> CGFloat {
        scrollView?.move(by: delta) ?? 0
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
