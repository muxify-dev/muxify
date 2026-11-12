import AppKit
import MuxifyCore

/// A part of a card's Tags: a Tag Mark, a chip with a Tag's text, or "+N" for the Tags that do not fit.
enum CardTagPart: Equatable {
    case mark(ShownTag)
    case chip(CardTags.Item)
    case more(Int)
}

/// Where the parts of a card's Tags stand in a room, as `CardTagsView` lays them out in SwiftUI: in a row with
/// `CardTagMetrics.spacing` between them, each with its middle on the row's middle. The `corner` placement shows a Tag
/// Mark for each Tag, the `title` placement the first chip and "+N", and the `line` placement the widest row of chips
/// that fits the room, else "+N" alone.
struct CardTagsLayout {
    let parts: [(part: CardTagPart, frame: NSRect)]
    /// The room the Tags take.
    let size: NSSize

    init(_ tags: CardTags, width: CGFloat = .greatestFiniteMagnitude, fontSize: InterfaceFontSize, scale: CGFloat) {
        let sized = Self.rows(of: tags).map { row in row.map { ($0, Self.size(of: $0, fontSize: fontSize, scale: scale)) } }
        let widthOf = { (row: [(CardTagPart, NSSize)]) in
            row.map(\.1.width).reduce(0, +) + CGFloat(max(0, row.count - 1)) * CardTagMetrics.spacing
        }
        // The first row that fits, as SwiftUI's `ViewThatFits` picks it, else the last.
        let row = sized.first { widthOf($0) <= width + 0.001 } ?? sized.last ?? []
        let height = row.map(\.1.height).max() ?? 0
        var x: CGFloat = 0
        parts = row.map { part, size in
            defer { x += size.width + CardTagMetrics.spacing }
            return (part, NSRect(x: x.rounded(toPixelsOf: scale), y: ((height - size.height) / 2).rounded(toPixelsOf: scale),
                                 width: size.width, height: size.height))
        }
        size = NSSize(width: widthOf(row), height: height)
    }

    /// The rows the placement can show, from the widest.
    private static func rows(of tags: CardTags) -> [[CardTagPart]] {
        let count = tags.items.count
        switch tags.placement {
        case .none:
            return []
        case .corner:
            return [tags.items.map { .mark($0.shown) }]
        case .title:
            return [tags.items.prefix(1).map { .chip($0) } + (count > 1 ? [.more(count - 1)] : [])]
        case .line:
            return tags.lineRows.map { shown in tags.items.prefix(shown).map { .chip($0) } + (shown < count ? [.more(count - shown)] : []) }
        }
    }

    private static func size(of part: CardTagPart, fontSize: InterfaceFontSize, scale: CGFloat) -> NSSize {
        let padding: CGFloat
        let text: String
        switch part {
        case .mark:
            let side = CardTagMetrics.markSide(fontSize)
            return NSSize(width: side, height: side)
        case .chip(let item):
            (padding, text) = (CardTagMetrics.chipHorizontalPadding, item.text)
        case .more(let count):
            (padding, text) = (CardTagMetrics.moreHorizontalPadding, "+\(count)")
        }
        let size = SidebarTextLayout(text, font: chipFont(fontSize), scale: scale).size
        return NSSize(width: size.width + 2 * padding, height: size.height + 2 * CardTagMetrics.chipVerticalPadding)
    }

    static func chipFont(_ fontSize: InterfaceFontSize) -> NSFont {
        .systemFont(ofSize: fontSize(CardTagMetrics.chipFontSize), weight: .medium)
    }
}

/// The Tags of a Topic card in the AppKit Topics list (docs/adr/0075-muxify-leaves-swiftui-entirely-one-area-at-a-time.md),
/// as `cardTagsOverlay` draws them in SwiftUI: the card's header keeps their place, and the card draws them over it. To
/// accessibility they are one static text, "Tags", with the names as its value, `tags-<id>`; their hover label (the
/// help tag) is the names. A press on them presses the card.
///
/// They rest at the card's opacity part by part, as SwiftUI's `opacity` dims each part of a view on its own and not the
/// view as one picture: the fill of a chip shows through its text.
final class SidebarTagsView: SidebarPressView {
    private var tags: CardTags?
    private var fontSize = InterfaceFontSize()
    private var scale: CGFloat = 2
    private var opacity = 1.0
    /// The parts that show, and their views, in the same order.
    private var parts: [CardTagPart] = []

    init() {
        super.init(frame: .zero)
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Tags")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Shows the Tags, or nothing for none, each part at `opacity`, the opacity the card rests at.
    func show(_ tags: CardTags?, fontSize: InterfaceFontSize, scale: CGFloat, opacity: Double) {
        guard tags != self.tags || fontSize != self.fontSize || scale != self.scale || opacity != self.opacity else { return }
        self.tags = tags
        self.fontSize = fontSize
        self.scale = scale
        self.opacity = opacity
        isHidden = tags == nil
        toolTip = tags?.names
        setAccessibilityIdentifier(tags?.accessibilityID)
        setAccessibilityValue(tags?.names)
        parts = []
        layOut()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layOut()
    }

    /// Lays the Tags out in the room the header kept for them: the `line` placement shows there the row that fitted.
    private func layOut() {
        guard let tags else { return subviews = [] }
        let layout = CardTagsLayout(tags, width: bounds.width, fontSize: fontSize, scale: scale)
        let shown = layout.parts.map(\.part)
        if shown != parts {
            parts = shown
            subviews = shown.map { part in
                if case .mark(let tag) = part { return TagMarkView(tag, opacity: opacity) }
                let chip = TagChipView(part, font: CardTagsLayout.chipFont(fontSize), opacity: opacity)
                chip.scale = scale
                return chip
            }
        }
        for (view, part) in zip(subviews, layout.parts) { view.frame = part.frame }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { isHidden ? nil : super.hitTest(point) }

    /// The names are the hover label, which SwiftUI's `help` does not give to accessibility as help.
    override func accessibilityHelp() -> String? { nil }

    override func accessibilityActivationPoint() -> NSPoint { accessibilityFrame().centre }
}

/// A Tag Mark: a small rounded square in the Tag's colour, as `TagMark` draws it. A Tag that the Config no longer defines
/// has the secondary text colour, dimmed. The shape is a layer under the view's own, as `RowFillView`'s.
private final class TagMarkView: LayerColoredView {
    private let shown: ShownTag
    private let shape = CALayer()

    init(_ shown: ShownTag, opacity: Double) {
        self.shown = shown
        super.init(frame: .zero)
        layer = CALayer()
        wantsLayer = true
        shape.cornerRadius = CardTagMetrics.markCornerRadius
        shape.cornerCurve = .continuous
        shape.opacity = Float(opacity * (shown.definition == nil ? CardTagMetrics.undefinedMarkOpacity : 1))
        layer?.addSublayer(shape)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        LayerGlide.withoutActions { shape.frame = bounds }
    }

    override func colorLayers() {
        shape.backgroundColor = (shown.definition.map { $0.color.nsColor(in: effectiveAppearance) } ?? .secondaryLabelColor).cgColor
    }
}

/// A chip of a Tag, its text in the Tag's colour on a faint fill of that colour, as `TagChip` draws it, dimmed for a Tag
/// that the Config no longer defines; or "+N" in the secondary text colour on a faint fill of the text colour, as
/// `MoreTagsChip` draws it.
private final class TagChipView: LayerColoredView {
    private let part: CardTagPart
    private let shape = CALayer()
    private let label = SidebarLabel()

    var scale: CGFloat {
        get { label.scale }
        set { label.scale = newValue }
    }

    init(_ part: CardTagPart, font: NSFont, opacity: Double) {
        self.part = part
        super.init(frame: .zero)
        layer = CALayer()
        wantsLayer = true
        shape.cornerRadius = CardTagMetrics.chipCornerRadius
        shape.cornerCurve = .continuous
        layer?.addSublayer(shape)
        addSubview(label)
        label.font = font
        // The fill and the text each at the opacity, as SwiftUI dims them.
        var dimmed = opacity
        switch part {
        case .chip(let item):
            label.text = item.text
            label.ink = item.shown.definition.map { .mark($0.color) } ?? .secondary
            if item.shown.definition == nil { dimmed *= CardTagMetrics.undefinedChipOpacity }
        case .more(let count):
            label.text = "+\(count)"
            label.ink = .secondary
        case .mark:
            break
        }
        shape.opacity = Float(dimmed)
        label.alphaValue = dimmed
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        LayerGlide.withoutActions { shape.frame = bounds }
        let padding = if case .more = part { CardTagMetrics.moreHorizontalPadding } else { CardTagMetrics.chipHorizontalPadding }
        label.frame = NSRect(origin: NSPoint(x: padding, y: CardTagMetrics.chipVerticalPadding), size: label.fit())
    }

    override func colorLayers() {
        let fill: NSColor = switch part {
        case .chip(let item):
            (item.shown.definition.map { $0.color.nsColor(in: effectiveAppearance) } ?? .secondaryLabelColor).faded(CardTagMetrics.chipFillOpacity)
        case .more, .mark:
            NSColor.labelColor.faded(CardTagMetrics.moreFillOpacity)
        }
        shape.backgroundColor = fill.cgColor
    }
}
