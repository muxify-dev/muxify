import AppKit
import MuxifyCore

/// What the row of a Window that a Settled Topic remembers shows.
struct RememberedRowContent: Equatable {
    let windowID: String
    let name: String
    /// The Window's folder, with `~` for the home folder, which the row's hover label shows.
    let folder: String
    /// `sidebar.window_tooltips`: when the row opens its hover label.
    var tooltips = Config.Sidebar.WindowTooltips.always
}

/// The row of a Window that an open Settled card remembers, in the AppKit Topics list
/// (docs/adr/0075-muxify-leaves-swiftui-entirely-one-area-at-a-time.md), as `RememberedSessions` draws it in SwiftUI: a
/// clock in its box, then the Window's name on one line, cut with "…" when it does not fit, both in the secondary text
/// colour, with the room of `RememberedRowMetrics` around them. A press on it does nothing, and it has no fill. After the
/// pointer rests on it, its hover label opens over it with the Window's folder, as `tooltips` says.
///
/// To accessibility it is one static text, `remembered-window-<id>`, with the name as its value and as large as the
/// clock and the name together, as SwiftUI combines the row's children.
final class RememberedRowView: SidebarRowView {
    private let symbol = SidebarSymbol(RememberedRowMetrics.symbol)
    private let title = SidebarLabel()
    private var content: RememberedRowContent?
    private var environment = SidebarListEnvironment()

    init(windowID: String) {
        super.init(frame: .zero)
        title.ink = .secondary
        subviews = [symbol, title]
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityIdentifier(RememberedRowMetrics.identifier(windowID))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ content: RememberedRowContent, environment: SidebarListEnvironment) {
        guard content != self.content || environment != self.environment else { return }
        self.content = content
        self.environment = environment
        let size = environment.fontSize
        symbol.pointSize = size(RememberedRowMetrics.symbolFontSize)
        symbol.scale = environment.displayScale
        title.text = content.name
        title.font = .systemFont(ofSize: size(RememberedRowMetrics.fontSize))
        title.scale = environment.displayScale
        setAccessibilityValue(content.name)
        layOut()
        // The label's title is the row's, in the row's font.
        hoverLabel.anchor.anchor(title, title: content.name, font: title.font,
                                 fullWidth: SidebarTextLayout(content.name, font: title.font, scale: environment.displayScale).size.width)
        hoverLabel.show(RowHoverLabel.Request(detail: content.folder, onlyWhenCutOff: content.tooltips == .truncated,
                                              enabled: content.tooltips != .off, fontSize: size))
    }

    /// The clock or the name, whichever is higher, and the room above and below it.
    var height: CGFloat { 2 * RememberedRowMetrics.vertical + contentHeight }

    private var contentHeight: CGFloat { max(symbol.symbolSize.height, title.lineHeight) }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layOut()
    }

    /// Lays the row out as SwiftUI lays out its `HStack`: the clock in the middle of its box, then the name in the room
    /// that the space after it leaves, each with its middle on the row's middle.
    private func layOut() {
        let scale = environment.displayScale
        let box = environment.fontSize(RememberedRowMetrics.designSymbolWidth)
        let middle = RememberedRowMetrics.vertical + contentHeight / 2
        let symbolSize = symbol.symbolSize
        symbol.frame = NSRect(x: (RememberedRowMetrics.leading + (box - symbolSize.width) / 2).rounded(toPixelsOf: scale),
                              y: (middle - symbolSize.height / 2).rounded(toPixelsOf: scale), width: symbolSize.width, height: symbolSize.height)
        let left = RememberedRowMetrics.leading + box + RememberedRowMetrics.spacing
        let room = bounds.width - left - RememberedRowMetrics.spacing - RememberedRowMetrics.endGap - RememberedRowMetrics.trailing
        let titleSize = title.fit(width: max(0, room))
        title.frame = NSRect(x: left.rounded(toPixelsOf: scale), y: (middle - titleSize.height / 2).rounded(toPixelsOf: scale),
                             width: titleSize.width, height: titleSize.height)
    }

    // MARK: Accessibility

    /// The clock and the name together.
    override func accessibilityFrame() -> NSRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(symbol.frame.union(title.frame), to: nil))
    }

    override func accessibilityLabel() -> String? { nil }

    override func accessibilityChildren() -> [Any]? { [] }

    override func accessibilityActivationPoint() -> NSPoint { accessibilityFrame().centre }
}
