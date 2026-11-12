import AppKit
import MuxifyCore

/// A pill over an edge of the AppKit Topics list (docs/adr/0075-muxify-leaves-swiftui-entirely-one-area-at-a-time.md),
/// "N more above" or "N more below", as `EdgePill` draws it in SwiftUI. The view is the band across the list that the
/// pill lies in, with the room for its shadow, and it clips the pill: near its edge the pill moves with the cards,
/// `EdgePillMetrics.offset`, so it slides in from the band's edge and out again. While it counts no card, the band
/// hides and has no accessibility row.
///
/// To accessibility the pill is a button named "N more above" or "N more below", with the identifier
/// `topics-more-above` or `topics-more-below`, as large as its band and moved with its slide, as SwiftUI gives it. A
/// press on it, also a first click, calls `onPress`. A scroll of the wheel over it scrolls `scrollView`, the list under
/// it.
final class EdgePillView: NSView {
    var onPress: () -> Void {
        get { button.onPress }
        set { button.onPress = newValue }
    }
    weak var scrollView: NSScrollView?
    private let button: EdgePillButtonView

    init(edge: EdgePillMetrics.Edge) {
        button = EdgePillButtonView(edge: edge)
        super.init(frame: .zero)
        layer = CALayer()
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(button)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// Shows the pill counting `count` cards, come `slide` points in from its edge, or hides it for no card.
    func show(count: Int, slide: CGFloat, environment: SidebarListEnvironment) {
        isHidden = count == 0
        guard count > 0 else { return }
        button.show(count: count, environment: environment)
        button.frame = NSRect(x: 0, y: EdgePillMetrics.offset(button.edge, slide: slide, height: bounds.height),
                              width: bounds.width, height: bounds.height)
    }

    override func accessibilityChildren() -> [Any]? { isHidden ? [] : [button] }

    override func scrollWheel(with event: NSEvent) {
        guard let scrollView else { return super.scrollWheel(with: event) }
        scrollView.scrollWheel(with: event)
    }
}

/// The pill itself: the arrow and the count on a capsule of the Sidebar's chrome with a faint fill and border of the
/// text colour, over a shadow, in the middle of the band.
private final class EdgePillButtonView: SidebarPressView {
    let edge: EdgePillMetrics.Edge
    private let chrome = SidebarChromeView()
    private let shape = EdgePillShapeView()
    private let arrow: SidebarSymbol
    private let word = SidebarLabel()
    private var environment = SidebarListEnvironment()

    init(edge: EdgePillMetrics.Edge) {
        self.edge = edge
        arrow = SidebarSymbol(EdgePillMetrics.symbol(edge))
        super.init(frame: .zero)
        arrow.weight = .bold
        word.ink = .secondary
        // Cut to the capsule that the shape draws: a circular capsule, as `CGPath(roundedRect:)` makes one.
        chrome.layer?.masksToBounds = true
        subviews = [chrome, shape, arrow, word]
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier(EdgePillMetrics.identifier(edge))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(count: Int, environment: SidebarListEnvironment) {
        self.environment = environment
        word.text = EdgePillMetrics.text(count: count)
        word.font = .systemFont(ofSize: environment.fontSize(EdgePillMetrics.fontSize), weight: .semibold)
        word.scale = environment.displayScale
        arrow.pointSize = environment.fontSize(EdgePillMetrics.symbolFontSize)
        arrow.scale = environment.displayScale
        chrome.theme = environment.chromeTheme
        shape.scale = environment.displayScale
        setAccessibilityLabel(EdgePillMetrics.label(edge, count: count))
        layOut()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layOut()
    }

    override func accessibilityFrame() -> NSRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(bounds, to: nil))
    }

    override func accessibilityActivationPoint() -> NSPoint { accessibilityFrame().centre }

    /// Lays the pill out as SwiftUI lays out `EdgePill`: the arrow and the count one after the other in an `HStack`,
    /// each with its middle on the capsule's middle, the capsule as wide as they are with its padding and as high as
    /// the band less its margins, in the middle of the band. As in SwiftUI, the capsule's edges are where the middle
    /// puts them, and the arrow and the count stand on whole pixels.
    private func layOut() {
        let scale = environment.displayScale
        let arrowSize = arrow.symbolSize, wordSize = word.fit()
        let height = max(0, bounds.height - 2 * EdgePillMetrics.margin)
        let width = 2 * EdgePillMetrics.horizontalPadding + arrowSize.width + EdgePillMetrics.spacing + wordSize.width
        let capsule = NSRect(x: (bounds.width - width) / 2, y: EdgePillMetrics.margin, width: width, height: height)
        func middle(_ room: CGFloat) -> CGFloat { (capsule.minY + (capsule.height - room) / 2).rounded(toPixelsOf: scale) }
        let arrowX = capsule.minX + EdgePillMetrics.horizontalPadding
        arrow.frame = NSRect(x: arrowX.rounded(toPixelsOf: scale), y: middle(arrowSize.height), width: arrowSize.width,
                             height: arrowSize.height)
        word.frame = NSRect(x: (arrowX + arrowSize.width + EdgePillMetrics.spacing).rounded(toPixelsOf: scale),
                            y: middle(wordSize.height), width: wordSize.width, height: wordSize.height)
        chrome.frame = capsule
        LayerGlide.withoutActions { chrome.layer?.cornerRadius = capsule.height / 2 }
        shape.frame = bounds
        shape.capsule = capsule
    }
}

/// The capsule of the pill over its chrome: its shadow outside it, the faint fill of the text colour and the border
/// inside its edge, as SwiftUI draws `EdgePill`. The view draws them itself into its layer, so that the verify
/// driver's `snapshot`, which draws the layers with `CALayer.render(in:)`, shows the shadow too: it draws no shadow of
/// a layer without content. SwiftUI's shadow of the composited pill shows outside the capsule only, under the chrome.
private final class EdgePillShapeView: NSView {
    /// The capsule, in the view's coordinates.
    var capsule = NSRect.zero {
        didSet {
            if capsule != oldValue { needsDisplay = true }
        }
    }
    /// The pixels in a point on the display, in which the shadow's blur and drop are given.
    var scale: CGFloat = 2 {
        didSet {
            if scale != oldValue { needsDisplay = true }
        }
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, capsule.width > 0, capsule.height > 0 else { return }
        let radius = capsule.height / 2
        let path = CGPath(roundedRect: capsule, cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.saveGState()
        context.addRect(bounds)
        context.addPath(path)
        context.clip(using: .evenOdd)
        // A shadow's drop and blur are in the device's pixels, and its drop counts upward. A blur of the radius in
        // pixels falls off over as many points below the capsule as SwiftUI's shadow of that radius.
        context.setShadow(offset: CGSize(width: 0, height: -EdgePillMetrics.shadowDrop * scale),
                          blur: EdgePillMetrics.shadowRadius * scale,
                          color: NSColor.black.withAlphaComponent(EdgePillMetrics.shadowOpacity).cgColor)
        context.addPath(path)
        context.fillPath()
        context.restoreGState()
        context.setFillColor(NSColor.labelColor.faded(EdgePillMetrics.fillOpacity).cgColor)
        context.addPath(path)
        context.fillPath()
        let width = EdgePillMetrics.borderWidth
        let border = capsule.insetBy(dx: width / 2, dy: width / 2)
        context.setStrokeColor(NSColor.labelColor.faded(EdgePillMetrics.borderOpacity).cgColor)
        context.setLineWidth(width)
        context.addPath(CGPath(roundedRect: border, cornerWidth: radius - width / 2, cornerHeight: radius - width / 2, transform: nil))
        context.strokePath()
    }
}
