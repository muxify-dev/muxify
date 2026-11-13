import AppKit
import MuxifyCore

extension TopicsModel.PaneRow {
    /// With no Window row above it, the active Pane row shows where the user is, for both versions of the row (ADR 0074).
    func showsLocation(selectedWindowID: String?) -> Bool {
        !isUnderWindowRow && pane.isActive && window.id == selectedWindowID
    }

    /// The value of the row's accessibility row, for both versions: `active` for the Window's active Pane, then the
    /// mark's name.
    func accessibilityValue(mark: AgentMark?) -> String {
        [pane.isActive ? "active" : nil, mark?.rawValue].compactMap { $0 }.joined(separator: ", ")
    }

    /// The detail line of the row's hover label, for both versions: the Pane's path, or its label when it has none.
    var hoverDetail: String { pane.path.isEmpty ? pane.label : Paths.tildify(pane.path) }
}

/// What a Pane row shows, as the Sessions list reads it from the models.
struct PaneRowContent: Equatable {
    let paneID: String
    /// The title and the Summary that the Config's Format gives.
    var text: SidebarFormats.Text
    /// The Window's active Pane.
    var isActive = false
    /// The row stands under its Window row. False when it stands in for its Session's only Window row.
    var isUnderWindowRow = true
    /// The row stands in for the Location's Window row: `TopicsModel.PaneRow.showsLocation`.
    var showsLocation = false
    var mark: AgentMark?
    /// The value of the accessibility row: `TopicsModel.PaneRow.accessibilityValue`.
    var accessibilityValue = ""
    /// The detail line of the hover label: `TopicsModel.PaneRow.hoverDetail`.
    var hoverDetail = ""
    /// The Pane's Window, under whose row a row under its Window row stands, and moves with it in a drag.
    var windowID = ""
}

/// A Pane row of the AppKit Sessions list (ADR 0074): `PaneRow` in SwiftUI. From the left: the place of the Agent mark,
/// which stays empty without one, the split icon, filled for the active Pane, and the title on one line with the
/// Summary under it. A row under its Window row is indented. A row that stands in for the Location's Window row has the
/// tint, with its icon in the accent colour; the others are in the softer text colour. Its hover label shows the full
/// title when the row cuts it off, and the Pane's path.
///
/// To accessibility it is one button, `pane-<id>`, which hides its parts. A press goes to its Pane, also on the first
/// click while Muxify is not the front app.
final class PaneRowView: SidebarRowView, CardRowView {
    let paneID: String
    private let mark = SidebarAgentMark()
    /// The split icon of the active Pane and of another, of which the row shows one.
    private let activeIcon = SidebarSymbol(PaneRowMetrics.activeSymbol)
    private let icon = SidebarSymbol(PaneRowMetrics.symbol)
    private let title = SidebarLabel()
    private let summary = SidebarLabel()
    private var content: PaneRowContent?
    private var environment = SidebarListEnvironment()
    /// The layout of the last width.
    private var arranged: (width: CGFloat, layout: Layout)?

    private struct Layout {
        var mark = NSRect.zero
        var icon = NSRect.zero
        var title = NSRect.zero
        var summary: NSRect?
        var height: CGFloat = 0
    }

    init(paneID: String) {
        self.paneID = paneID
        super.init(frame: .zero)
        wantsLayer = true
        summary.ink = .secondary
        subviews = [fill, mark, activeIcon, icon, title, summary]
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier("pane-" + paneID)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Shows the content. The tint fades in or out when the Location comes to the row or leaves it, unless `fades` is
    /// false, as for the rows of a card that opens.
    func show(_ content: PaneRowContent, environment: SidebarListEnvironment, fades: Bool = true) {
        guard content != self.content || environment != self.environment else { return }
        let tints = self.content.map { $0.showsLocation != content.showsLocation } ?? false
        self.content = content
        self.environment = environment
        let size = environment.fontSize
        mark.show(content.mark, colors: environment.agentColors, moves: environment.pulses && !environment.reduceMotion,
                  fontSize: size, scale: environment.displayScale)
        for symbol in [activeIcon, icon] {
            symbol.pointSize = size(PaneRowMetrics.iconSize)
            symbol.ink = content.showsLocation ? .accent : .secondary
            symbol.scale = environment.displayScale
        }
        activeIcon.isHidden = !content.isActive
        icon.isHidden = content.isActive
        title.text = content.text.title
        title.font = .systemFont(ofSize: size(PaneRowMetrics.titleSize))
        title.ink = content.showsLocation ? .primary : .secondary
        summary.text = content.text.summary
        summary.font = .systemFont(ofSize: size(PaneRowMetrics.summarySize))
        summary.isHidden = content.text.summary.isEmpty
        for label in [title, summary] { label.scale = environment.displayScale }
        arranged = nil
        layOut()
        showsLocation = content.showsLocation
        showFill(fades: fades && tints)
        // The label's title is the row's, in the row's font.
        hoverLabel.anchor.anchor(title, title: title.text, font: title.font,
                                 fullWidth: SidebarTextLayout(title.text, font: title.font, scale: environment.displayScale).size.width)
        hoverLabel.show(RowHoverLabel.Request(detail: content.hoverDetail, fontSize: size))
    }

    func height(width: CGFloat) -> CGFloat { layout(width: width).height }

    var accessibilityParts: [NSView] { [self] }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layOut()
    }

    private func layOut() {
        guard content != nil else { return }
        let layout = layout(width: bounds.width)
        fill.frame = bounds
        mark.frame = layout.mark
        activeIcon.frame = layout.icon
        icon.frame = layout.icon
        title.frame = layout.title
        if let frame = layout.summary { summary.frame = frame }
    }

    /// Lays the row out as SwiftUI lays out the `HStack` of `PaneRow`: the mark's place and the icon's room take their
    /// width, the space at the end takes at least `PaneRowMetrics.endGap`, the title and the Summary take what is left,
    /// and each child of the stack stands with its middle on the row's middle.
    private func layout(width: CGFloat) -> Layout {
        if let arranged, arranged.width == width { return arranged.layout }
        guard let content else { return Layout() }
        let scale = environment.displayScale
        let size = environment.fontSize
        let place = size(PaneRowMetrics.markPlace)
        let iconRoom = size(PaneRowMetrics.iconRoom)
        let iconSize = (content.isActive ? activeIcon : icon).symbolSize
        let leading = PaneRowMetrics.leading(isUnderWindowRow: content.isUnderWindowRow)
        // The children of the stack are the mark's place, the icon, the title's column and the space.
        let room = max(0, width - leading - PaneRowMetrics.trailing)
        let columnRoom = max(0, room - place - iconRoom - 3 * PaneRowMetrics.spacing - PaneRowMetrics.endGap)
        let titleSize = title.fit(width: columnRoom)
        let summarySize = content.text.summary.isEmpty ? nil : summary.fit(width: columnRoom)
        let columnHeight = titleSize.height + (summarySize.map { PaneRowMetrics.lineSpacing + $0.height } ?? 0)
        let height = max(place, iconSize.height, columnHeight)

        func middle(_ childHeight: CGFloat) -> CGFloat {
            (PaneRowMetrics.vertical + (height - childHeight) / 2).rounded(toPixelsOf: scale)
        }
        var layout = Layout()
        layout.mark = NSRect(x: leading, y: middle(place), width: place, height: place)
        let iconX = leading + place + PaneRowMetrics.spacing
        layout.icon = NSRect(x: (iconX + (iconRoom - iconSize.width) / 2).rounded(toPixelsOf: scale), y: middle(iconSize.height),
                             width: iconSize.width, height: iconSize.height)
        let columnX = iconX + iconRoom + PaneRowMetrics.spacing
        let columnY = middle(columnHeight)
        layout.title = NSRect(origin: NSPoint(x: columnX, y: columnY), size: titleSize)
        layout.summary = summarySize.map { NSRect(origin: NSPoint(x: columnX, y: columnY + titleSize.height + PaneRowMetrics.lineSpacing), size: $0) }
        layout.height = height + 2 * PaneRowMetrics.vertical
        arranged = (width, layout)
        return layout
    }

    // MARK: Accessibility

    /// The title and the Summary, as SwiftUI names a button by the texts of its label.
    override func accessibilityLabel() -> String? {
        guard let content else { return nil }
        return [content.text.title, content.text.summary].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    override func accessibilityValue() -> Any? { content?.accessibilityValue ?? "" }

    override func accessibilityChildren() -> [Any]? { [] }

    override func accessibilityActivationPoint() -> NSPoint { accessibilityFrame().centre }
}

/// The row that ends a long open card in the AppKit lists (ADR 0074): "N more…", where N is the number of rows the card
/// holds back. A press shows all rows of the card. To accessibility it is a button with the identifier of the
/// card's header and `-more`.
final class MoreRowView: SidebarPressView, CardRowView {
    private let label = SidebarLabel()
    private var environment = SidebarListEnvironment()

    init(identifier: String) {
        super.init(frame: .zero)
        label.ink = .secondary
        subviews = [label]
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier(identifier + "-more")
        setAccessibilityValue("")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Shows the number of rows the card holds back. `value` is the row's accessibility value: in the Topics list, the
    /// strongest Agent mark of the rows held back.
    func show(count: Int, value: String = "", environment: SidebarListEnvironment) {
        self.environment = environment
        setAccessibilityValue(value)
        label.text = MoreRowMetrics.text(count)
        label.font = .systemFont(ofSize: environment.fontSize(MoreRowMetrics.fontSize))
        label.scale = environment.displayScale
        setAccessibilityLabel(label.text)
        layOut()
    }

    /// At least `MoreRowMetrics.minHeight`, and the text's line.
    func height(width: CGFloat) -> CGFloat {
        max(environment.fontSize(MoreRowMetrics.minHeight), label.fit(width: room(width)).height)
    }

    var accessibilityParts: [NSView] { [self] }

    private func room(_ width: CGFloat) -> CGFloat { max(0, width - MoreRowMetrics.leading) }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layOut()
    }

    /// The text after its room, with its middle on the row's middle.
    private func layOut() {
        let size = label.fit(width: room(bounds.width))
        label.frame = NSRect(x: MoreRowMetrics.leading, y: ((bounds.height - size.height) / 2).rounded(toPixelsOf: environment.displayScale),
                             width: size.width, height: size.height)
    }

    override func accessibilityChildren() -> [Any]? { [] }

    override func accessibilityActivationPoint() -> NSPoint { accessibilityFrame().centre }
}
