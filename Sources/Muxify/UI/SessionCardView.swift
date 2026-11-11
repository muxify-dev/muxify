import AppKit
import MuxifyCore

/// What a Session card shows, as the Sessions list reads it from the models.
struct SessionCardContent: Equatable {
    var title: String
    /// The Summary, which a closed card shows under its title. Empty for none.
    var summary = ""
    var isOpen = false
    /// The card holds the Location's Window.
    var holdsSelection = false
    var mark: CardMark?
    var isLocked = false
    /// The Session is Locked and the Config sets In Play, so the Lock is a Guest.
    var isGuest = false
    /// A Window of the Session has a bell.
    var hasBell = false
    var hint: CardHint?
    /// The rows an open card lists, in tmux's order: `CardRows.shownCount` of its Window and Pane rows. A closed card
    /// has none.
    var rows: [CardRowContent] = []
    /// The rows an open card holds back, which its "N more…" counts. 0 for none.
    var moreCount = 0
}

/// A row of an open Session card: a Window row, or a Pane row under its Window row or in its place.
enum CardRowContent: Equatable {
    case window(WindowRowContent)
    case pane(PaneRowContent)
}

/// The Hint of a card, in the place the header keeps for it after the title.
struct CardHint: Equatable {
    let target: QuickSwitchTarget
    /// The key that shows at rest. Empty when the card only keeps the place, for the Hint of a held modifier.
    let restKey: String
    /// The keys of the modifier the user holds, which the badge shows in place of the key at rest. Empty for none.
    let triggers: [KeyTrigger]

    /// Nil when the card has no Hint: its header then keeps no place for one.
    init?(_ target: QuickSwitchTarget, in hints: HintPresentation) {
        guard hints.restKey(for: target) != nil || !hints[target].isEmpty else { return nil }
        self.target = target
        restKey = hints.restKey(for: target) ?? ""
        triggers = hints[target]
    }

    /// The badge shows: the user holds the modifier of the Hint.
    var showsBadge: Bool { !triggers.isEmpty }
}

/// A Session card of the AppKit Sessions list (ADR 0074). Closed, it is flat, with only its border; open, it is
/// raised, with its Window and Pane rows under its header, and "N more…" after them when it holds rows back. A spine
/// shows its mark, and the card that holds the Location's Window has the many-coloured border. It gives the
/// accessibility rows of the SwiftUI card: `card-session-<id>` for the card, the parts of its Window rows, its Pane rows
/// and "N more…", `session-<id>` for its header, and a row for each Hint: the card's and its Window rows'.
final class SessionCardView: NSView {
    let sessionID: String
    /// A press on the header.
    var onPress: () -> Void = {} {
        didSet { header.onPress = onPress }
    }
    /// A click on a Window row.
    var onSelectWindow: (TmuxWindow) -> Void = { _ in }
    /// A press on a Pane row, with the Pane's ID.
    var onSelectPane: (String) -> Void = { _ in }
    /// A press on "N more…".
    var onShowAllRows: () -> Void = {} {
        didSet { more.onPress = onShowAllRows }
    }
    private let fill = CardFillView()
    private let header: SessionCardHeaderView
    /// The rows of an open card. A card that closes keeps them, so they fade where they stand.
    private let rows = CardRowsView()
    /// The Window and Pane rows from the top, and "N more…" after them when it shows.
    private var listed: [CardRowView] = []
    private let more: MoreRowView
    private let spine = CardSpineView()
    private let outline = CardOutlineView()
    private let selection = CardSelectionBorderView()
    /// The card's Hint: its key at rest, or the badge while the user holds the Hint's modifier.
    private let hint = CardRestKeyView()
    private let badge = SidebarHintView()
    /// The Hints of the Window rows of an open card, by Window ID.
    private var windowHints: [String: SidebarHintView] = [:]
    private var content: SessionCardContent?
    private var environment = SessionsListEnvironment()
    /// The card's top edge in the list's viewport. The header of an open card sticks to the viewport's top once the
    /// card's top has scrolled past it.
    private var viewportTop: CGFloat = 0

    init(sessionID: String) {
        self.sessionID = sessionID
        header = SessionCardHeaderView(identifier: "session-" + sessionID)
        more = MoreRowView(identifier: "session-" + sessionID)
        super.init(frame: .zero)
        wantsLayer = true
        // The SwiftUI card cuts nothing off.
        clipsToBounds = false
        // From the back: the fill, the rows, the header, which stays above the rows that scroll under it, the spine,
        // the border and the Hints.
        subviews = chrome
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("card-session-" + sessionID)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// The card's views from the back, without the Hints of its Window rows, which come after them.
    private var chrome: [NSView] { [fill, rows, header, spine, outline, selection, hint, badge] }

    var isOpen: Bool { content?.isOpen ?? false }

    /// Shows the content. The colours of the border turn once when the Location comes to a card that already showed.
    func show(_ content: SessionCardContent, environment: SessionsListEnvironment) {
        guard content != self.content || environment != self.environment else { return }
        let came = self.content.map { !$0.holdsSelection && content.holdsSelection } ?? false
        let wasOpen = isOpen
        self.content = content
        self.environment = environment
        header.show(content, environment: environment)
        if content.isOpen { showRows(content.rows, more: content.moreCount, fades: wasOpen) }
        fill.alphaValue = content.isOpen ? 1 : 0
        rows.alphaValue = content.isOpen ? 1 : 0
        rows.isOpen = content.isOpen
        spine.show(content.mark, colors: environment.agentColors, moves: environment.pulses && !environment.reduceMotion)
        // The card that holds the Location's Window gives up its plain border for the coloured one.
        outline.isHidden = content.holdsSelection
        selection.isHidden = !content.holdsSelection
        // The badge ends where the key at rest ends, and grows over the title.
        let held = content.hint.flatMap { $0.showsBadge ? $0 : nil }
        hint.show(held == nil ? content.hint : nil, fontSize: environment.fontSize, scale: environment.displayScale)
        badge.isHidden = held == nil
        if let held { badge.show(.badge(held.triggers), target: held.target, fontSize: environment.fontSize, scale: environment.displayScale) }
        showWindowHints()
        layOut()
        if came, !environment.reduceMotion { selection.turn() }
    }

    /// Shows a row for each Window and Pane, from the top, and "N more…" after them for `more` rows held back. A row
    /// that already showed keeps its view, so its tint fades when the Location moves, unless `fades` is false.
    private func showRows(_ contents: [CardRowContent], more count: Int, fades: Bool) {
        var windows = Dictionary(listed.compactMap { $0 as? WindowRowView }.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        var panes = Dictionary(listed.compactMap { $0 as? PaneRowView }.map { ($0.paneID, $0) }, uniquingKeysWith: { first, _ in first })
        listed = contents.map { content -> CardRowView in
            switch content {
            case .window(let content):
                let row = windows.removeValue(forKey: content.window.id)
                    ?? WindowRowView(windowID: content.window.id, identifier: "session-window-" + content.window.id)
                row.onPress = { [weak self] in self?.onSelectWindow(content.window) }
                row.show(content, environment: environment, fades: fades)
                return row
            case .pane(let content):
                let row = panes.removeValue(forKey: content.paneID) ?? PaneRowView(paneID: content.paneID)
                row.onPress = { [weak self] in self?.onSelectPane(content.paneID) }
                row.show(content, environment: environment, fades: fades)
                return row
            }
        }
        if count > 0 {
            more.show(count: count, environment: environment)
            listed.append(more)
        }
        let views = listed.map { $0 as NSView }
        if rows.subviews != views { rows.subviews = views }
    }

    /// Shows the Hint of each Window row of an open card: the badge while the user holds its modifier, else its key at
    /// rest when the Config shows Window Hints at all times. A closed card shows none.
    private func showWindowHints() {
        var kept = windowHints
        windowHints = [:]
        if isOpen {
            for case let row as WindowRowView in listed {
                let target = QuickSwitchTarget.window(row.windowID)
                let look: SidebarHintView.Look
                if !environment.hints[target].isEmpty { look = .badge(environment.hints[target]) }
                else if let key = environment.hints.restKey(for: target) { look = .key(key) }
                else { continue }
                let view = kept.removeValue(forKey: row.windowID) ?? SidebarHintView()
                view.show(look, target: target, fontSize: environment.fontSize, scale: environment.displayScale)
                windowHints[row.windowID] = view
            }
        }
        let views = chrome + windowHints.keys.sorted().compactMap { windowHints[$0] }
        if subviews != views { subviews = views }
    }

    /// The card's height at `width`: its header, and under the header of an open card its rows.
    func height(width: CGFloat) -> CGFloat {
        header.height(width: width) + (isOpen ? CardRowsPadding.top + rowsHeight(width: width) + CardRowsPadding.bottom : 0)
    }

    /// The height of the rows in a card `width` wide, with `CardSpacing.row` between two rows.
    private func rowsHeight(width: CGFloat) -> CGFloat {
        let rowWidth = max(0, width - 2 * CardRowsPadding.horizontal)
        return listed.map { $0.height(width: rowWidth) }.reduce(0, +) + CardSpacing.row * CGFloat(max(0, listed.count - 1))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layOut()
    }

    /// Moves the header of an open card to the top of the list's viewport while the card's rows scroll under it.
    /// `top` is the card's top edge in the viewport.
    func stick(cardTop top: CGFloat) {
        guard top != viewportTop else { return }
        viewportTop = top
        placeHeader()
    }

    /// Puts the header at the top of the card, or as far down as it sticks, and the card's Hint on it.
    private func placeHeader() {
        let height = header.height(width: bounds.width)
        let stuck = isOpen ? StuckHeader.offset(cardTop: viewportTop, cardHeight: bounds.height, headerHeight: height) : 0
        header.frame = NSRect(x: 0, y: stuck, width: bounds.width, height: height)
        header.sticks = stuck > 0
        // The header keeps the Hint's place, and the card draws the Hint over it: the key at rest in the place, and the
        // badge with its end at the place's end and its middle on the place's middle.
        let place = header.hintPlace(width: bounds.width)?.offsetBy(dx: 0, dy: stuck) ?? .zero
        hint.frame = place
        let size = badge.size, scale = environment.displayScale
        badge.frame = NSRect(x: (place.maxX - size.width).rounded(toPixelsOf: scale), y: (place.midY - size.height / 2).rounded(toPixelsOf: scale),
                             width: size.width, height: size.height)
    }

    private func layOut() {
        fill.frame = bounds
        outline.frame = bounds
        selection.frame = bounds
        placeHeader()
        rows.frame = NSRect(x: CardRowsPadding.horizontal, y: header.height(width: bounds.width) + CardRowsPadding.top,
                            width: max(0, bounds.width - 2 * CardRowsPadding.horizontal), height: rowsHeight(width: bounds.width))
        var top: CGFloat = 0
        for row in listed {
            row.frame = NSRect(x: 0, y: top, width: rows.bounds.width, height: row.height(width: rows.bounds.width))
            top = row.frame.maxY + CardSpacing.row
        }
        spine.frame = NSRect(x: CardSpine.leading, y: CardSpine.verticalInset, width: CardSpine.width,
                             height: max(0, bounds.height - 2 * CardSpine.verticalInset))
        // A Window row's Hint stands in the room the row keeps before its icon, from the row's top left corner.
        for case let row as WindowRowView in listed {
            guard let view = windowHints[row.windowID] else { continue }
            view.frame = NSRect(origin: NSPoint(x: rows.frame.minX + row.frame.minX + WindowHintMetrics.inset,
                                                y: rows.frame.minY + row.frame.minY + WindowHintMetrics.inset), size: view.size)
        }
    }

    // MARK: Accessibility

    /// The rows of an open card, each Window row by its parts, then the header and the Hints, each a row of its own
    /// because the header hides its children. SwiftUI lists the header after the rows, which it draws above them, and
    /// the Hints by their identifiers.
    override func accessibilityChildren() -> [Any]? {
        let hints = ([hint, badge] + Array(windowHints.values)).filter { !$0.isHidden }
            .sorted { $0.accessibilityIdentifier() < $1.accessibilityIdentifier() }
        return (isOpen ? listed.flatMap(\.accessibilityParts) : []) + [header] + hints
    }

    /// VoiceOver reads the header first, then the rows and the Hint, as SwiftUI's sort priority orders the header.
    override func accessibilityChildrenInNavigationOrder() -> [NSAccessibilityElementProtocol]? {
        let children = (accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElementProtocol }
        return [header] + children.filter { $0 !== header }
    }

    override func accessibilityActivationPoint() -> NSPoint { accessibilityFrame().centre }

    #if DEBUG
    /// The turn of the border's colours and the fade of the spine that run now, for the tests.
    var turnAnimation: CAAnimation? { selection.turnAnimation }
    var spineFade: CAAnimation? { spine.fade }
    /// The opacity of the lock or the Guest mark, and the title's frame in the header, for the tests.
    var markOpacity: CGFloat { header.markOpacity }
    var titleFrame: NSRect { header.titleFrame }
    #endif
}

extension NSRect {
    var centre: NSPoint { NSPoint(x: midX, y: midY) }
}

/// The rows of a card. A closed card's rows take no click and no pointer.
private final class CardRowsView: NSView {
    var isOpen = false {
        didSet {
            for case let row as SidebarRowView in subviews { row.isShown = isOpen }
        }
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { isOpen ? super.hitTest(point) : nil }
}

/// The header of a Session card: the title, after it the place of the card's Hint and the lock or the Guest mark,
/// and on a closed card the bell and the Summary under the title. It lays its parts out as `CardHeader` does in
/// SwiftUI. To accessibility it is one button, which hides its parts. A press on it works on the first click while
/// Muxify is not the front app.
private final class SessionCardHeaderView: SidebarPressView {
    /// The background of the header while it sticks to the top of the list.
    private let backdrop = StuckHeaderBackdropView()
    private let title = SidebarLabel()
    private let guest = SidebarLabel()
    private let lock = SidebarSymbol(CardHeaderMark.lock)
    private let bell = SidebarSymbol(CardHeaderMark.bell)
    private let summary = SidebarLabel()
    private var content = SessionCardContent(title: "")
    private var environment = SessionsListEnvironment()
    /// The frames of the last layout, and the width they were made for.
    private var arranged: (width: CGFloat, frames: Frames)?

    /// Where the parts stand in a header of one width.
    private struct Frames {
        var title = NSRect.zero
        /// The first line of the header, from its leading to its trailing padding, as high as the title.
        var titleLine = NSRect.zero
        var hint: NSRect?
        var mark = NSRect.zero
        var bell = NSRect.zero
        var summary = NSRect.zero
        var height: CGFloat = 0
    }

    init(identifier: String) {
        super.init(frame: .zero)
        guest.text = CardHeaderMark.guest
        guest.ink = .secondary
        summary.ink = .secondary
        backdrop.isHidden = true
        subviews = [backdrop, title, guest, lock, bell, summary]
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier(identifier)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The header sticks to the top of the list, over the rows that scroll under it.
    var sticks = false {
        didSet { backdrop.isHidden = !sticks }
    }

    func show(_ content: SessionCardContent, environment: SessionsListEnvironment) {
        self.content = content
        self.environment = environment
        backdrop.theme = environment.chromeTheme
        let size = environment.fontSize
        title.text = content.title
        title.font = environment.typography.nsFont(for: .session)
        title.wraps = environment.wrapsCardTitles
        guest.font = .systemFont(ofSize: size(CardHeaderFont.mark), weight: .medium)
        lock.pointSize = size(CardHeaderFont.mark)
        bell.pointSize = size(CardHeaderFont.mark)
        summary.text = content.summary
        summary.font = .systemFont(ofSize: size(CardHeaderFont.summary))
        for part in [title, guest, summary] { part.scale = environment.displayScale }
        for part in [lock, bell] { part.scale = environment.displayScale }
        // A part that the card does not show now stays in its place, so it fades there when the card opens or closes.
        // The badge of the card's Hint takes the mark's place while it shows.
        let marks = content.hint?.showsBadge != true
        guest.alphaValue = content.isGuest && marks ? 1 : 0
        lock.alphaValue = content.isLocked && !content.isGuest && marks ? 1 : 0
        bell.alphaValue = showsBell ? 1 : 0
        summary.alphaValue = showsSummary ? 1 : 0
        arranged = nil
        layOut()
    }

    private var showsBell: Bool { !content.isOpen && content.hasBell }
    private var showsSummary: Bool { !content.isOpen && !content.summary.isEmpty }

    func height(width: CGFloat) -> CGFloat { frames(width: width).height }

    /// The place of the card's Hint in a header `width` wide, nil when the card has none.
    func hintPlace(width: CGFloat) -> NSRect? { frames(width: width).hint }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layOut()
    }

    private func layOut() {
        let frames = frames(width: bounds.width)
        backdrop.frame = bounds
        title.frame = frames.title
        (content.isGuest ? guest : lock).frame = frames.mark
        if showsBell { bell.frame = frames.bell }
        if showsSummary { summary.frame = frames.summary }
    }

    /// Lays the header out as SwiftUI lays `CardHeader` out: the fixed parts of the first line take their room, the
    /// title takes what is left, and each part stands with its middle on the middle of the title's first line.
    private func frames(width: CGFloat) -> Frames {
        if let arranged, arranged.width == width { return arranged.frames }
        let scale = environment.displayScale
        let gap = CardHeaderSpacing.titleLine
        let left = CardHeaderPadding.leading
        let room = max(0, width - left - CardHeaderPadding.trailing)
        var frames = Frames()

        let hintSize = content.hint.map { CardRestKeyView.size(key: $0.restKey, fontSize: environment.fontSize, scale: scale) }
        let markSize = content.isGuest ? guest.fit() : content.isLocked ? lock.symbolSize : NSSize.zero
        // The gaps: after the title, after the Hint, and on each side of the space that pushes the marks to the end.
        let fixed = (hintSize.map { $0.width + gap } ?? 0) + 2 * gap + markSize.width
        let titleSize = title.fit(width: max(0, room - fixed))
        let firstLine = title.lineHeight

        // Each part's middle is on one line. The title's is the middle of its first line.
        let middles = [firstLine / 2, (hintSize?.height ?? 0) / 2, markSize.height / 2]
        let heights = [titleSize.height, hintSize?.height ?? 0, markSize.height]
        let above = middles.max() ?? 0
        let lineHeight = above + (zip(heights, middles).map { $0 - $1 }.max() ?? 0)
        let top = CardHeaderPadding.top
        func place(_ size: NSSize, x: CGFloat) -> NSRect {
            NSRect(x: x.rounded(toPixelsOf: scale), y: (top + above - size.height / 2).rounded(toPixelsOf: scale), width: size.width, height: size.height)
        }
        frames.title = NSRect(x: left, y: (top + above - firstLine / 2).rounded(toPixelsOf: scale), width: titleSize.width, height: titleSize.height)
        frames.titleLine = NSRect(x: left, y: top, width: room, height: lineHeight)
        frames.hint = hintSize.map { place($0, x: left + titleSize.width + gap) }
        frames.mark = place(markSize, x: left + room - markSize.width)

        // The lines under the title: the details, which hold the bell, and the Summary.
        var bottom = top + lineHeight + CardHeaderSpacing.lines
        if showsBell {
            frames.bell = NSRect(origin: NSPoint(x: left, y: bottom), size: bell.symbolSize)
            bottom = frames.bell.maxY
        }
        if showsSummary {
            let size = summary.fit(width: room)
            frames.summary = NSRect(x: left, y: bottom + CardHeaderSpacing.lines + CardHeaderSpacing.summaryTop, width: size.width, height: size.height)
            bottom = frames.summary.maxY
        }
        frames.height = bottom + CardHeaderPadding.bottom(isOpen: content.isOpen)
        arranged = (width, frames)
        return frames
    }

    // MARK: Accessibility

    override func accessibilityLabel() -> String? { content.title }

    /// `expanded` or `collapsed`, then `Guest` or `Locked`, then the mark's name.
    override func accessibilityValue() -> Any? {
        ([content.isOpen ? "expanded" : "collapsed"] + (content.isGuest ? ["Guest"] : content.isLocked ? ["Locked"] : [])
            + [content.mark?.rawValue].compactMap { $0 }).joined(separator: ", ")
    }

    /// The Summary of a closed card.
    override func accessibilityHelp() -> String? { content.isOpen ? "" : content.summary }

    override func accessibilityChildren() -> [Any]? { [] }

    /// The middle of the title's line, where a click tool such as Homerow clicks in place of the header's centre.
    override func accessibilityActivationPoint() -> NSPoint {
        guard let window else { return .zero }
        let line = frames(width: bounds.width).titleLine
        return window.convertPoint(toScreen: convert(NSPoint(x: line.midX, y: line.midY), to: nil))
    }

    #if DEBUG
    var markOpacity: CGFloat { (content.isGuest ? guest : lock).alphaValue }
    var titleFrame: NSRect { title.frame }
    #endif
}

/// A card's key at rest, on a faint capsule of the text colour: `CardRestKey` in SwiftUI. It is a row of its own to
/// accessibility, with the identifier of its target and the key as its value.
final class CardRestKeyView: NSView {
    private var layout: SidebarTextLayout?
    private var scale: CGFloat = 2

    init() {
        super.init(frame: .zero)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private static func font(_ fontSize: InterfaceFontSize) -> NSFont {
        let font = NSFont.systemFont(ofSize: fontSize(CardRestKeyMetrics.fontSize), weight: .semibold)
        return font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: font.pointSize) } ?? font
    }

    private static func layout(_ key: String, fontSize: InterfaceFontSize, scale: CGFloat) -> SidebarTextLayout {
        SidebarTextLayout(key, font: font(fontSize), scale: scale)
    }

    /// The room the key takes: the key with its padding, and not less than the capsule's least side.
    static func size(key: String, fontSize: InterfaceFontSize, scale: CGFloat) -> NSSize {
        let text = layout(key, fontSize: fontSize, scale: scale).size
        let side = fontSize(CardRestKeyMetrics.minSide)
        return NSSize(width: max(side, (key.isEmpty ? 0 : text.width) + 2 * CardRestKeyMetrics.horizontalPadding),
                      height: max(side, key.isEmpty ? 0 : text.height))
    }

    /// Shows the key of the Hint at rest, or nothing when the card has no key at rest.
    func show(_ hint: CardHint?, fontSize: InterfaceFontSize, scale: CGFloat) {
        let key = hint?.restKey ?? ""
        isHidden = key.isEmpty
        layout = key.isEmpty ? nil : Self.layout(key, fontSize: fontSize, scale: scale)
        self.scale = scale
        setAccessibilityElement(!key.isEmpty)
        setAccessibilityIdentifier(hint?.target.accessibilityID)
        setAccessibilityValue(key)
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func accessibilityActivationPoint() -> NSPoint { accessibilityFrame().centre }

    override func draw(_ dirtyRect: NSRect) {
        guard let layout else { return }
        NSColor.labelColor.faded(CardRestKeyMetrics.fillOpacity).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        layout.draw(at: NSPoint(x: ((bounds.width - layout.size.width) / 2).rounded(toPixelsOf: scale),
                                y: ((bounds.height - layout.size.height) / 2).rounded(toPixelsOf: scale)),
                    ink: NSColor.labelColor.faded(CardRestKeyMetrics.textOpacity))
    }
}
