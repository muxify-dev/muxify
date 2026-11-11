import AppKit
import MuxifyCore
import SwiftUI

/// What a Window row shows, as the Sessions list reads it from the models.
struct WindowRowContent: Equatable {
    let window: TmuxWindow
    /// The title, the Summary and the parts that the Config's Formats give.
    var formatted: SidebarFormats.WindowRowContent
    /// The row is the Location's Window.
    var isSelected = false
    var tabCount = 0
    var isGitViewOpen = false
    /// The Window left its Session's Worktree for the main working copy of its repository.
    var usesMainWorkingCopy = false
    /// `sidebar.window_tooltips`: when the row opens its hover label.
    var tooltips = Config.Sidebar.WindowTooltips.always
}

/// A Window row of the AppKit Sessions list (ADR 0074): `WindowRow` in SwiftUI. From the left: the room for a Hint,
/// the app icon or the Format's left part, the title with the lines under it, and at the end the bell, the Git View
/// icon and the Tab and Pane counts or the Format's right part. It lays its parts out as SwiftUI lays out the row's
/// `HStack`. The row of the Location's Window has a soft tint, and a row under the pointer a faint fill. Its hover
/// label shows the full title when the row cuts it off, and the Window's place and path, as `tooltips` says.
///
/// The row is no accessibility element. As in SwiftUI, each of its parts is one, with the row's identifier and value,
/// and the card lists them among its children. A click on the row goes to its Window, also on the first click while
/// Muxify is not the front app.
final class WindowRowView: SidebarRowView, CardRowView, NSViewToolTipOwner {
    let windowID: String
    /// The row's identifier, which each of its parts has.
    private let rowIdentifier: String
    private let logo = SidebarLogo()
    private let title = SidebarLabel()
    private let summary = SidebarLabel()
    private let mainWorkingCopy = SidebarLabel()
    private let bell = SidebarSymbol(CardHeaderMark.bell)
    private let gitView = GitViewIconView()
    private let tabSymbol = SidebarSymbol(WindowRowMetrics.tabSymbol)
    private let tabCount = SidebarLabel()
    private let paneCount = PaneCountView()
    /// The views of the Format's left and right parts.
    private var left: [NSView] = []
    private var right: [NSView] = []
    private var content: WindowRowContent?
    private var environment = SessionsListEnvironment()
    /// The layout of the last width.
    private var arranged: (width: CGFloat, layout: Layout)?
    /// The row's context menu, as the list reads it for the Window.
    var menuItems: () -> SidebarMenu? = { nil }

    /// Where the row's parts stand in a row of one width, from the left, and the help of each badge that has one.
    private struct Layout {
        var parts: [(view: NSView, frame: NSRect)] = []
        var help: [(frame: NSRect, text: String)] = []
        var height: CGFloat = 0
    }

    /// One child of the row's stack: its parts side by side, `spacing` apart, each with its middle on the child's.
    private struct Child {
        var parts: [(view: NSView, size: NSSize)] = []
        var spacing: CGFloat = 0
        /// The width of a child with no parts, which keeps room only.
        var room: CGFloat = 0
        var help: String?

        var width: CGFloat {
            parts.isEmpty ? room : parts.map(\.size.width).reduce(0, +) + spacing * CGFloat(parts.count - 1)
        }
        var height: CGFloat { parts.map(\.size.height).max() ?? 0 }
    }

    init(windowID: String, identifier: String) {
        self.windowID = windowID
        rowIdentifier = identifier
        super.init(frame: .zero)
        wantsLayer = true
        summary.ink = .secondary
        mainWorkingCopy.ink = .secondary
        mainWorkingCopy.text = WindowRowText.mainWorkingCopy
        // "Main working copy" wraps when the row is too narrow for it, as a SwiftUI text without a line limit.
        mainWorkingCopy.wraps = true
        bell.ink = .secondary
        tabSymbol.ink = .secondary
        tabSymbol.weight = .medium
        tabCount.ink = .secondary
        expose(logo, role: .image)
        expose(title, role: .staticText)
        expose(summary, role: .staticText)
        expose(mainWorkingCopy, role: .staticText, label: WindowRowText.mainWorkingCopy)
        expose(bell, role: .image, label: "Bell")
        expose(gitView, role: .unknown, help: WindowRowText.gitViewOpen, valued: false)
        expose(tabSymbol, role: .image, label: WindowRowText.tabSymbolLabel)
        expose(tabCount, role: .staticText)
        expose(paneCount, role: .unknown, valued: false)
        subviews = [fill]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Shows the content. The tint fades in or out when the Location comes to the row or leaves it, unless `fades` is
    /// false, as for the rows of a card that opens.
    func show(_ content: WindowRowContent, environment: SessionsListEnvironment, fades: Bool = true) {
        guard content != self.content || environment != self.environment else { return }
        let old = self.content
        let tints = old.map { $0.isSelected != content.isSelected } ?? false
        if old?.formatted.left != content.formatted.left || old?.formatted.right != content.formatted.right
            || old?.window.logoName != content.window.logoName || environment != self.environment {
            left = parts(content.formatted.left ?? [], left: true, logo: content.window.logoName)
            right = parts(content.formatted.right ?? [], left: false, logo: content.window.logoName)
        }
        self.content = content
        self.environment = environment
        let window = content.window
        let size = environment.fontSize
        let typography = environment.typography
        logo.name = window.logoName
        title.text = content.formatted.text.title
        title.font = typography.nsFont(for: .title)
        summary.text = content.formatted.text.summary
        summary.font = typography.nsFont(for: .location)
        mainWorkingCopy.font = typography.nsFont(for: .location)
        bell.pointSize = size(CardHeaderFont.mark)
        gitView.side = size(WindowRowMetrics.gitViewIconSize)
        tabSymbol.pointSize = size(WindowRowMetrics.symbolSize)
        tabCount.text = "\(content.tabCount)"
        tabCount.font = typography.nsFont(for: .badge)
        paneCount.show(count: window.paneCount, isZoomed: window.isZoomed, environment: environment)
        for label in [title, summary, mainWorkingCopy, tabCount] { label.scale = environment.displayScale }
        for symbol in [bell, tabSymbol] { symbol.scale = environment.displayScale }
        title.setAccessibilityLabel(content.formatted.text.title)
        summary.setAccessibilityLabel(content.formatted.text.summary)
        tabCount.setAccessibilityLabel(tabCount.text)
        for view in [tabSymbol, tabCount] { view.setAccessibilityHelp(WindowRowText.tabs(content.tabCount)) }
        // Each part has the row's value, except the badges that SwiftUI makes elements of their own.
        for view in [logo, title, summary, mainWorkingCopy, bell, tabSymbol, tabCount] + left + right {
            view.setAccessibilityValue(content.isSelected ? "selected" : "")
        }
        arranged = nil
        layOut()
        showsLocation = content.isSelected
        showFill(fades: fades && tints)
        // The label's title is the row's, in the font of the SwiftUI row's title.
        hoverLabel.anchor.anchor(title, title: Text(title.text).font(typography.font(for: .title)),
                                 fullWidth: SidebarTextLayout(title.text, font: title.font, scale: environment.displayScale).size.width)
        hoverLabel.show(RowHoverLabel.Request(detail: WindowRowText.hoverDetail(window), onlyWhenCutOff: content.tooltips == .truncated,
                                              enabled: content.tooltips != .off, fontSize: size))
    }

    func height(width: CGFloat) -> CGFloat { layout(width: width).height }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layOut()
    }

    private func layOut() {
        guard content != nil else { return }
        let layout = layout(width: bounds.width)
        let views = [fill] + layout.parts.map(\.view)
        if subviews != views { subviews = views }
        fill.frame = bounds
        for (view, frame) in layout.parts { view.frame = frame }
        removeAllToolTips()
        for help in layout.help { addToolTip(help.frame, owner: self, userData: nil) }
    }

    /// Lays the row out as SwiftUI lays out the `HStack` of `WindowRow`: the fixed parts take their room, the space
    /// between the title and the badges takes at least `WindowRowMetrics.endGap`, the title and the lines under it
    /// take what is left, and each child of the stack stands with its middle on the row's middle.
    private func layout(width: CGFloat) -> Layout {
        if let arranged, arranged.width == width { return arranged.layout }
        guard let content else { return Layout() }
        let scale = environment.displayScale
        let size = environment.fontSize
        let window = content.window

        var before: [Child] = []
        if environment.hints.windowSlotReserved { before.append(Child(room: size(WindowRowMetrics.hintRoom))) }
        if content.formatted.left == nil {
            before.append(Child(parts: [(logo, NSSize(width: WindowRowMetrics.iconSize, height: WindowRowMetrics.iconSize))]))
        } else if !left.isEmpty {
            before.append(Child(parts: left.map { ($0, Self.size(of: $0)) }))
        }
        var after: [Child] = []
        if window.hasBell { after.append(Child(parts: [(bell, bell.symbolSize)])) }
        if content.isGitViewOpen {
            after.append(Child(parts: [(gitView, NSSize(width: gitView.side, height: gitView.side))], help: WindowRowText.gitViewOpen))
        }
        if content.formatted.right == nil {
            if content.tabCount > 0 {
                after.append(Child(parts: [(tabSymbol, tabSymbol.symbolSize), (tabCount, tabCount.fit())],
                                   spacing: WindowRowMetrics.badgeSpacing, help: WindowRowText.tabs(content.tabCount)))
            }
            if window.paneCount > 1 {
                after.append(Child(parts: [(paneCount, paneCount.size)], help: window.isZoomed ? WindowRowText.zoomed : nil))
            }
        } else if !right.isEmpty {
            after.append(Child(parts: right.map { ($0, Self.size(of: $0)) }))
        }

        // The children of the stack are the ones before the title, the title's column, the space and the ones after.
        let gaps = WindowRowMetrics.spacing * CGFloat(before.count + after.count + 1)
        let room = max(0, width - WindowRowMetrics.leading - WindowRowMetrics.trailing)
        let fixed = (before + after).map(\.width).reduce(0, +)
        let columnRoom = max(0, room - gaps - fixed - WindowRowMetrics.endGap)
        var lines: [(view: NSView, size: NSSize)] = [(title, title.fit(width: columnRoom))]
        if !content.formatted.text.summary.isEmpty { lines.append((summary, summary.fit(width: columnRoom))) }
        if content.usesMainWorkingCopy { lines.append((mainWorkingCopy, mainWorkingCopy.fit(width: columnRoom))) }
        let columnWidth = lines.map(\.size.width).max() ?? 0
        let columnHeight = lines.map(\.size.height).reduce(0, +) + WindowRowMetrics.lineSpacing * CGFloat(lines.count - 1)
        let height = max(columnHeight, (before + after).map(\.height).max() ?? 0)
        let space = max(WindowRowMetrics.endGap, room - gaps - fixed - columnWidth)

        var layout = Layout()
        func middle(_ childHeight: CGFloat, in height: CGFloat, from top: CGFloat) -> CGFloat {
            (top + (height - childHeight) / 2).rounded(toPixelsOf: scale)
        }
        var x = WindowRowMetrics.leading
        func place(_ child: Child) {
            let top = middle(child.height, in: height, from: WindowRowMetrics.vertical)
            var partX = x
            for (view, size) in child.parts {
                layout.parts.append((view, NSRect(x: partX, y: middle(size.height, in: child.height, from: top), width: size.width, height: size.height)))
                partX += size.width + child.spacing
            }
            if let help = child.help { layout.help.append((NSRect(x: x, y: top, width: child.width, height: child.height), help)) }
            x += child.width + WindowRowMetrics.spacing
        }
        before.forEach(place)
        var lineY = middle(columnHeight, in: height, from: WindowRowMetrics.vertical)
        for (view, size) in lines {
            layout.parts.append((view, NSRect(origin: NSPoint(x: x, y: lineY), size: size)))
            lineY += size.height + WindowRowMetrics.lineSpacing
        }
        x += columnWidth + WindowRowMetrics.spacing + space + WindowRowMetrics.spacing
        after.forEach(place)
        layout.height = height + 2 * WindowRowMetrics.vertical
        arranged = (width, layout)
        return layout
    }

    /// The room a part of a Format takes.
    private static func size(of part: NSView) -> NSSize {
        switch part {
        case let label as SidebarLabel: return label.fit()
        case let symbol as SidebarSymbol: return symbol.symbolSize
        default: return NSSize(width: WindowRowMetrics.iconSize, height: WindowRowMetrics.iconSize)
        }
    }

    /// The views of a Format's parts: a text in the title's font on the left and in the badges' on the right, the
    /// current app icon, or a system symbol, which is named by its name.
    private func parts(_ parts: [SidebarPart], left: Bool, logo name: String) -> [NSView] {
        parts.map { part -> NSView in
            switch part {
            case .text(let text):
                let label = SidebarLabel()
                label.text = text
                label.font = environment.typography.nsFont(for: left ? .title : .badge)
                label.ink = left ? .primary : .secondary
                label.scale = environment.displayScale
                expose(label, role: .staticText, label: text)
                return label
            case .currentAppIcon:
                let logo = SidebarLogo()
                logo.name = name
                expose(logo, role: .image)
                return logo
            case .symbol(let symbolName):
                let symbol = SidebarSymbol(symbolName)
                symbol.pointSize = environment.fontSize(WindowRowMetrics.symbolSize)
                symbol.weight = .medium
                symbol.ink = left ? .primary : .secondary
                symbol.scale = environment.displayScale
                expose(symbol, role: .image, label: symbolName)
                return symbol
            }
        }
    }

    // MARK: The menu

    /// A right-click on the row shows the row's menu, in place of the card's. As in SwiftUI, the menu gives the row's
    /// parts no named accessibility actions.
    override func menu(for event: NSEvent) -> NSMenu? { menuItems()?.contextMenu() }

    // MARK: The help

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        layout(width: bounds.width).help.first { $0.frame.contains(point) }?.text ?? ""
    }

    // MARK: Accessibility

    /// The parts that show, from the left, each a row of its own with the row's identifier.
    var accessibilityParts: [NSView] { layout(width: bounds.width).parts.map(\.view) }

    private func expose(_ view: NSView, role: NSAccessibility.Role, label: String? = nil, help: String? = nil, valued: Bool = true) {
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(role)
        view.setAccessibilityIdentifier(rowIdentifier)
        view.setAccessibilityLabel(label)
        view.setAccessibilityHelp(help)
        view.setAccessibilityValue(valued ? (content?.isSelected == true ? "selected" : "") : nil)
    }
}

/// The fill of a row: clear, the faint fill of a row under the pointer, or the soft tint of the Location's row, in the
/// row's rounded shape. The shape is a layer under the view's own: the driver's `snapshot` draws the corners of a
/// view's own layer square.
final class RowFillView: NSView {
    enum Fill { case clear, hover, tint }

    static let fadeKey = "tint"
    private(set) var fill = Fill.clear
    private let shape = CALayer()

    init() {
        super.init(frame: .zero)
        layer = CALayer()
        wantsLayer = true
        shape.cornerRadius = WindowRowMetrics.cornerRadius
        shape.cornerCurve = .continuous
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

    /// Shows the fill. With `fades`, it fades from where it shows now, with ease-out over `SelectedRow.fade`.
    func show(_ fill: Fill, fades: Bool) {
        guard fill != self.fill else { return }
        self.fill = fill
        let shown = (shape.presentation() ?? shape).backgroundColor
        color()
        guard fades else { return shape.removeAnimation(forKey: Self.fadeKey) }
        let fade = CABasicAnimation(keyPath: "backgroundColor")
        fade.fromValue = shown
        fade.duration = SelectedRow.fade
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        shape.add(fade, forKey: Self.fadeKey)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        color()
    }

    /// A layer keeps the colour it got, so it gets the colour again for each appearance.
    private func color() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color: NSColor? = switch fill {
            case .clear: nil
            case .hover: NSColor.labelColor.faded(SelectedRow.hoverOpacity)
            case .tint: NSColor.controlAccentColor.faded(SelectedRow.tintOpacity)
            }
            LayerGlide.withoutActions { shape.backgroundColor = color?.cgColor }
        }
    }

    #if DEBUG
    /// The colour the fill has now, and the fade of the tint that runs, for the tests.
    var shownColor: CGColor? { shape.backgroundColor }
    var fade: CAAnimation? { shape.animation(forKey: Self.fadeKey) }
    #endif
}

/// The Git View icon of a Window whose Git View is open, as `GitViewIcon` strokes it, in the secondary text colour.
/// Its accessibility frame is the frame of its stroke, as SwiftUI gives a shape's.
final class GitViewIconView: NSView {
    var side: CGFloat = WindowRowMetrics.gitViewIconSize {
        didSet {
            if side != oldValue { needsDisplay = true }
        }
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private var square: CGRect { CGRect(x: 0, y: 0, width: side, height: side) }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.addPath(GitViewIconShape.path(in: square))
        context.setLineWidth(GitViewIconShape.lineWidth(side: side))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setStrokeColor(NSColor.secondaryLabelColor.cgColor)
        context.strokePath()
    }

    override func accessibilityFrame() -> NSRect {
        guard let window else { return .zero }
        let stroke = GitViewIconShape.path(in: square).boundingBoxOfPath.insetBy(dx: -GitViewIconShape.lineWidth(side: side) / 2,
                                                                                  dy: -GitViewIconShape.lineWidth(side: side) / 2)
        return window.convertToScreen(convert(stroke, to: nil))
    }
}

/// The Pane count of a Window with more than one Pane: its symbol and its count. While a Pane is Zoomed, it glows in
/// the accent colour on a soft capsule. To accessibility it is one row, which names the count and the Zoom.
final class PaneCountView: NSView {
    private let symbol = SidebarSymbol(WindowRowMetrics.paneSymbol)
    private let count = SidebarLabel()
    private var isZoomed = false

    init() {
        super.init(frame: .zero)
        symbol.weight = .medium
        subviews = [symbol, count]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(count: Int, isZoomed: Bool, environment: SessionsListEnvironment) {
        self.isZoomed = isZoomed
        symbol.pointSize = environment.fontSize(WindowRowMetrics.symbolSize)
        symbol.scale = environment.displayScale
        self.count.text = "\(count)"
        self.count.font = environment.typography.nsFont(for: .badge)
        self.count.scale = environment.displayScale
        let ink: SidebarInk = isZoomed ? .accent : .secondary
        symbol.ink = ink
        self.count.ink = ink
        setAccessibilityLabel(WindowRowText.panes(count, isZoomed: isZoomed))
        needsDisplay = true
        layOut()
    }

    /// The symbol and the count side by side, with the capsule's room on each side.
    var size: NSSize {
        let symbolSize = symbol.symbolSize, countSize = count.fit()
        return NSSize(width: 2 * WindowRowMetrics.paneCountPadding + symbolSize.width + WindowRowMetrics.badgeSpacing + countSize.width,
                      height: max(symbolSize.height, countSize.height))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layOut()
    }

    private func layOut() {
        let size = size, scale = count.scale
        let symbolSize = symbol.symbolSize, countSize = count.fit()
        symbol.frame = NSRect(x: WindowRowMetrics.paneCountPadding, y: ((size.height - symbolSize.height) / 2).rounded(toPixelsOf: scale),
                              width: symbolSize.width, height: symbolSize.height)
        count.frame = NSRect(x: symbol.frame.maxX + WindowRowMetrics.badgeSpacing, y: ((size.height - countSize.height) / 2).rounded(toPixelsOf: scale),
                             width: countSize.width, height: countSize.height)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isZoomed else { return }
        NSColor.controlAccentColor.faded(WindowRowMetrics.zoomFillOpacity).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }

    /// The help shows over the badge, and SwiftUI gives the badge's row none.
    override func accessibilityHelp() -> String? { nil }

    /// SwiftUI's frame of the badge: with the capsule of a Zoomed Pane, the capsule; else the symbol's glyph and the
    /// count, because a capsule that does not show takes no room in it.
    override func accessibilityFrame() -> NSRect {
        guard let window else { return .zero }
        let shown = isZoomed ? bounds : symbol.convert(symbol.glyphFrame, to: self).union(count.frame)
        return window.convertToScreen(convert(shown, to: nil))
    }

    override func accessibilityChildren() -> [Any]? { [] }
}
