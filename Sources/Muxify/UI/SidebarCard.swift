import SwiftUI
import MuxifyCore

/// One Topic or Session in the Sidebar. Closed, the card is flat, with only its border; open, it is raised and lists
/// its Window and Pane rows, and its header stays at the top of the list while its rows scroll under it. A spine on the
/// left edge shows the Agent mark of its Agents. The card that holds the selected Window has a many-coloured border,
/// which turns once when the selection comes to it from another card, so a closed card still shows where the user is.
/// A right-click anywhere on the card shows its menu, except on a row or a heading with its own menu.
struct SidebarCard<Header: View, Content: View, CardMenu: View>: View {
    let isOpen: Bool
    let holdsSelection: Bool
    let mark: CardMark?
    /// The coordinate space of the scroll view around the list, in which the open card's header sticks to the top.
    var viewport: String? = nil
    var restingOpacity: Double = 1
    /// The card's accessibility identifier: `card-` and its header's identifier. The card offers its menu's items as
    /// accessibility actions, so a check reaches the menu of the space around the rows without opening it.
    let identifier: String
    @Environment(\.quickSwitchHints) private var hints
    @ViewBuilder var header: () -> Header
    @ViewBuilder var content: () -> Content
    /// The card's context menu: on its header, its padding, the gaps between its rows and its footer line.
    @ViewBuilder var menu: () -> CardMenu

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.chromeTheme) private var chromeTheme
    /// The card's frame in the viewport, kept as it was while a drag lifts the card, so the header does not stick to the
    /// top of the viewport when the card is dragged past it.
    @State private var frame: CGRect = .zero
    @Environment(\.isLiftedByDrag) private var isLifted
    @Environment(\.scrollTopInset) private var scrollTopInset
    /// The card moved while lifted, so the header glides to its new place once the card lands.
    @State private var movedWhileLifted = false
    @State private var headerHeight: CGFloat = 0
    @State private var turn: Double = 0

    /// How far the header moves down to stay at the top of the viewport, or under a block that sticks there, never past
    /// the card's last row.
    private var stuck: CGFloat {
        guard isOpen, viewport != nil else { return 0 }
        return StuckHeader.offset(cardTop: frame.minY, cardHeight: frame.height, headerHeight: headerHeight, inset: scrollTopInset)
    }

    var body: some View {
        #if DEBUG
        BodyCount.tick("SidebarCard")
        #endif
        return VStack(alignment: .leading, spacing: 0) {
            header()
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
                .background {
                    if stuck > 0 {
                        ZStack {
                            Color.clear.chrome(theme: chromeTheme, material: .sidebar)
                            Color.primary.opacity(StuckHeader.fillOpacity)
                        }
                        .overlay(alignment: .bottom) { Divider() }
                    }
                }
                .offset(y: stuck)
                // Above the rows that scroll under it. That also lists it after them among the accessibility children,
                // so its sort priority keeps it first for VoiceOver.
                .zIndex(1)
                .accessibilitySortPriority(1)
            if isOpen {
                VStack(alignment: .leading, spacing: CardSpacing.row) { content() }
                    .padding(.horizontal, CardRowsPadding.horizontal)
                    .padding(.top, CardRowsPadding.top)
                    .padding(.bottom, CardRowsPadding.bottom)
                    // A row dragged up stops at the bottom of the header that sticks to the top, not under it.
                    .environment(\.dragTopInset, stuck > 0 ? max(0, frame.minY + stuck + headerHeight) : 0)
            }
        }
        .background {
            if isOpen {
                shape.fill(Color.primary.opacity(CardOutline.openFillOpacity))
                    .shadow(color: .black.opacity(CardOutline.shadowOpacity), radius: CardOutline.shadowRadius, y: CardOutline.shadowDrop)
            }
        }
        .overlay(alignment: .leading) {
            if let mark {
                RowMarkSpine(mark: mark)
                    .frame(width: CardSpine.width)
                    .padding(.vertical, CardSpine.verticalInset)
                    .padding(.leading, CardSpine.leading)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            Group {
                if holdsSelection { BalatroBorder(angle: turn, shape: shape) } else {
                    shape.strokeBorder(Color.primary.opacity(CardOutline.borderOpacity), lineWidth: CardOutline.borderWidth)
                }
            }
            .allowsHitTesting(false)
        }
        // On the whole card, so the space around the rows has it too. A row or heading with its own menu keeps that one.
        .contextMenu { menu() }
        .opacity(restingOpacity)
        .cardHints(hints)
        // A container, in which the header's sort priority applies.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("card-" + identifier)
        .accessibilityActions { menu() }
        .onChange(of: holdsSelection) { _, holds in
            guard holds, !reduceMotion else { return }
            turn = CardSelectionBorder.turnStart
            let curve = CardSelectionBorder.turnCurve
            withAnimation(.timingCurve(curve.x1, curve.y1, curve.x2, curve.y2, duration: CardSelectionBorder.turnDuration)) { turn = 0 }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(viewport ?? "")) } action: { frame in
            guard viewport != nil else { return }
            guard !isLifted else {
                movedWhileLifted = true
                return
            }
            if movedWhileLifted {
                movedWhileLifted = false
                withAnimation(.spring(duration: 0.3, bounce: 0.15)) { self.frame = frame }
            } else {
                self.frame = frame
            }
        }
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: CardOutline.cornerRadius, style: .continuous) }
}

/// The border of the card that holds the selected Window: the colours of a Balatro card's edge, around the card.
/// SwiftUI animates `angle`, so a change of it turns the colours.
private struct BalatroBorder: View, Animatable {
    var angle: Double
    let shape: RoundedRectangle

    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    private static let colors: [Color] = CardSelectionBorder.colors.map { Color(red: $0.red, green: $0.green, blue: $0.blue) }

    var body: some View {
        shape.strokeBorder(AngularGradient(colors: Self.colors, center: .center, angle: .degrees(angle)), lineWidth: CardSelectionBorder.width)
            .saturation(CardSelectionBorder.saturation)
    }
}

private struct ChromeThemeKey: EnvironmentKey {
    static let defaultValue: TerminalTheme? = nil
}

extension EnvironmentValues {
    /// The Ghostty theme that the header and the Sidebar take their background from, nil for the system materials.
    var chromeTheme: TerminalTheme? {
        get { self[ChromeThemeKey.self] }
        set { self[ChromeThemeKey.self] = newValue }
    }
}

private struct WrapsCardTitlesKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// `sidebar.titles.wrap`: a card title wraps so it always shows whole. False keeps it on one line, cut with "…".
    var wrapsCardTitles: Bool {
        get { self[WrapsCardTitlesKey.self] }
        set { self[WrapsCardTitlesKey.self] = newValue }
    }
}

/// A card's header: the title on its own line, wrapped so it shows whole unless the Config keeps it on one line, a line
/// of details under it, and, on a closed card, a summary of what the card holds. The card gives it the press that
/// opens or closes it.
struct CardHeader<Details: View>: View {
    let title: String
    let isOpen: Bool
    let mark: CardMark?
    var isPinned = false
    /// A Locked Session's card shows a lock where a Pinned Topic's card shows its pin.
    var isLocked = false
    /// A Guest's card shows the Guest mark there.
    var isGuest = false
    var hintTarget: QuickSwitchTarget? = nil
    @Environment(\.quickSwitchHints) private var hints
    /// Words for the accessibility value after the open state, such as "Dormant".
    var notes: [String] = []
    let summary: String
    /// The room the action in the card's bottom-right corner takes, so the last line of a closed card stops before it.
    var cornerWidth: CGFloat = 0
    var tags: CardTags? = nil
    /// The Topic Note. Every card shows it whole on its own line, softer on a closed card.
    var note: String? = nil
    /// A word in the top-right corner, on the title's first line, such as how long ago a Topic was Settled. The
    /// bottom-right action then goes on a line under the title.
    var cornerLabel: CardCornerLabel? = nil
    @ViewBuilder var details: () -> Details
    @Environment(\.sidebarTypography) private var typography
    @Environment(\.interfaceFontSize) private var fontSize
    @Environment(\.wrapsCardTitles) private var wrapsTitle
    /// The title line's frame in the header, where a click tool such as Homerow clicks in place of the header's centre.
    @State private var titleLine: CGRect = .zero
    /// The title line's width, and the width of the Hint and of the marks after the title, for a title that shares its
    /// first line with Tag chips.
    @State private var titleLineWidth: CGFloat = 0
    @State private var hintWidth: CGFloat = 0
    @State private var titleLineEnd: CGFloat = 0

    private static var space: String { "card-header" }

    private var showsSummary: Bool { !isOpen && !summary.isEmpty }

    /// Tag Marks and Tag chips sit in the right corner of the title's first line, after the Pin or Lock.
    private var tagsInTitleLine: CardTags? {
        guard let tags, tags.placement == .corner || tags.placement == .title else { return nil }
        return tags
    }

    /// With Tag chips in the title line, a long title wraps under them at the full card width, which SwiftUI's
    /// `Text` cannot do: the title is cut into its first line and the rest.
    private var titleLines: (first: String, rest: String)? {
        guard wrapsTitle, tags?.placement == .title, titleLineWidth > 0 else { return nil }
        let room = TitleLines.firstLineRoom(lineWidth: titleLineWidth, hintWidth: hintWidth, endWidth: titleLineEnd)
        return TitleLines.split(title, font: typography.nsFont(for: .session), width: room)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CardHeaderSpacing.lines) {
            HStack(alignment: .titleLine, spacing: CardHeaderSpacing.titleLine) {
                ZStack(alignment: .topLeading) {
                    if let titleLines {
                        Text(titleLines.first).font(typography.font(for: .session)).fixedSize()
                    } else {
                        Text(title)
                            .font(typography.font(for: .session))
                            .lineLimit(wrapsTitle ? nil : 1)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // One line of the title's font: its centre is the centre of the title's first line.
                    Text(" ").font(typography.font(for: .session)).hidden()
                        .alignmentGuide(.titleLine) { $0[VerticalAlignment.center] }
                }
                if let hintTarget {
                    CardHintSlot(target: hintTarget).onGeometryChange(for: CGFloat.self) { $0.size.width } action: { hintWidth = $0 }
                }
                Spacer(minLength: 0)
                HStack(alignment: .titleLine, spacing: CardHeaderSpacing.titleLine) {
                    // The Hint badge takes the mark's place while it shows.
                    let markOpacity: Double = hintTarget.map { hints[$0].isEmpty ? 1 : 0 } ?? 1
                    if isPinned { PinMark().opacity(markOpacity) } else if isGuest { GuestMark().opacity(markOpacity) }
                    else if isLocked { LockMark().opacity(markOpacity) }
                    if let tagsInTitleLine { CardTagsSlot(tags: tagsInTitleLine) }
                    // Keeps the title clear of the label, which `cardCornerLabel` shows as its own accessibility element.
                    if let cornerLabel { CardCornerLabelText(label: cornerLabel).hidden() }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { titleLineEnd = $0 }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { titleLineWidth = $0 }
            .padding(.trailing, !isOpen && summary.isEmpty && cornerLabel == nil ? cornerWidth : 0)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { titleLine = $0 }
            if let rest = titleLines?.rest, !rest.isEmpty {
                Text(rest).font(typography.font(for: .session)).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: CardHeaderSpacing.details) {
                if let tags, tags.placement == .line { CardTagsSlot(tags: tags) }
                details()
            }
            if let note {
                NoteLine(note: note, isOpen: isOpen)
                    .padding(.trailing, !isOpen && summary.isEmpty ? cornerWidth : 0)
            }
            if showsSummary {
                Text(summary)
                    .font(fontSize.font(CardHeaderFont.summary))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.top, CardHeaderSpacing.summaryTop)
                    .padding(.trailing, cornerWidth)
            }
            if cornerLabel != nil, !isOpen, note == nil, !showsSummary {
                Color.clear.frame(height: CardCorner.actionLineHeight(fontSize))
            }
        }
        .padding(.leading, CardHeaderPadding.leading).padding(.trailing, CardHeaderPadding.trailing)
        .padding(.top, CardHeaderPadding.top).padding(.bottom, CardHeaderPadding.bottom(isOpen: isOpen))
        .coordinateSpace(.named(Self.space))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(title)
        .accessibilityHint(isOpen ? "" : summary)
        .accessibilityActivationPoint(CGPoint(x: titleLine.midX, y: titleLine.midY))
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        ([isOpen ? "expanded" : "collapsed"] + notes + [mark?.rawValue, note.map { "Note: " + $0 }].compactMap { $0 }).joined(separator: ", ")
    }
}

/// The Topic Note on a card: a pencil and the whole text, in a yellow that reads on the light and the dark Sidebar. A
/// closed card shows it softer, so the open card's Note stays the one that stands out.
private struct NoteLine: View {
    let note: String
    let isOpen: Bool
    @Environment(\.interfaceFontSize) private var fontSize

    private static let color = Color(nsColor: .cardNote)

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: CardNote.spacing) {
            Image(systemName: CardNote.symbol)
            Text(note).fixedSize(horizontal: false, vertical: true)
        }
        .font(fontSize.font(CardNote.fontSize))
        .foregroundStyle(Self.color.opacity(isOpen ? 1 : CardNote.closedOpacity))
        .padding(.top, CardNote.top)
    }
}

extension VerticalAlignment {
    private enum TitleLine: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat { context[VerticalAlignment.center] }
    }

    /// The centre of a card title's first line, so the marks after a wrapped title stay on that line.
    static let titleLine = VerticalAlignment(TitleLine.self)
}

/// The mark after a Pinned Topic's title.
struct PinMark: View {
    @Environment(\.interfaceFontSize) private var fontSize

    var body: some View {
        Image(systemName: CardHeaderMark.pin).font(fontSize.font(CardHeaderFont.mark)).foregroundStyle(.secondary)
    }
}

/// The mark after a Guest's title: a card In Play above `topics.in_play`.
struct GuestMark: View {
    @Environment(\.interfaceFontSize) private var fontSize

    var body: some View {
        Text(CardHeaderMark.guest).font(fontSize.font(CardHeaderFont.mark, weight: .medium)).foregroundStyle(.secondary)
    }
}

/// The mark after a Locked Session's title.
struct LockMark: View {
    @Environment(\.interfaceFontSize) private var fontSize

    var body: some View {
        Image(systemName: CardHeaderMark.lock).font(fontSize.font(CardHeaderFont.mark)).foregroundStyle(.secondary)
    }
}

extension Animation {
    /// The glide of a card that opens or closes.
    static let cardOpens = Animation.easeOut(duration: CardMotion.openDuration)

    /// Runs the change that opens or closes a card with the card's glide, as `TopicCardPress` asks.
    static func opensCard(_ change: () -> Void) {
        withAnimation(.cardOpens, change)
    }
}

/// A Window row and the Pane rows under it, which move together; or a Pane row that stands in for its Session's only
/// Window row, which does not move.
private struct WindowUnit: Identifiable {
    let id: String
    let window: TmuxWindow?
    var items: [TopicsModel.SessionChildren.Item]

    static func units(_ items: [TopicsModel.SessionChildren.Item]) -> [WindowUnit] {
        var units: [WindowUnit] = []
        for item in items {
            switch item {
            case .window(let window):
                units.append(WindowUnit(id: window.id, window: window, items: [item]))
            case .pane(let row) where row.isUnderWindowRow && units.last?.window?.id == row.window.id:
                units[units.count - 1].items.append(item)
            case .pane:
                units.append(WindowUnit(id: item.id, window: nil, items: [item]))
            }
        }
        return units
    }
}

/// An open card's list: each block's heading and rows, cut at `CardRows.limit` with "N more…" below.
/// A block whose rows are all cut loses its heading too. A drag on a Window row moves the Window within its
/// Session; with `blockDrag`, a drag on a heading moves its whole block.
struct CardList<Heading: View, Row: View>: View {
    let blocks: [CardBlock]
    /// The card header's identifier; the button is `<identifier>-more`.
    let identifier: String
    let selectedWindowID: String?
    let showsAll: Bool
    let onShowAll: () -> Void
    /// The card shows an action in its bottom-right corner, so the list ends with a footer line for it, beside
    /// "N more…" when that shows.
    var reservesCorner = false
    var agentSpines: [String: AgentMark] = [:]
    /// The drag of whole blocks, which the headings start; nil while the blocks keep their order.
    var blockDrag: ListDrag<String>? = nil
    let windows: WindowRowDrag
    @ViewBuilder var heading: (CardBlock) -> Heading
    @ViewBuilder var row: (TopicsModel.SessionChildren.Item) -> Row

    @State private var windowDrag = ListDrag<String>(spacing: CardSpacing.row)
    @Environment(\.interfaceFontSize) private var fontSize

    var body: some View {
        let total = blocks.reduce(0) { $0 + $1.items.count }
        let shown = CardRows.shownCount(blocks.flatMap(\.items), selectedWindowID: selectedWindowID, showsAll: showsAll)
        let hiddenMark = blocks.flatMap(\.items).dropFirst(shown).compactMap { agentSpines[$0.id] }.max()
        let starts = blocks.indices.map { index in blocks[..<index].reduce(0) { $0 + $1.items.count } }
        let visible = blocks.indices.filter { starts[$0] < shown }.map { index in
            CardBlock(id: blocks[index].id, items: Array(blocks[index].items.prefix(shown - starts[index])))
        }
        let blockIDs = visible.map(\.id)
        // The dividers stay with the blocks they top, so they hide while a block moves.
        let movingBlock = blockDrag?.dragged != nil
        VStack(alignment: .leading, spacing: CardSpacing.block) {
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, block in
                let view = blockView(block)
                    .overlay(alignment: .top) {
                        if index > 0 {
                            Divider().padding(.horizontal, CardBlockDivider.inset).offset(y: -CardBlockDivider.rise)
                                .opacity(movingBlock ? 0 : 1)
                                .animation(.easeOut(duration: 0.15), value: movingBlock)
                        }
                    }
                // A moving Window stays above the next block when it gives way past the end of its own.
                let holdsMovingWindow = windowDrag.dragged.map { id in block.items.contains { $0.id == id } } ?? false
                if let blockDrag {
                    view.listDragItem(block.id, drag: blockDrag, shown: blockIDs, cornerRadius: 7)
                        .zIndex(blockDrag.dragged == block.id ? 30 : holdsMovingWindow ? 20 : 0)
                } else {
                    view.zIndex(holdsMovingWindow ? 20 : 0)
                }
            }
        }
        if shown < total {
            Button(action: onShowAll) {
                Text(MoreRowMetrics.text(total - shown))
                    .font(fontSize.font(MoreRowMetrics.fontSize))
                    .foregroundStyle(.secondary)
                    .padding(.leading, MoreRowMetrics.leading)
                    .frame(maxWidth: .infinity, minHeight: fontSize(MoreRowMetrics.minHeight), alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(alignment: .leading) {
                if let mark = hiddenMark {
                    AgentMarkSpine(mark: mark)
                        .frame(width: 3)
                        .padding(.vertical, 3)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .padding(.trailing, reservesCorner ? CardCorner.width(fontSize) : 0)
            .accessibilityIdentifier(identifier + "-more")
            .accessibilityValue(hiddenMark?.rawValue ?? "")
        } else if reservesCorner {
            Color.clear.frame(height: CardCorner.footerHeight(fontSize))
        }
    }

    private func markedRow(_ item: TopicsModel.SessionChildren.Item) -> some View {
        row(item).overlay(alignment: .leading) {
            if let mark = agentSpines[item.id] {
                AgentMarkSpine(mark: mark)
                    .frame(width: 3)
                    .padding(.vertical, 3)
                    .allowsHitTesting(false)
                    .accessibilityLabel(mark.rawValue)
                    .accessibilityIdentifier("topic-agent-mark-" + item.id)
            }
        }
    }

    private func blockView(_ block: CardBlock) -> some View {
        let units = WindowUnit.units(block.items)
        let windowIDs = units.compactMap(\.window?.id)
        return VStack(alignment: .leading, spacing: CardSpacing.row) {
            heading(block)
            ForEach(units) { unit in
                if let window = unit.window {
                    VStack(alignment: .leading, spacing: CardSpacing.row) {
                        ForEach(unit.items) { item in
                            if case .window = item {
                                markedRow(item).listDrag(window.id, drag: windowDrag, isEnabled: windows.isEnabled && windowIDs.count > 1,
                                                        onTap: { windows.select(window) }) { windows.move(window, $0) }
                            } else {
                                markedRow(item)
                            }
                        }
                    }
                    .listDragItem(window.id, drag: windowDrag, shown: windowIDs, cornerRadius: WindowRowMetrics.cornerRadius)
                } else {
                    ForEach(unit.items) { markedRow($0) }
                }
            }
        }
    }
}

/// The word a card shows in its top-right corner, above its action.
struct CardCornerLabel {
    let text: String
    let accessibilityID: String
}

private struct CardCornerLabelText: View {
    let label: CardCornerLabel
    @Environment(\.interfaceFontSize) private var fontSize

    var body: some View {
        Text(label.text).font(fontSize.font(11)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
    }
}

extension View {
    /// Shows the label that a `CardHeader` keeps room for, centred on the title's first line. Apply it after the
    /// card's own accessibility identifier, which would otherwise name the label too.
    func cardCornerLabel(_ label: CardCornerLabel?) -> some View {
        overlay(alignment: Alignment(horizontal: .trailing, vertical: .titleLine)) {
            if let label {
                CardCornerLabelText(label: label)
                    .padding(.trailing, 10)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier(label.accessibilityID)
            }
        }
    }

    func cardCorner<Action: View>(@ViewBuilder _ action: () -> Action) -> some View {
        overlay(alignment: .bottomTrailing) { action().padding(.trailing, CardCorner.trailing).padding(.bottom, CardCorner.bottom) }
    }
}
