import AppKit

/// How a list of the Sidebar moves its own clip view, for the SwiftUI lists through `ScrollDriver` and for the AppKit
/// lists (docs/adr/0075-muxify-leaves-swiftui-entirely-one-area-at-a-time.md). It is the same NSClipView move that the
/// TestDriver's Reveal makes.
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
}
