import AppKit
import MuxifyCore

/// What a card of the AppKit Topics list shows, a Topic card or a Locked card, as the list reads it from the models.
struct TopicCardContent: Equatable {
    var header: CardHeaderContent
    /// The card holds the Location: it is the Active Topic's card.
    var holdsSelection = false
    /// The mark of the spine along the card's left edge. The open card of the Active Topic shows the marks on its rows
    /// instead.
    var spine: CardMark?
    /// The Unread mark's spine over the header, which the open card of an Unread Active Topic shows while its rows show
    /// the Agent marks.
    var unreadOverHeader = false
    /// The opacity of the card at rest, as `TopicCardOpacity` gives it. The Hint shows whole.
    var restingOpacity = 1.0
    /// The Topic's own action in the card's bottom-right corner. Nil for a Locked card.
    var corner: TopicCardCorner?
}

/// The Topic's own action in the bottom-right corner of its card, as a link: Settle in the Topics list.
struct TopicCardCorner: Equatable {
    let title: String
    let identifier: String
    var isEnabled = true
}

/// A card of the AppKit Topics list (docs/adr/0075-muxify-leaves-swiftui-entirely-one-area-at-a-time.md): a Topic card
/// or a Locked card, as `TopicCard` and `LockedCard` draw them in SwiftUI. Closed, it is flat, with only its border;
/// open, it is raised. A spine shows its mark, and the card that holds the Location has the many-coloured border. A
/// Topic card shows Settle in its corner. A card rests at its opacity, and its Hint shows whole.
///
/// To accessibility the view is no element: its rows are the corner's link, then the card, `card-<id>`, whose rows are
/// its header, `<id>`, and its Hint, as SwiftUI gives them. `<id>` is the card's `accessibilityID`, such as
/// `topic-<Topic ID>` or `locked-<Session ID>`.
final class TopicCardView: NSView {
    let cardID: TopicGroupID
    /// A press on the header.
    var onPress: () -> Void = {} {
        didSet { header.onPress = onPress }
    }
    /// A press on the action in the corner.
    var onCorner: () -> Void = {} {
        didSet { corner.onPress = onCorner }
    }
    /// The card, as one accessibility row.
    private let card = TopicCardGroupView()
    /// The parts of the card that rest at its opacity.
    private let dimmed = FlippedView()
    private let fill = CardFillView()
    private let header: CardHeaderView
    private let unread = CardSpineView()
    private let spine = CardSpineView()
    private let outline = CardOutlineView()
    private let selection = CardSelectionBorderView()
    private let hint = CardHintViews()
    private let corner = TopicCardCornerView()
    private var content: TopicCardContent?
    private var environment = SidebarListEnvironment()

    init(cardID: TopicGroupID) {
        self.cardID = cardID
        header = CardHeaderView(identifier: cardID.accessibilityID)
        super.init(frame: .zero)
        wantsLayer = true
        dimmed.wantsLayer = true
        // The SwiftUI card cuts nothing off.
        for view in [self, card, dimmed] { view.clipsToBounds = false }
        // From the back: the fill, the header, the spines, the border, then the Hint and the corner's action.
        dimmed.subviews = [fill, header, unread, spine, outline, selection]
        card.subviews = [dimmed] + hint.views
        subviews = [card, corner]
        card.setAccessibilityIdentifier("card-" + cardID.accessibilityID)
        card.rows = { [weak self] in self.map { [$0.header] + $0.hint.shown } ?? [] }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    var isOpen: Bool { content?.header.isOpen ?? false }

    /// Shows the content. The colours of the border turn once when the Location comes to a card that already showed.
    func show(_ content: TopicCardContent, environment: SidebarListEnvironment) {
        guard content != self.content || environment != self.environment else { return }
        let came = self.content.map { !$0.holdsSelection && content.holdsSelection } ?? false
        self.content = content
        self.environment = environment
        header.show(content.header, environment: environment)
        fill.alphaValue = content.header.isOpen ? 1 : 0
        let moves = environment.pulses && !environment.reduceMotion
        spine.show(content.spine, colors: environment.agentColors, moves: moves)
        unread.show(content.unreadOverHeader ? .unread : nil, colors: environment.agentColors, moves: moves)
        // The card that holds the Location gives up its plain border for the coloured one.
        outline.isHidden = content.holdsSelection
        selection.isHidden = !content.holdsSelection
        dimmed.alphaValue = content.restingOpacity
        hint.show(content.header.hint, environment: environment)
        corner.show(content.corner, environment: environment)
        corner.alphaValue = content.restingOpacity
        layOut()
        if came, !environment.reduceMotion { selection.turn() }
    }

    /// The card's height at `width`: its header, and under the header of an open card the room of its rows, with the
    /// line that a Topic card's rows end with for its action.
    func height(width: CGFloat) -> CGFloat {
        let footer = content?.corner == nil ? 0 : CardCorner.footerHeight(environment.fontSize)
        return header.height(width: width) + (isOpen ? CardRowsPadding.top + footer + CardRowsPadding.bottom : 0)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layOut()
    }

    private func layOut() {
        card.frame = bounds
        dimmed.frame = bounds
        fill.frame = bounds
        outline.frame = bounds
        selection.frame = bounds
        let headerHeight = header.height(width: bounds.width)
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: headerHeight)
        spine.frame = NSRect(x: CardSpine.leading, y: CardSpine.verticalInset, width: CardSpine.width,
                             height: max(0, bounds.height - 2 * CardSpine.verticalInset))
        unread.frame = NSRect(x: CardSpine.leading, y: CardSpine.verticalInset, width: CardSpine.width,
                              height: max(0, headerHeight - 2 * CardSpine.verticalInset))
        // The header keeps the Hint's place, and the card draws the Hint over it.
        hint.place(header.hintPlace(width: bounds.width))
        // In the bottom-right corner, at the same offsets whether the card is open or closed.
        let size = corner.size
        corner.frame = NSRect(x: bounds.width - CardCorner.trailing - size.width, y: bounds.height - CardCorner.bottom - size.height,
                              width: size.width, height: size.height)
    }

    // MARK: Accessibility

    /// The corner's link, then the card, as SwiftUI lists the overlay of the card's corner.
    override func accessibilityChildren() -> [Any]? { (corner.isHidden ? [] : [corner]) + [card] }
}

/// The card as one accessibility row: a group of its header and its Hint, though the Hint is no part of what rests at
/// the card's opacity.
private final class TopicCardGroupView: NSView {
    /// The rows of the card: its header, then the Hint.
    var rows: () -> [NSView] = { [] }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func accessibilityChildren() -> [Any]? { rows() }

    override func accessibilityActivationPoint() -> NSPoint { accessibilityFrame().centre }
}

/// The Topic's own action in its card's corner: a link in the text size of `CardCorner`, as SwiftUI's link button
/// draws it, and a link to accessibility. A disabled link does nothing.
private final class TopicCardCornerView: SidebarPressView {
    private let label = SidebarLabel()
    private var isEnabled = true

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.link)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Shows the action, or nothing for none.
    func show(_ corner: TopicCardCorner?, environment: SidebarListEnvironment) {
        isHidden = corner == nil
        isEnabled = corner?.isEnabled ?? false
        label.text = corner?.title ?? ""
        label.font = .systemFont(ofSize: environment.fontSize(CardCorner.fontSize))
        label.ink = isEnabled ? .link : .disabledLink
        label.scale = environment.displayScale
        setAccessibilityIdentifier(corner?.identifier)
        setAccessibilityLabel(corner?.title)
        setAccessibilityEnabled(isEnabled)
    }

    /// The room the action's text takes.
    var size: NSSize { label.fit() }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        label.frame = bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? { isHidden ? nil : super.hitTest(point) }

    override func pressUp(at point: NSPoint) {
        if isEnabled { super.pressUp(at: point) }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        return super.accessibilityPerformPress()
    }

    override func accessibilityActivationPoint() -> NSPoint { accessibilityFrame().centre }
}
