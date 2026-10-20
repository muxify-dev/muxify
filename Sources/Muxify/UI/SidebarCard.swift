import SwiftUI
import MuxifyCore

/// One Topic or Session in the Sidebar. Closed, the card is flat, with only its border; open, it is raised and lists
/// its Window and Pane rows, and its header stays at the top of the list while its rows scroll under it. A spine on the
/// left edge shows the Agent mark of its Agents. The card that holds the selected Window has a many-coloured border,
/// which turns once when the selection comes to it from another card, so a closed card still shows where the user is.
struct SidebarCard<Header: View, Content: View>: View {
    let isOpen: Bool
    let holdsSelection: Bool
    let mark: RowMark?
    /// The coordinate space of the scroll view around the list, in which the open card's header sticks to the top.
    var viewport: String? = nil
    var restingOpacity: Double = 1
    @Environment(\.quickSwitchHints) private var hints
    @ViewBuilder var header: () -> Header
    @ViewBuilder var content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.chromeTheme) private var chromeTheme
    /// The card's frame in the viewport, kept as it was while a drag lifts the card, so the header does not stick to the
    /// top of the viewport when the card is dragged past it.
    @State private var frame: CGRect = .zero
    @Environment(\.isLiftedByDrag) private var isLifted
    /// The card moved while lifted, so the header glides to its new place once the card lands.
    @State private var movedWhileLifted = false
    @State private var headerHeight: CGFloat = 0
    @State private var turn: Double = 0

    /// How far the header moves down to stay at the top of the viewport, never past the card's last row.
    private var stuck: CGFloat {
        guard isOpen, viewport != nil else { return 0 }
        return min(max(0, -frame.minY), max(0, frame.height - headerHeight - 8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header()
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
                .background {
                    if stuck > 0 {
                        ZStack {
                            Color.clear.chrome(theme: chromeTheme, material: .sidebar)
                            Color.primary.opacity(0.08)
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
                    .padding(.horizontal, 4)
                    .padding(.top, 3)
                    .padding(.bottom, 5)
                    // A row dragged up stops at the bottom of the header that sticks to the top, not under it.
                    .environment(\.dragTopInset, stuck > 0 ? max(0, frame.minY + stuck + headerHeight) : 0)
            }
        }
        .background {
            if isOpen {
                shape.fill(Color.primary.opacity(0.08)).shadow(color: .black.opacity(0.28), radius: 5, y: 2)
            }
        }
        .overlay(alignment: .leading) {
            if let mark {
                RowMarkSpine(mark: mark)
                    .frame(width: 3)
                    .padding(.vertical, 8)
                    .padding(.leading, 4)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            Group {
                if holdsSelection { BalatroBorder(angle: turn, shape: shape) } else { shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1) }
            }
            .allowsHitTesting(false)
        }
        .opacity(restingOpacity)
        .cardHints(hints)
        // A container, in which the header's sort priority applies.
        .accessibilityElement(children: .contain)
        .onChange(of: holdsSelection) { _, holds in
            guard holds, !reduceMotion else { return }
            turn = -150
            withAnimation(.timingCurve(0.18, 0.85, 0.25, 1, duration: 0.9)) { turn = 0 }
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

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 9, style: .continuous) }
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

    private static let colors: [Color] = ([0xfe5f55, 0xfda200, 0xffe066, 0x4bc292, 0x009dff, 0x8e5cff, 0xfe5f55] as [UInt32]).map { hex in
        let red = Double(hex >> 16 & 0xff), green = Double(hex >> 8 & 0xff), blue = Double(hex & 0xff)
        return Color(red: red / 255, green: green / 255, blue: blue / 255)
    }

    var body: some View {
        shape.strokeBorder(AngularGradient(colors: Self.colors, center: .center, angle: .degrees(angle)), lineWidth: 2)
            .saturation(1.15)
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
    let mark: RowMark?
    var isPinned = false
    /// A Locked Session's card shows a lock where a Pinned Topic's card shows its pin.
    var isLocked = false
    var hintTarget: QuickSwitchTarget? = nil
    @Environment(\.quickSwitchHints) private var hints
    /// Words for the accessibility value after the open state, such as "Dormant".
    var notes: [String] = []
    let summary: String
    /// The card shows an action in its bottom-right corner, so the summary stops before it.
    var reservesCorner = false
    @ViewBuilder var details: () -> Details
    @Environment(\.sidebarTypography) private var typography
    @Environment(\.wrapsCardTitles) private var wrapsTitle
    /// The title line's frame in the header, where a click tool such as Homerow clicks in place of the header's centre.
    @State private var titleLine: CGRect = .zero

    private static var space: String { "card-header" }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .titleLine, spacing: 5) {
                ZStack(alignment: .topLeading) {
                    Text(title)
                        .font(typography.font(for: .session))
                        .lineLimit(wrapsTitle ? nil : 1)
                        .fixedSize(horizontal: false, vertical: true)
                    // One line of the title's font: its centre is the centre of the title's first line.
                    Text(" ").font(typography.font(for: .session)).hidden()
                        .alignmentGuide(.titleLine) { $0[VerticalAlignment.center] }
                }
                if let hintTarget { CardHintSlot(target: hintTarget) }
                Spacer(minLength: 0)
                // The Hint badge takes the mark's place while it shows.
                let markOpacity: Double = hintTarget.map { hints[$0].isEmpty ? 1 : 0 } ?? 1
                if isPinned { PinMark().opacity(markOpacity) } else if isLocked { LockMark().opacity(markOpacity) }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { titleLine = $0 }
            HStack(spacing: 5) { details() }
            if !isOpen && !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.top, 1)
                    .padding(.trailing, reservesCorner ? CardCorner.width : 0)
            }
        }
        .padding(.leading, 13).padding(.trailing, 10).padding(.top, 7).padding(.bottom, isOpen ? 3 : 7)
        .coordinateSpace(.named(Self.space))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(title)
        .accessibilityHint(isOpen ? "" : summary)
        .accessibilityActivationPoint(CGPoint(x: titleLine.midX, y: titleLine.midY))
        .accessibilityValue(([isOpen ? "expanded" : "collapsed"] + notes + [mark?.rawValue].compactMap { $0 }).joined(separator: ", "))
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
    var body: some View {
        Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.secondary)
    }
}

/// The mark after a Locked Session's title.
struct LockMark: View {
    var body: some View {
        Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(.secondary)
    }
}

/// The rows of one Session in an open card.
struct CardBlock: Identifiable {
    /// The Session ID.
    let id: String
    let items: [TopicsModel.SessionChildren.Item]
}

/// The room between the rows of an open card, and between its Session blocks, where their divider is.
enum CardSpacing {
    static let row: CGFloat = 1
    static let block: CGFloat = 9
}

/// What a click and a long press on a card's Window row do: a click selects the Window, and a long press moves it,
/// with its Pane rows, before or after another Window of its Session.
struct WindowRowDrag {
    var isEnabled = true
    let select: (TmuxWindow) -> Void
    let move: (TmuxWindow, DropPlacement<String>) -> Void
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
/// A block whose rows are all cut loses its heading too. A long press on a Window row moves the Window within its
/// Session; with `blockDrag`, a long press on a heading moves its whole block.
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
    /// The drag of whole blocks, which the headings start; nil while the blocks keep their order.
    var blockDrag: LongPressDrag<String>? = nil
    let windows: WindowRowDrag
    @ViewBuilder var heading: (CardBlock) -> Heading
    @ViewBuilder var row: (TopicsModel.SessionChildren.Item) -> Row

    @State private var windowDrag = LongPressDrag<String>(spacing: CardSpacing.row)

    var body: some View {
        let total = blocks.reduce(0) { $0 + $1.items.count }
        let shown = CardRows.shownCount(blocks.flatMap(\.items), selectedWindowID: selectedWindowID, showsAll: showsAll)
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
                            Divider().padding(.horizontal, 6).offset(y: -5)
                                .opacity(movingBlock ? 0 : 1)
                                .animation(.easeOut(duration: 0.15), value: movingBlock)
                        }
                    }
                // A moving Window stays above the next block when it gives way past the end of its own.
                let holdsMovingWindow = windowDrag.dragged.map { id in block.items.contains { $0.id == id } } ?? false
                if let blockDrag {
                    view.longPressDragItem(block.id, drag: blockDrag, shown: blockIDs, cornerRadius: 7)
                        .zIndex(blockDrag.dragged == block.id ? 30 : holdsMovingWindow ? 20 : 0)
                } else {
                    view.zIndex(holdsMovingWindow ? 20 : 0)
                }
            }
        }
        if shown < total {
            Button(action: onShowAll) {
                Text("\(total - shown) more…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 28)
                    .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, reservesCorner ? CardCorner.width : 0)
            .accessibilityIdentifier(identifier + "-more")
        } else if reservesCorner {
            Color.clear.frame(height: 16)
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
                                row(item).longPressDrag(window.id, drag: windowDrag, isEnabled: windows.isEnabled && windowIDs.count > 1,
                                                        onTap: { windows.select(window) }) { windows.move(window, $0) }
                            } else {
                                row(item)
                            }
                        }
                    }
                    .longPressDragItem(window.id, drag: windowDrag, shown: windowIDs, cornerRadius: 6)
                } else {
                    ForEach(unit.items) { row($0) }
                }
            }
        }
    }
}

/// The one place a card shows its own action, such as Settle: pinned to the bottom-right corner at the same
/// offsets whether the card is open or closed, so it never moves when the card opens.
enum CardCorner {
    /// The room the action takes at the end of the summary line or the footer line.
    static let width: CGFloat = 44
}

extension View {
    func cardCorner<Action: View>(@ViewBuilder _ action: () -> Action) -> some View {
        overlay(alignment: .bottomTrailing) { action().padding(.trailing, 10).padding(.bottom, 6) }
    }
}
