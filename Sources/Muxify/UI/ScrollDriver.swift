import AppKit
import SwiftUI

/// Scrolls the SwiftUI scroll view that `ScrollDriverView` sits in while a lifted card's pointer rests at an edge.
/// `ScrollViewReader` scrolls to a view; an auto-scroll scrolls by points, each tick, with no gesture event to drive
/// it. It is the same NSClipView move that the TestDriver's Reveal makes.
@MainActor final class ScrollDriver {
    fileprivate weak var scrollView: NSScrollView?
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

    private func tick() {
        guard let scrollView, let document = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let end = max(0, document.bounds.height - clip.bounds.height)
        let offset = document.isFlipped ? clip.bounds.origin.y : end - clip.bounds.origin.y
        let step = EdgeAutoScroll.step(pointer: pointer, in: area(offset), offset: offset, end: end)
        let delta = dwell.pass(step, at: ProcessInfo.processInfo.systemUptime)
        guard delta != 0 else { return }
        let y = min(max(0, offset + delta), end)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: document.isFlipped ? y : end - y))
        scrollView.reflectScrolledClipView(clip)
    }
}

/// A view of no size in a scroll view's content that hands its scroll view to `driver`.
struct ScrollDriverView: NSViewRepresentable {
    let driver: ScrollDriver

    final class Anchor: NSView {
        var driver: ScrollDriver?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            driver?.scrollView = enclosingScrollView
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
        if let scrollView = view.enclosingScrollView { driver.scrollView = scrollView }
    }
}
