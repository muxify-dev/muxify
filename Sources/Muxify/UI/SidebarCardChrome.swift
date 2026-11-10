import AppKit
import MuxifyCore
import QuartzCore

/// The parts of a card in the AppKit Sessions list that are not its header or its rows (ADR 0074): the fill of an
/// open card, the spine and the border of the card that holds the Location's Window. Each is a view that hosts its
/// own layers, takes no click, and reads the sizes that the SwiftUI card reads.

/// The raised look of an open card: a faint fill of the text colour over a shadow, under the card's rounded shape.
/// The fill is a layer under the view's own, because AppKit takes the shadow off the layer of a view.
final class CardFillView: NSView {
    private let fill = CALayer()

    init() {
        super.init(frame: .zero)
        layer = CALayer()
        wantsLayer = true
        fill.cornerRadius = CardOutline.cornerRadius
        fill.cornerCurve = .continuous
        fill.shadowColor = .black
        fill.shadowOpacity = Float(CardOutline.shadowOpacity)
        fill.shadowRadius = CardOutline.shadowRadius
        // A layer's shadow counts upward, also in a flipped view.
        fill.shadowOffset = CGSize(width: 0, height: -CardOutline.shadowDrop)
        layer?.addSublayer(fill)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        LayerGlide.withoutActions { fill.frame = bounds }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        color()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        color()
    }

    /// A layer keeps the colour it got, so it gets the text colour again for each appearance.
    private func color() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            LayerGlide.withoutActions { fill.backgroundColor = NSColor.labelColor.faded(CardOutline.openFillOpacity).cgColor }
        }
    }
}

/// The clock of the marks that Core Animation moves (ADR 0074). SwiftUI's marks read the time since the reference
/// date, so that they move together. An animation that repeats on this clock began with the period of that time
/// which ran when the first mark asked, so every mark keeps one beat, whenever it starts, and the beat of SwiftUI's
/// marks.
enum MarkClock {
    /// One moment on both clocks: Core Animation's, and the time since the reference date.
    private static let start = (media: CACurrentMediaTime(), date: Date().timeIntervalSinceReferenceDate)

    /// Makes the animation one period that repeats on the clock, for a layer that it is then added to.
    static func repeats(_ animation: CAAnimation, every period: TimeInterval, on layer: CALayer) {
        animation.duration = period
        animation.repeatCount = .infinity
        animation.beginTime = layer.convertTime(start.media, from: nil)
        animation.timeOffset = start.date.truncatingRemainder(dividingBy: period)
    }
}

/// The spine: a bar along the card's left edge in the colour of the card's mark. The Working mark's bar fades in and
/// out on the clock that every Working mark shares.
final class CardSpineView: NSView {
    private let bar = CALayer()
    private var mark: CardMark?
    private var colors = AgentColors()
    private var breathes = false

    private static let breath = "breath"

    init() {
        super.init(frame: .zero)
        layer = CALayer()
        wantsLayer = true
        // SwiftUI's rounded rectangle has continuous corners.
        bar.cornerCurve = .continuous
        layer?.addSublayer(bar)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Shows the mark in its colour of the Config. `moves` is false with Reduce Motion or `ui.pulse: false`: the
    /// Working mark's bar then stays still.
    func show(_ mark: CardMark?, colors: AgentColors, moves: Bool) {
        self.mark = mark
        self.colors = colors
        breathes = moves && mark == .agent(.working)
        isHidden = mark == nil
        color()
        breathe()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        LayerGlide.withoutActions {
            bar.frame = bounds
            // SwiftUI's rounded rectangle makes its corners no rounder than half its narrow side, and the bar is
            // narrower than two corners.
            bar.cornerRadius = min(CardSpine.cornerRadius, min(bounds.width, bounds.height) / 2)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        color()
        breathe()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        color()
    }

    /// A mark's colour can differ between the light and the dark appearance, and a layer keeps the colour it got.
    private func color() {
        guard let mark else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color: NSColor
            switch mark {
            case .unread: color = .controlAccentColor
            case .agent(let mark): color = colors[mark].nsColor(in: effectiveAppearance)
            }
            LayerGlide.withoutActions { bar.backgroundColor = color.cgColor }
        }
    }

    /// Starts or stops the fade: one period of `MarkBreath`, again and again on the clock of the marks.
    private func breathe() {
        guard breathes else { return bar.removeAnimation(forKey: Self.breath) }
        guard bar.animation(forKey: Self.breath) == nil else { return }
        let steps = 48
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = (0...steps).map { MarkBreath.opacity(at: MarkBreath.period * Double($0) / Double(steps)) }
        MarkClock.repeats(animation, every: MarkBreath.period, on: bar)
        bar.add(animation, forKey: Self.breath)
    }

    #if DEBUG
    /// The fade that runs now, for the tests.
    var fade: CAAnimation? { bar.animation(forKey: Self.breath) }
    #endif
}

/// The ring of a card's border: opaque where the border is, `width` wide inside the card's rounded shape, to mask the
/// colours of the border. The border of a view's own layer draws its round corners without smoothing in the driver's
/// `snapshot`, and a ring that masks does not.
private final class CardRing: CALayer {
    init(width: CGFloat) {
        super.init()
        borderWidth = width
        borderColor = .black
        cornerRadius = CardOutline.cornerRadius
        cornerCurve = .continuous
    }

    override init(layer: Any) { super.init(layer: layer) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// The plain border of a card: the text colour at `CardOutline.borderOpacity`, in a ring of `CardOutline.borderWidth`.
final class CardOutlineView: NSView {
    private let ring = CardRing(width: CardOutline.borderWidth)

    init() {
        super.init(frame: .zero)
        layer = CALayer()
        wantsLayer = true
        layer?.mask = ring
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        LayerGlide.withoutActions { ring.frame = bounds }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        color()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        color()
    }

    /// A layer keeps the colour it got, so it gets the text colour again for each appearance.
    private func color() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            LayerGlide.withoutActions { layer?.backgroundColor = NSColor.labelColor.faded(CardOutline.borderOpacity).cgColor }
        }
    }
}

/// The border of the card that holds the Location's Window: the colours of `CardSelectionBorder` around the card, in
/// the shape of the plain border and twice as wide. The colours are one gradient around the card's centre, and a
/// ring cuts the border out of it. `turn` turns the colours once.
final class CardSelectionBorderView: NSView {
    private let colors = CAGradientLayer()
    private let ring = CardRing(width: CardSelectionBorder.width)

    private static let turn = "turn"

    /// The colours around the card with the border's saturation, at even steps. SwiftUI's angular gradient mixes two
    /// colours in Oklab, and its saturation then works on each colour as the screen shows it, keeping each part in its
    /// range. Neither is a straight line between two of `CardSelectionBorder.colors`, which is how the layer mixes
    /// them, so the layer gets the colour of each tenth of the way.
    private static let saturated: [CGColor] = {
        let colors = CardSelectionBorder.colors.map(Oklab.init), steps = 10
        func saturated(_ color: Oklab) -> CGColor {
            let (red, green, blue) = color.rgb
            let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
            func part(_ part: Double) -> CGFloat { CGFloat(min(1, max(0, luminance + CardSelectionBorder.saturation * (part - luminance)))) }
            return CGColor(srgbRed: part(red), green: part(green), blue: part(blue), alpha: 1)
        }
        return zip(colors, colors.dropFirst()).flatMap { from, to in
            (0..<steps).map { step in saturated(from.mixed(with: to, share: Double(step) / Double(steps))) }
        } + [saturated(colors[colors.count - 1])]
    }()

    init() {
        super.init(frame: .zero)
        layer = CALayer()
        wantsLayer = true
        // From 3 o'clock, clockwise in a flipped view, as SwiftUI's angular gradient.
        colors.type = .conic
        colors.startPoint = CGPoint(x: 0.5, y: 0.5)
        colors.endPoint = CGPoint(x: 1, y: 0.5)
        colors.colors = Self.saturated
        layer?.addSublayer(colors)
        layer?.mask = ring
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        LayerGlide.withoutActions {
            ring.frame = bounds
            // A square around the card's centre that covers the card at every angle: the gradient layer measures
            // its angles in its own square, and the turn rotates it.
            let side = hypot(bounds.width, bounds.height)
            colors.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            colors.position = CGPoint(x: bounds.midX, y: bounds.midY)
        }
    }

    /// Turns the colours once, from `CardSelectionBorder.turnStart` to their place.
    func turn() {
        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = CardSelectionBorder.turnStart * .pi / 180
        animation.toValue = 0
        animation.duration = CardSelectionBorder.turnDuration
        let curve = CardSelectionBorder.turnCurve
        animation.timingFunction = CAMediaTimingFunction(controlPoints: Float(curve.x1), Float(curve.y1), Float(curve.x2), Float(curve.y2))
        colors.add(animation, forKey: Self.turn)
    }

    #if DEBUG
    /// The turn that runs now, for the tests.
    var turnAnimation: CAAnimation? { colors.animation(forKey: Self.turn) }
    #endif
}

/// A colour in Oklab, the space in which SwiftUI mixes the colours of a gradient. It is made from an sRGB colour and
/// gives one back, each part from 0 to 1.
private struct Oklab {
    let lightness, a, b: Double

    init(_ color: (red: Double, green: Double, blue: Double)) {
        func linear(_ part: Double) -> Double { part <= 0.04045 ? part / 12.92 : pow((part + 0.055) / 1.055, 2.4) }
        let (red, green, blue) = (linear(color.red), linear(color.green), linear(color.blue))
        let l = cbrt(0.4122214708 * red + 0.5363325363 * green + 0.0514459929 * blue)
        let m = cbrt(0.2119034982 * red + 0.6806995451 * green + 0.1073969566 * blue)
        let s = cbrt(0.0883024619 * red + 0.2817188376 * green + 0.6299787005 * blue)
        self.init(lightness: 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                  a: 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                  b: 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    private init(lightness: Double, a: Double, b: Double) {
        self.lightness = lightness
        self.a = a
        self.b = b
    }

    /// The colour `share` of the way to `other`.
    func mixed(with other: Oklab, share: Double) -> Oklab {
        Oklab(lightness: lightness + (other.lightness - lightness) * share, a: a + (other.a - a) * share, b: b + (other.b - b) * share)
    }

    var rgb: (red: Double, green: Double, blue: Double) {
        let l = pow(lightness + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(lightness - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(lightness - 0.0894841775 * a - 1.2914855480 * b, 3)
        func encoded(_ part: Double) -> Double {
            let part = min(1, max(0, part))
            return part <= 0.0031308 ? 12.92 * part : 1.055 * pow(part, 1 / 2.4) - 0.055
        }
        return (encoded(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
                encoded(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
                encoded(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s))
    }
}
