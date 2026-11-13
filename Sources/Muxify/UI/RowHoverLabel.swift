import AppKit
import MuxifyCore

/// A row's hover label for a row in AppKit (ADR 0074): what `hoverLabel(detail:onlyWhenCutOff:enabled:)` does for a
/// SwiftUI row. The row says when the pointer comes and goes, what the label shows, and when the row goes away; the
/// row's title is the `anchor`'s. The panel shows the AppKit label, `HoverLabelView`.
@MainActor
final class RowHoverLabel {
    /// What the label shows, and when.
    struct Request: Equatable {
        var detail = ""
        /// The label opens only when the row cuts its title off.
        var onlyWhenCutOff = false
        /// False suppresses the label.
        var enabled = true
        /// The Interface font size of the row, which the label's detail grows with.
        var fontSize = InterfaceFontSize()
    }

    let anchor = RowHoverAnchor()
    private var request = Request()
    private var hovering = false

    /// Takes what the label shows from now on. As in SwiftUI, a change of `onlyWhenCutOff` closes the label and opens
    /// it again by the new rule, and a change of `enabled` opens or closes it.
    func show(_ request: Request) {
        let old = self.request
        self.request = request
        if request.onlyWhenCutOff != old.onlyWhenCutOff {
            HoverLabels.shared.leave(anchor)
            update()
        } else if request.enabled != old.enabled {
            update()
        }
    }

    /// The pointer came onto the row, or left it.
    func pointer(inside: Bool) {
        hovering = inside
        update()
    }

    /// The row went away: its label closes.
    func disappear() {
        hovering = false
        HoverLabels.shared.leave(anchor)
    }

    private func update() {
        if hovering && request.enabled {
            HoverLabels.shared.enter(anchor, detail: request.detail, onlyWhenCutOff: request.onlyWhenCutOff, fontSize: request.fontSize)
        } else {
            HoverLabels.shared.leave(anchor)
        }
    }
}

/// The title of a row in AppKit as its hover label needs it, with no SwiftUI type
/// (docs/adr/0075-muxify-leaves-swiftui-entirely-one-area-at-a-time.md): the view that draws it, its text in its font,
/// and how wide the whole text is on one line. Its label is `HoverLabelView`.
@MainActor
final class RowHoverAnchor: HoverLabelAnchor {
    private(set) weak var titleView: NSView?
    private var title = ""
    private var font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    private(set) var hasTitle = false
    private(set) var fullWidth: CGFloat = 0

    /// `view` draws the row's title, `title` is that title in `font`, and `fullWidth` is how wide the whole title is on
    /// one line.
    func anchor(_ view: NSView, title: String, font: NSFont, fullWidth: CGFloat) {
        titleView = view
        self.title = title
        self.font = font
        self.fullWidth = fullWidth
        hasTitle = true
    }

    func label(showsTitle: Bool, detail: String, fontSize: InterfaceFontSize, scale: CGFloat) -> NSView {
        HoverLabelView(title: showsTitle ? (title, font) : nil, detail: detail, fontSize: fontSize, scale: scale)
    }
}
