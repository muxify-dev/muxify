import AppKit
import MuxifyCore

/// An Open Place of the AppKit Topics list (docs/adr/0075-muxify-leaves-swiftui-entirely-one-area-at-a-time.md): an In
/// Play place that no card fills, as `OpenPlaceCard` draws it in SwiftUI. A plus in a circle and its word stand in the
/// secondary text colour in a dashed border, and after the word the place keeps the room of its Hint. A press, also a
/// first click, asks which Guest Topic or Benched Topic takes the place.
///
/// To accessibility it is a group, as SwiftUI gives it, whose row is a button named by the place's number, "Open
/// Place N", with the identifier `open-place-N`.
final class OpenPlaceView: NSView {
    /// The ID of the Open Place's record, which keeps its view while its number changes.
    let recordID: String
    /// A press on the Open Place.
    var onPress: () -> Void {
        get { button.onPress }
        set { button.onPress = newValue }
    }
    private let button = OpenPlaceButtonView()

    init(recordID: String) {
        self.recordID = recordID
        super.init(frame: .zero)
        addSubview(button)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// Shows the Open Place at its number, counted from 1, with the room of its Hint when the Hints show one.
    func show(place: Int, environment: SidebarListEnvironment) {
        button.show(place: place, environment: environment)
    }

    var height: CGFloat { button.height }

    /// The room the Open Place keeps after its word for its Hint, in its own coordinates; nil while the Hints show none.
    /// The Hint itself comes with a later task of the set remove-swiftui.
    var hintPlace: NSRect? { button.hintPlace }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        button.frame = bounds
    }

    override func accessibilityChildren() -> [Any]? { [button] }
}

/// The button of an Open Place: its plus, its word and its border.
private final class OpenPlaceButtonView: SidebarPressView {
    private let symbol = SidebarSymbol(OpenPlaceMetrics.symbol)
    private let word = SidebarLabel()
    private let border = OpenPlaceBorderView()
    private var hint: CardHint?
    private var environment = SidebarListEnvironment()
    private(set) var hintPlace: NSRect?

    override init(frame: NSRect) {
        super.init(frame: frame)
        symbol.weight = .semibold
        word.text = OpenPlaceMetrics.word
        word.ink = .secondary
        subviews = [symbol, word, border]
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(place: Int, environment: SidebarListEnvironment) {
        self.environment = environment
        hint = CardHint(.openPlace(place), in: environment.hints)
        symbol.pointSize = environment.fontSize(OpenPlaceMetrics.symbolFontSize)
        symbol.scale = environment.displayScale
        word.font = .systemFont(ofSize: environment.fontSize(OpenPlaceMetrics.fontSize), weight: .medium)
        word.scale = environment.displayScale
        setAccessibilityLabel(OpenPlaceMetrics.label(place: place))
        setAccessibilityIdentifier("open-place-\(place)")
        layOut()
    }

    var height: CGFloat { environment.fontSize(OpenPlaceMetrics.designHeight) }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layOut()
    }

    override func accessibilityActivationPoint() -> NSPoint { accessibilityFrame().centre }

    /// Lays the place out as SwiftUI lays out the `HStack` of `OpenPlaceCard`: the plus, the word and the Hint's room
    /// one after the other from the leading padding, each with its middle on the place's middle.
    private func layOut() {
        let scale = environment.displayScale
        func middle(_ height: CGFloat) -> CGFloat { ((bounds.height - height) / 2).rounded(toPixelsOf: scale) }
        let symbolSize = symbol.symbolSize, wordSize = word.fit()
        var x = OpenPlaceMetrics.horizontalPadding
        symbol.frame = NSRect(x: x, y: middle(symbolSize.height), width: symbolSize.width, height: symbolSize.height)
        x += symbolSize.width + OpenPlaceMetrics.spacing
        word.frame = NSRect(x: x.rounded(toPixelsOf: scale), y: middle(wordSize.height), width: wordSize.width, height: wordSize.height)
        x += wordSize.width + OpenPlaceMetrics.spacing
        hintPlace = hint.map { hint in
            let size = CardRestKeyView.size(key: hint.restKey, fontSize: environment.fontSize, scale: scale)
            return NSRect(x: x.rounded(toPixelsOf: scale), y: middle(size.height), width: size.width, height: size.height)
        }
        border.frame = bounds
    }
}

/// The dashed border of an Open Place, inside its edges, as SwiftUI's `strokeBorder` draws it on a rounded rectangle.
/// `DropSlotView` draws its border in the same way.
private final class OpenPlaceBorderView: LayerColoredView {
    private let border = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = CALayer()
        wantsLayer = true
        border.fillColor = nil
        border.lineWidth = OpenPlaceMetrics.borderWidth
        border.lineDashPattern = OpenPlaceMetrics.dash.map { NSNumber(value: Double($0)) }
        layer?.addSublayer(border)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        LayerGlide.withoutActions {
            let inset = bounds.insetBy(dx: OpenPlaceMetrics.borderWidth / 2, dy: OpenPlaceMetrics.borderWidth / 2)
            let radius = max(0, OpenPlaceMetrics.cornerRadius - OpenPlaceMetrics.borderWidth / 2)
            border.path = inset.width > 0 && inset.height > 0
                ? CGPath(roundedRect: inset, cornerWidth: radius, cornerHeight: radius, transform: nil) : nil
        }
    }

    override func colorLayers() {
        border.strokeColor = NSColor.secondaryLabelColor.faded(OpenPlaceMetrics.borderOpacity).cgColor
    }
}
