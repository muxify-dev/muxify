import AppKit

/// How a list of the Sidebar moves its own clip view, for the SwiftUI lists through `ScrollDriver` and for the AppKit
/// lists (docs/adr/0075-muxify-leaves-swiftui-entirely-one-area-at-a-time.md): at once, which is the same NSClipView
/// move that the TestDriver's Reveal makes, or in a glide.
extension NSScrollView {
    /// The last scroll offset: the content's height less the visible part's, and never less than zero.
    var scrollEnd: CGFloat {
        max(0, (documentView?.bounds.height ?? 0) - contentView.bounds.height)
    }

    /// How far the content has scrolled up from its top, for a flipped document and for one that is not.
    var scrollOffset: CGFloat {
        documentView?.isFlipped ?? true ? contentView.bounds.origin.y : scrollEnd - contentView.bounds.origin.y
    }

    /// Moves the content `delta` points up at once, within its scroll range, and returns the part of `delta` it could
    /// not move.
    @discardableResult
    func move(by delta: CGFloat) -> CGFloat {
        guard let document = documentView else { return 0 }
        let clip = contentView
        let end = scrollEnd, offset = scrollOffset
        let y = min(max(0, offset + delta), end)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: document.isFlipped ? y : end - y))
        reflectScrolledClipView(clip)
        return offset + delta - y
    }

    /// Glides the content to `offset` points from its top, within its scroll range, by the clip view's animator over
    /// `duration` along `timing`. The clip view comes to rest at a place it can stand at, so nothing moves after the
    /// glide. The animator starts no NSAnimation, so the glide reports itself to Diagnostics as `name`
    /// (`DisplayLinkProbe`), where the `sidebar_pager_scroll` and `topics_list_sidebar` suites count it.
    func glide(to offset: CGFloat, duration: TimeInterval, timing: CAMediaTimingFunctionName, name: String) {
        guard let document = documentView else { return }
        let clip = contentView
        let end = scrollEnd
        let y = min(max(0, offset), end)
        let from = clip.bounds.origin, to = NSPoint(x: from.x, y: document.isFlipped ? y : end - y)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: timing)
            clip.animator().setBoundsOrigin(to)
        }
        reflectScrolledClipView(clip)
        DisplayLinkProbe.didStart(glide: name, in: window, duration: duration, from: from, to: to)
    }
}

/// Scrolls a list while a lifted item's pointer rests at an edge of its area, each tick, with no event to drive it: by
/// `EdgeAutoScroll.step` once the pointer has rested in a band for `EdgeAutoScroll.Dwell.delay`. The SwiftUI Topics
/// list's `ScrollDriver` and the AppKit Topics list both scroll their lists with it.
@MainActor final class EdgeAutoScrollLoop {
    /// The scroll view whose clip view the loop moves.
    weak var scrollView: NSScrollView?
    private var pointer: CGFloat?
    private var area: (CGFloat) -> ClosedRange<CGFloat> = { _ in 0...0 }
    private var dwell = EdgeAutoScroll.Dwell()
    private var loop: Task<Void, Never>?

    /// Follows a lifted item's pointer, its y in the visible part of the scroll view, until it is nil. `area` gives, for
    /// a scroll offset, the part of the visible part whose edges scroll.
    func follow(pointer: CGFloat?, area: @escaping (CGFloat) -> ClosedRange<CGFloat>) {
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
            while !Task.isCancelled, let scroller = self {
                scroller.tick()
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private func tick() {
        guard let scrollView else { return }
        let offset = scrollView.scrollOffset, end = scrollView.scrollEnd
        let step = EdgeAutoScroll.step(pointer: pointer, in: area(offset), offset: offset, end: end)
        let delta = dwell.pass(step, at: ProcessInfo.processInfo.systemUptime)
        if delta != 0 { scrollView.move(by: delta) }
    }
}
