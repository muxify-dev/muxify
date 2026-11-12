import AppKit
import MuxifyCore

/// A card of the AppKit Topics list (docs/adr/0075-muxify-leaves-swiftui-entirely-one-area-at-a-time.md): a Topic card
/// or a Locked card. It is bare: the card's rounded box with its plain border and, in its header, the title in the
/// font of a card's title. It gives the accessibility rows of the SwiftUI card: `card-<id>` for the card and `<id>` for
/// its header, where `<id>` is the card's `accessibilityID`, such as `topic-<Topic ID>` or `locked-<Session ID>`.
final class TopicCardView: NSView {
    let cardID: TopicGroupID
    private let header: TopicCardHeaderView
    private let outline = CardOutlineView()

    init(cardID: TopicGroupID) {
        self.cardID = cardID
        header = TopicCardHeaderView(identifier: cardID.accessibilityID)
        super.init(frame: .zero)
        // From the back: the header, then the border.
        subviews = [header, outline]
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("card-" + cardID.accessibilityID)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    func show(title: String, environment: SidebarListEnvironment) {
        header.show(title: title, font: environment.typography.nsFont(for: .session), scale: environment.displayScale)
        layOut()
    }

    /// The card's height: its header's.
    var height: CGFloat { header.height }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layOut()
    }

    private func layOut() {
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: header.height)
        outline.frame = bounds
    }
}

/// The header of a bare card: its title on one line, cut with "…" when it does not fit. Its accessibility row has the
/// title as its label.
private final class TopicCardHeaderView: NSView {
    private let title = SidebarLabel()

    init(identifier: String) {
        super.init(frame: .zero)
        addSubview(title)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier(identifier)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    func show(title text: String, font: NSFont, scale: CGFloat) {
        title.text = text
        title.font = font
        title.scale = scale
        setAccessibilityLabel(text)
        layOut()
    }

    /// A closed card's header: one line of the title, in the header's padding.
    var height: CGFloat {
        CardHeaderPadding.top + title.lineHeight + CardHeaderPadding.bottom(isOpen: false)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layOut()
    }

    private func layOut() {
        let width = max(0, bounds.width - CardHeaderPadding.leading - CardHeaderPadding.trailing)
        _ = title.fit(width: width)
        title.frame = NSRect(x: CardHeaderPadding.leading, y: CardHeaderPadding.top, width: width, height: title.lineHeight)
    }
}
