import AppKit
import MuxifyCore
import QuartzCore

/// The Agent mark of a row in the AppKit Sessions list (ADR 0074): `AgentMarkView` in SwiftUI. The Working mark is the
/// pixel glyph of `WorkingGlyph`, whose pixels step on the clock that every Working mark shares; a Notification is a
/// dot in the mark's colour of the Config. The mark stands in the middle of the view, and both grow with the Interface
/// font size. The view's corner must stand on a device pixel, so the glyph's pixels do too.
final class SidebarAgentMark: NSView {
    private var mark: AgentMark?
    private var colors = AgentColors()
    private var moves = false
    private var fontSize = InterfaceFontSize()
    private var scale: CGFloat = 2
    /// The glyph's footprint, which holds its pixels.
    private let glyph = CALayer()
    private let pixels: [CALayer] = WorkingGlyph.cells.map { _ in CALayer() }
    /// The dot of a Notification.
    private let dot = CAShapeLayer()

    static let stepKey = "step"

    init() {
        super.init(frame: .zero)
        layer = CALayer()
        wantsLayer = true
        for pixel in pixels { glyph.addSublayer(pixel) }
        // A row without a mark keeps its place empty.
        glyph.isHidden = true
        dot.isHidden = true
        layer?.addSublayer(glyph)
        layer?.addSublayer(dot)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Shows the mark, nil for none, in its colour of the Config. `moves` is false with Reduce Motion or
    /// `ui.pulse: false`: the Working mark then stands still at its first step.
    func show(_ mark: AgentMark?, colors: AgentColors, moves: Bool, fontSize: InterfaceFontSize, scale: CGFloat) {
        guard mark != self.mark || colors != self.colors || moves != self.moves || fontSize != self.fontSize || scale != self.scale
        else { return }
        self.mark = mark
        self.colors = colors
        self.moves = moves
        self.fontSize = fontSize
        self.scale = scale
        glyph.isHidden = mark != .working
        dot.isHidden = mark == nil || mark == .working
        layOut()
        color()
        step()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layOut()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        color()
        step()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        color()
    }

    private var footprint: CGSize { CGSize(width: fontSize(WorkingGlyph.footprint), height: fontSize(WorkingGlyph.footprint)) }

    /// The pixels at each step of the period, from the first.
    private var steps: [[(frame: CGRect, opacity: Double)]] {
        (0..<WorkingGlyph.steps).map { step in
            WorkingGlyph.pixels(in: footprint, phase: Double(step) / Double(WorkingGlyph.steps), fontSize: fontSize, displayScale: scale)
        }
    }

    /// A square of `side` in the middle of the view, on device pixels.
    private func middle(_ side: CGFloat) -> CGRect {
        CGRect(x: ((bounds.width - side) / 2).rounded(toPixelsOf: scale), y: ((bounds.height - side) / 2).rounded(toPixelsOf: scale),
               width: side, height: side)
    }

    /// The glyph, with its pixels as they stand at the first step, and the dot.
    private func layOut() {
        LayerGlide.withoutActions {
            glyph.frame = middle(footprint.width)
            for (layer, pixel) in zip(pixels, steps[0]) {
                layer.frame = pixel.frame
                layer.opacity = Float(pixel.opacity)
            }
            let side = fontSize(AgentMarkMetrics.dotSize)
            dot.frame = middle(side)
            dot.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: side, height: side), transform: nil)
            dot.contentsScale = scale
        }
    }

    /// A mark's colour can differ between the light and the dark appearance, and a layer keeps the colour it got.
    private func color() {
        guard let mark else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color = colors[mark].nsColor(in: effectiveAppearance).cgColor
            LayerGlide.withoutActions {
                if mark == .working {
                    for pixel in pixels { pixel.backgroundColor = color }
                } else {
                    dot.fillColor = color
                }
            }
        }
    }

    /// Starts or stops the steps: each pixel's opacity at each of the eight steps of the period, again and again on the
    /// clock of the marks, with no change between two steps.
    private func step() {
        guard moves, mark == .working else {
            for pixel in pixels { pixel.removeAnimation(forKey: Self.stepKey) }
            return
        }
        let steps = steps
        for (index, pixel) in pixels.enumerated() {
            let animation = CAKeyframeAnimation(keyPath: "opacity")
            animation.values = steps.map { Float($0[index].opacity) }
            // A discrete animation holds each value from its key time to the next, so it has one more key time.
            animation.keyTimes = (0...steps.count).map { NSNumber(value: Double($0) / Double(steps.count)) }
            animation.calculationMode = .discrete
            MarkClock.repeats(animation, every: WorkingGlyph.period, on: pixel)
            pixel.add(animation, forKey: Self.stepKey)
        }
    }

    #if DEBUG
    /// The steps of the glyph's pixels that run now, the frames of its pixels in the view, and their opacities, for
    /// the tests.
    var stepAnimations: [CAAnimation] { pixels.compactMap { $0.animation(forKey: Self.stepKey) } }
    var pixelFrames: [CGRect] { pixels.map { glyph.convert($0.frame, to: layer) } }
    var pixelOpacities: [Float] { pixels.map(\.opacity) }
    /// The dot's colour and frame in the view, nil when the view shows no dot.
    var dotColor: CGColor? { dot.isHidden ? nil : dot.fillColor }
    var dotFrame: CGRect { dot.frame }
    #endif
}
