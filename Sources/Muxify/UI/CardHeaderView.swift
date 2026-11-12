import AppKit
import MuxifyCore

/// What a card's header shows in the AppKit lists, as `CardHeader` shows it in SwiftUI: the header of a Session card
/// of the Sessions list (ADR 0074), and of a Topic card or a Locked card of the Topics list
/// (docs/adr/0075-muxify-leaves-swiftui-entirely-one-area-at-a-time.md).
struct CardHeaderContent: Equatable {
    var title: String
    /// The Summary, which a closed card shows under its title. Empty for none.
    var summary = ""
    var isOpen = false
    /// The card's mark, which the header names in its accessibility value.
    var mark: CardMark?
    /// The pin of a Pinned Topic after the title, in the place of the Guest mark and the lock.
    var isPinned = false
    var isLocked = false
    /// The Guest mark after the title, in the place of the lock.
    var isGuest = false
    /// A Window of the card rang: a closed card shows the bell in its details line.
    var hasBell = false
    /// The words of the details line, before the bell, such as "Dormant".
    var details: [String] = []
    /// The Topic Note, whole, on a line of its own.
    var note: String?
    /// The Tags of a Topic card. The header keeps their place: at the end of the title's first line, after the pin, or
    /// first in the details line, as their placement says. The card draws them over it.
    var tags: CardTags?
    var hint: CardHint?
    /// Words for the accessibility value after the open state, such as "Pinned" or "Locked".
    var notes: [String] = []
    /// The room the action in the card's bottom-right corner takes, as a design size at 12: the last line of a closed
    /// card stops before it. 0 for a card with no action.
    var cornerWidth: CGFloat = 0
    /// The word in the top-right corner, on the title's first line, such as how long ago a Topic was Settled. The
    /// header keeps its place at the end of that line, and the card draws it there. A closed card then has a line
    /// under its title for the action in its corner, unless a Note or the Summary gives one.
    var cornerLabel: CardCornerLabel?
}

/// The header of a card in an AppKit list: the title, after it the place of the card's Hint and the pin, the Guest
/// mark or the lock, then the place of the Tags in the title line, under it the details line with the bell of a closed
/// card or the place of the Tags on their own line, the Topic Note, and the Summary of a closed card. With Tag chips in
/// the title line, a long title wraps under them at the full width of the header, as `CardHeader` cuts it. It lays its parts out as `CardHeader` does in SwiftUI. To accessibility it is one button, which hides
/// its parts. A press on it works on the first click while Muxify is not the front app.
final class CardHeaderView: SidebarPressView {
    /// The background of the header while it sticks to the top of the list.
    private let backdrop = StuckHeaderBackdropView()
    private let title = SidebarLabel()
    /// The rest of a title that shares its first line with Tag chips, on the lines under them.
    private let titleRest = SidebarLabel()
    private let guest = SidebarLabel()
    private let pin = SidebarSymbol(CardHeaderMark.pin)
    private let lock = SidebarSymbol(CardHeaderMark.lock)
    private let bell = SidebarSymbol(CardHeaderMark.bell)
    /// The words of the details line, from its start.
    private var details: [SidebarLabel] = []
    private let pencil = SidebarSymbol(CardNote.symbol)
    private let note = SidebarLabel()
    private let summary = SidebarLabel()
    private var content = CardHeaderContent(title: "")
    private var environment = SidebarListEnvironment()
    /// The frames of the last layout, and the width they were made for.
    private var arranged: (width: CGFloat, frames: Frames)?
    /// The header's named accessibility actions.
    var actions: () -> SidebarMenu? = { nil }

    /// Where the parts stand in a header of one width.
    private struct Frames {
        var title = NSRect.zero
        /// The first line of the header, from its leading to its trailing padding, as high as the title.
        var titleLine = NSRect.zero
        var hint: NSRect?
        var mark = NSRect.zero
        var titleRest = NSRect.zero
        var tags: NSRect?
        var cornerLabel: NSRect?
        var details: [NSRect] = []
        var bell = NSRect.zero
        var pencil = NSRect.zero
        var note = NSRect.zero
        var summary = NSRect.zero
        var height: CGFloat = 0
    }

    init(identifier: String) {
        super.init(frame: .zero)
        guest.text = CardHeaderMark.guest
        guest.ink = .secondary
        summary.ink = .secondary
        note.wraps = true
        note.ink = .note
        pencil.ink = .note
        backdrop.isHidden = true
        subviews = [backdrop, title, titleRest, guest, pin, lock, bell, pencil, note, summary]
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

    func show(_ content: CardHeaderContent, environment: SidebarListEnvironment) {
        self.content = content
        self.environment = environment
        backdrop.theme = environment.chromeTheme
        let size = environment.fontSize, scale = environment.displayScale
        title.text = content.title
        title.font = environment.typography.nsFont(for: .session)
        title.wraps = environment.wrapsCardTitles
        titleRest.font = title.font
        titleRest.wraps = true
        guest.font = .systemFont(ofSize: size(CardHeaderFont.mark), weight: .medium)
        for symbol in [pin, lock, bell] { symbol.pointSize = size(CardHeaderFont.mark) }
        showDetails(content.details, font: .systemFont(ofSize: size(CardHeaderFont.detail)), scale: scale)
        note.text = content.note ?? ""
        note.font = .systemFont(ofSize: size(CardNote.fontSize))
        pencil.pointSize = size(CardNote.fontSize)
        summary.text = content.summary
        summary.font = .systemFont(ofSize: size(CardHeaderFont.summary))
        for part in [title, titleRest, guest, note, summary] { part.scale = scale }
        for part in [pin, lock, bell, pencil] { part.scale = scale }
        // A part that the card does not show now stays in its place, so it fades there when the card opens or closes.
        // The badge of the card's Hint takes the mark's place while it shows.
        let marks = content.hint?.showsBadge != true
        pin.alphaValue = content.isPinned && marks ? 1 : 0
        guest.alphaValue = content.isGuest && !content.isPinned && marks ? 1 : 0
        lock.alphaValue = content.isLocked && !content.isGuest && !content.isPinned && marks ? 1 : 0
        bell.alphaValue = showsBell ? 1 : 0
        // A closed card's Note is softer, so the open card's Note stays the one that stands out.
        let noteOpacity = content.note == nil ? 0 : content.isOpen ? 1 : CardNote.closedOpacity
        note.alphaValue = noteOpacity
        pencil.alphaValue = noteOpacity
        summary.alphaValue = showsSummary ? 1 : 0
        arranged = nil
        layOut()
    }

    /// One label for each word of the details line, in the secondary text colour.
    private func showDetails(_ words: [String], font: NSFont, scale: CGFloat) {
        while details.count < words.count {
            let label = SidebarLabel()
            label.ink = .secondary
            details.append(label)
            addSubview(label)
        }
        for (index, label) in details.enumerated() {
            label.text = index < words.count ? words[index] : ""
            label.font = font
            label.scale = scale
            label.isHidden = index >= words.count
        }
    }

    private var showsBell: Bool { !content.isOpen && content.hasBell }
    private var showsSummary: Bool { !content.isOpen && !content.summary.isEmpty }

    func height(width: CGFloat) -> CGFloat { frames(width: width).height }

    /// The place of the card's Hint in a header `width` wide, nil when the card has none.
    func hintPlace(width: CGFloat) -> NSRect? { frames(width: width).hint }

    /// The place of the card's Tags in a header `width` wide, nil when the card shows none.
    func tagsPlace(width: CGFloat) -> NSRect? { frames(width: width).tags }

    /// The place of the word in the card's top-right corner in a header `width` wide, nil when the card has none.
    func cornerLabelPlace(width: CGFloat) -> NSRect? { frames(width: width).cornerLabel }

    /// The font of the word in the card's top-right corner.
    static func cornerLabelFont(_ environment: SidebarListEnvironment) -> NSFont {
        .systemFont(ofSize: environment.fontSize(CardCorner.labelFontSize))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layOut()
    }

    private func layOut() {
        let frames = frames(width: bounds.width)
        backdrop.frame = bounds
        title.frame = frames.title
        titleRest.frame = frames.titleRest
        (content.isPinned ? pin : content.isGuest ? guest : lock).frame = frames.mark
        for (label, frame) in zip(details, frames.details) { label.frame = frame }
        if showsBell { bell.frame = frames.bell }
        if content.note != nil {
            pencil.frame = frames.pencil
            note.frame = frames.note
        }
        if showsSummary { summary.frame = frames.summary }
    }

    /// Lays the header out as SwiftUI lays `CardHeader` out: the fixed parts of the first line take their room, the
    /// title takes what is left, and each part stands with its middle on the middle of the title's first line. The
    /// lines under it stand `CardHeaderSpacing.lines` apart, and the details line is one of them also when it is empty.
    private func frames(width: CGFloat) -> Frames {
        if let arranged, arranged.width == width { return arranged.frames }
        let scale = environment.displayScale
        let gap = CardHeaderSpacing.titleLine
        let left = CardHeaderPadding.leading
        let room = max(0, width - left - CardHeaderPadding.trailing)
        // The action in the card's corner: the last line of a closed card stops before it.
        let corner = environment.fontSize(content.cornerWidth)
        var frames = Frames()

        let hintSize = content.hint.map { CardRestKeyView.size(key: $0.restKey, fontSize: environment.fontSize, scale: scale) }
        let hasMark = content.isPinned || content.isGuest || content.isLocked
        let markSize = content.isPinned ? pin.symbolSize : content.isGuest ? guest.fit() : content.isLocked ? lock.symbolSize : NSSize.zero
        let lineTags = content.tags.flatMap { $0.placement == .corner || $0.placement == .title ? $0 : nil }
        let lineTagsSize = lineTags.map { CardTagsLayout($0, fontSize: environment.fontSize, scale: scale).size }
        let labelSize = content.cornerLabel.map { SidebarTextLayout($0.text, font: Self.cornerLabelFont(environment), scale: scale).size }
        // The marks at the end of the line: the pin, the Guest mark or the lock, the Tags, then the place of the word in
        // the corner.
        let endParts = (hasMark ? [markSize.width] : []) + (lineTagsSize.map { [$0.width] } ?? []) + (labelSize.map { [$0.width] } ?? [])
        let endWidth = endParts.reduce(0, +) + CGFloat(max(0, endParts.count - 1)) * gap
        // A closed card with no Summary ends with its first line, which then stops before the corner's action, unless
        // the word in the corner puts the action on a line of its own.
        let lineRoom = max(0, room - (!content.isOpen && content.summary.isEmpty && content.cornerLabel == nil ? corner : 0))
        let labelRoom = labelSize.map { $0.width + gap } ?? 0
        // The gaps: after the title, after the Hint, and on each side of the space that pushes the marks to the end.
        let fixed = (hintSize.map { $0.width + gap } ?? 0) + 2 * gap + endWidth
        // With Tag chips in the title line, a long title wraps under them: its first line takes the words that fit.
        let lines = environment.wrapsCardTitles && content.tags?.placement == .title && lineRoom > 0
            ? TitleLines.split(content.title, font: title.font,
                               width: TitleLines.firstLineRoom(lineWidth: lineRoom, hintWidth: hintSize?.width ?? 0, endWidth: endWidth))
            : nil
        title.text = lines?.first ?? content.title
        title.wraps = lines == nil && environment.wrapsCardTitles
        titleRest.text = lines?.rest ?? ""
        let titleSize = lines == nil ? title.fit(width: max(0, lineRoom - fixed)) : title.fit()
        let firstLine = title.lineHeight

        // Each part's middle is on one line. The title's is the middle of its first line.
        let middles = [firstLine / 2, (hintSize?.height ?? 0) / 2, markSize.height / 2, (lineTagsSize?.height ?? 0) / 2,
                       (labelSize?.height ?? 0) / 2]
        let heights = [titleSize.height, hintSize?.height ?? 0, markSize.height, lineTagsSize?.height ?? 0, labelSize?.height ?? 0]
        let above = middles.max() ?? 0
        let lineHeight = above + (zip(heights, middles).map { $0 - $1 }.max() ?? 0)
        let top = CardHeaderPadding.top
        func place(_ size: NSSize, x: CGFloat) -> NSRect {
            NSRect(x: x.rounded(toPixelsOf: scale), y: (top + above - size.height / 2).rounded(toPixelsOf: scale), width: size.width, height: size.height)
        }
        frames.title = NSRect(x: left, y: (top + above - firstLine / 2).rounded(toPixelsOf: scale), width: titleSize.width, height: titleSize.height)
        frames.titleLine = NSRect(x: left, y: top, width: room, height: lineHeight)
        frames.hint = hintSize.map { place($0, x: left + titleSize.width + gap) }
        frames.mark = place(markSize, x: left + lineRoom - endWidth)
        frames.tags = lineTagsSize.map { place($0, x: left + lineRoom - labelRoom - $0.width) }
        // At the header's trailing padding, as the card's overlay puts it.
        frames.cornerLabel = labelSize.map { place($0, x: width - CardCorner.labelTrailing - $0.width) }
        var bottom = top + lineHeight

        // The rest of a title cut under its Tag chips, at the header's full width.
        if !titleRest.text.isEmpty {
            frames.titleRest = NSRect(origin: NSPoint(x: left, y: bottom + CardHeaderSpacing.lines), size: titleRest.fit(width: room))
            bottom = frames.titleRest.maxY
        }

        // The details line: the Tags on their own line, its words, then the bell of a closed card, each with its middle on
        // the line's middle.
        bottom += CardHeaderSpacing.lines
        let words = details.prefix(content.details.count).map { $0.fit() }
        let ownLineTags = content.tags.flatMap { $0.placement == .line ? $0 : nil }
        let ownLineTagsSize = ownLineTags.map {
            CardTagsLayout($0, width: Self.tagsOffer($0, words: words, room: room, environment: environment), fontSize: environment.fontSize,
                           scale: scale).size
        }
        let parts = (ownLineTagsSize.map { [$0] } ?? []) + words + (showsBell ? [bell.symbolSize] : [])
        let detailsHeight = parts.map(\.height).max() ?? 0
        var x = left
        var placed = parts.map { size -> NSRect in
            defer { x += size.width + CardHeaderSpacing.details }
            return NSRect(x: x.rounded(toPixelsOf: scale), y: (bottom + (detailsHeight - size.height) / 2).rounded(toPixelsOf: scale),
                          width: size.width, height: size.height)
        }
        if ownLineTagsSize != nil { frames.tags = placed.removeFirst() }
        frames.details = Array(placed.prefix(words.count))
        if showsBell { frames.bell = placed[words.count] }
        bottom += detailsHeight

        // The Note: the pencil and the text that wraps after it, on one baseline.
        if content.note != nil {
            let noteRoom = max(0, room - (!content.isOpen && content.summary.isEmpty ? corner : 0))
            let pencilSize = pencil.symbolSize
            let textSize = note.fit(width: max(0, noteRoom - pencilSize.width - CardNote.spacing))
            let lineTop = bottom + CardHeaderSpacing.lines + CardNote.top
            let textBaseline = SidebarTextLayout.baseline(of: note.font), pencilBaseline = pencil.baseline
            let baseline = max(textBaseline, pencilBaseline)
            frames.pencil = NSRect(x: left, y: (lineTop + baseline - pencilBaseline).rounded(toPixelsOf: scale),
                                   width: pencilSize.width, height: pencilSize.height)
            frames.note = NSRect(x: left + pencilSize.width + CardNote.spacing, y: (lineTop + baseline - textBaseline).rounded(toPixelsOf: scale),
                                 width: textSize.width, height: textSize.height)
            bottom = max(frames.pencil.maxY, frames.note.maxY)
        }

        if showsSummary {
            let size = summary.fit(width: max(0, room - corner))
            frames.summary = NSRect(x: left, y: bottom + CardHeaderSpacing.lines + CardHeaderSpacing.summaryTop, width: size.width, height: size.height)
            bottom = frames.summary.maxY
        }
        // The line of the corner's action under a closed card's title, when the word in the corner takes the room it
        // has at the end of the title's line.
        if content.cornerLabel != nil, !content.isOpen, content.note == nil, !showsSummary {
            bottom += CardHeaderSpacing.lines + CardCorner.actionLineHeight(environment.fontSize)
        }
        frames.height = bottom + CardHeaderPadding.bottom(isOpen: content.isOpen)
        arranged = (width, frames)
        return frames
    }

    /// The room the details line offers Tags on their own line, as SwiftUI's `HStack` shares out its width: the least
    /// flexible part first, each part offered an even share of the room that is left. A word can give up all its width,
    /// and the Tags the width between their widest row and "+N" alone.
    private static func tagsOffer(_ tags: CardTags, words: [NSSize], room: CGFloat, environment: SidebarListEnvironment) -> CGFloat {
        let widest = CardTagsLayout(tags, fontSize: environment.fontSize, scale: environment.displayScale).size.width
        let narrowest = CardTagsLayout(tags, width: 0, fontSize: environment.fontSize, scale: environment.displayScale).size.width
        // The parts by how far they can shrink, the Tags as nil.
        let parts = ([(flexibility: widest - narrowest, width: nil)] + words.map { (flexibility: $0.width, width: Optional($0.width)) })
            .enumerated().sorted { ($0.element.flexibility, $0.offset) < ($1.element.flexibility, $1.offset) }.map(\.element)
        var left = room - CGFloat(words.count) * CardHeaderSpacing.details
        for (index, part) in parts.enumerated() {
            let offer = left / CGFloat(parts.count - index)
            guard let width = part.width else { return max(0, offer) }
            left -= min(width, offer)
        }
        return max(0, left)
    }

    // MARK: Accessibility

    override func accessibilityLabel() -> String? { content.title }

    /// `expanded` or `collapsed`, then the notes, such as `Pinned` or `Locked`, the mark's name and the Note.
    override func accessibilityValue() -> Any? {
        ([content.isOpen ? "expanded" : "collapsed"] + content.notes
            + [content.mark?.rawValue, content.note.map { "Note: " + $0 }].compactMap { $0 }).joined(separator: ", ")
    }

    /// The Summary of a closed card.
    override func accessibilityHelp() -> String? { content.isOpen ? "" : content.summary }

    override func accessibilityChildren() -> [Any]? { [] }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? { actions()?.accessibilityActions }

    /// The middle of the title's line, where a click tool such as Homerow clicks in place of the header's centre.
    override func accessibilityActivationPoint() -> NSPoint {
        guard let window else { return .zero }
        let line = frames(width: bounds.width).titleLine
        return window.convertPoint(toScreen: convert(NSPoint(x: line.midX, y: line.midY), to: nil))
    }
}

/// A card's Hint over its header: the key at rest in the place that the header keeps for it, or the badge while the
/// user holds the Hint's modifier, with its end at the place's end and its middle on the place's middle, so it grows
/// over the title. Each is a row of its own to accessibility, in the card.
@MainActor final class CardHintViews {
    let key = CardRestKeyView()
    let badge = SidebarHintView()
    private var scale: CGFloat = 2

    /// The views, from the back.
    var views: [NSView] { [key, badge] }

    /// The views that show, as accessibility rows.
    var shown: [NSView] { views.filter { !$0.isHidden } }

    func show(_ hint: CardHint?, environment: SidebarListEnvironment) {
        scale = environment.displayScale
        let held = hint.flatMap { $0.showsBadge ? $0 : nil }
        key.show(held == nil ? hint : nil, fontSize: environment.fontSize, scale: scale)
        badge.isHidden = held == nil
        if let held { badge.show(.badge(held.triggers), target: held.target, fontSize: environment.fontSize, scale: scale) }
    }

    /// Puts the Hint over its place, in the coordinates of the views' superview. No place puts it nowhere.
    func place(_ place: NSRect?) {
        let place = place ?? .zero
        key.frame = place
        let size = badge.size
        badge.frame = NSRect(x: (place.maxX - size.width).rounded(toPixelsOf: scale), y: (place.midY - size.height / 2).rounded(toPixelsOf: scale),
                             width: size.width, height: size.height)
    }
}

extension NSColor {
    /// The yellow of a Topic Note, in the light or the dark appearance that draws.
    static let cardNote = NSColor(name: nil) { appearance in
        let color = appearance.isDark ? CardNote.dark : CardNote.light
        return NSColor(red: color.red, green: color.green, blue: color.blue, alpha: 1)
    }
}
