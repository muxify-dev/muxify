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
