import AppKit
import MuxifyCore
import SwiftUI

/// The Working mark of a row: square pixels light up one step at a time, like a terminal activity glyph.
/// Every moving glyph shares a clock; a still one has no animation timer.
///
/// Core Animation moves the glyph, not SwiftUI. A SwiftUI animation clock, such as a `TimelineView`, makes SwiftUI
/// update and lay out the whole App Window on each tick, and with an Agent at work that kept the main thread busy
/// all the time: a swipe between Topics and Sessions then waited for it. See "Agent marks" in docs/development.md.
struct TerminalActivityIndicator: View {
    let moves: Bool
    let color: Color

    @Environment(\.interfaceFontSize) private var fontSize

    static let period: TimeInterval = 1.2

    static func phase(at date: Date) -> Double {
        let cycles = date.timeIntervalSinceReferenceDate / period
        return cycles - floor(cycles)
    }

    var body: some View {
        if !moves {
            TerminalActivityGlyph(phase: 0, color: color)
        } else {
            MovingTerminalActivityGlyph(color: color)
                .frame(width: fontSize(TerminalActivityGlyph.footprint), height: fontSize(TerminalActivityGlyph.footprint))
                .accessibilityHidden(true)
        }
    }
}

/// Eight separate square pixels on a three-column, three-row perimeter. No outline
/// connects them: a bright head and two dimmer trailing pixels step clockwise.
struct TerminalActivityGlyph: View {
    let phase: Double
    let color: Color

    @Environment(\.displayScale) private var displayScale
    /// The glyph sits beside a row's text, so its footprint and blocks grow with the Interface font size.
    @Environment(\.interfaceFontSize) private var fontSize

    /// A block at 12.
    static let blockSize: CGFloat = 3
    /// The glyph's footprint at 12.
    static let footprint: CGFloat = 10

    static let cells: [CGPoint] = [
        CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 2, y: 0), CGPoint(x: 2, y: 1),
        CGPoint(x: 2, y: 2), CGPoint(x: 1, y: 2), CGPoint(x: 0, y: 2), CGPoint(x: 0, y: 1),
    ]

    static func head(at phase: Double) -> Int {
        // Wall-clock dates lose a little precision at exact tick boundaries.
        // This tolerance prevents a repeated pixel followed by a skipped one.
        let position = (phase - floor(phase)) * Double(cells.count)
        return Int(floor(position + 0.00001)) % cells.count
    }

    var body: some View {
        Canvas { context, size in
            let head = Self.head(at: phase)
            for (index, block) in Self.blocks(in: size, displayScale: displayScale, maxBlockSize: fontSize(Self.blockSize)).enumerated() {
                let opacity = Self.opacity(stepsBehindHead: (head - index + Self.cells.count) % Self.cells.count)
                context.fill(Path(block), with: .color(color.opacity(opacity)))
            }
        }
        .frame(width: fontSize(Self.footprint), height: fontSize(Self.footprint))
    }

    /// The opacity of a block that lights `steps` steps after the head.
    static func opacity(stepsBehindHead steps: Int) -> Double {
        switch steps {
        case 0: 0.85
        case 1: 0.55
        case 2: 0.32
        default: 0.16
        }
    }

    /// The block of each cell, in `cells` order, in a glyph of `size` with the top left at the origin.
    static func blocks(in size: CGSize, displayScale: CGFloat, maxBlockSize: CGFloat) -> [CGRect] {
        // Reserve a physical pixel for each gap. At 12 and 1×, use 2 pt
        // blocks so all eight stay separate within the same 10 pt
        // footprint; at 2×, retain the 3 pt blocks and half-point gaps.
        // At other sizes the footprint and the 3 pt cap scale by the factor.
        let gap = 1 / displayScale
        let availablePixels = min(size.width, size.height) * displayScale - 2
        let blockSize = min(maxBlockSize, floor(availablePixels / 3) / displayScale)
        let pitch = blockSize + gap
        let extent = 2 * pitch + blockSize
        // Align the entire grid to physical pixels to avoid antialiasing
        // that would blur adjacent blocks together.
        let origin = CGPoint(x: ((size.width - extent) / 2 * displayScale).rounded() / displayScale,
                             y: ((size.height - extent) / 2 * displayScale).rounded() / displayScale)
        return cells.map { cell in
            CGRect(x: origin.x + cell.x * pitch, y: origin.y + cell.y * pitch, width: blockSize, height: blockSize)
        }
    }
}

/// The moving glyph: the blocks of `TerminalActivityGlyph` as layers that Core Animation steps on the shared clock,
/// so a moving glyph costs SwiftUI nothing after it is placed.
private struct MovingTerminalActivityGlyph: NSViewRepresentable {
    let color: Color

    func makeNSView(context: Context) -> MovingTerminalActivityGlyphView { MovingTerminalActivityGlyphView() }

    func updateNSView(_ view: MovingTerminalActivityGlyphView, context: Context) {
        view.color = color.resolve(in: context.environment).cgColor
        view.maxBlockSize = context.environment.interfaceFontSize(TerminalActivityGlyph.blockSize)
    }
}

final class MovingTerminalActivityGlyphView: NSView {
    var color: CGColor = .clear {
        didSet {
            guard color != oldValue else { return }
            withoutActions { for block in blocks { block.backgroundColor = color } }
        }
    }
    var maxBlockSize: CGFloat = TerminalActivityGlyph.blockSize {
        didSet { if maxBlockSize != oldValue { needsLayout = true } }
    }
    let blocks = TerminalActivityGlyph.cells.map { _ in CALayer() }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for block in blocks { layer?.addSublayer(block) }
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// The glyph only shows; clicks go to the row under it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 2
        let frames = TerminalActivityGlyph.blocks(in: bounds.size, displayScale: scale, maxBlockSize: maxBlockSize)
        withoutActions {
            for (block, frame) in zip(blocks, frames) {
                block.frame = frame
                block.contentsScale = scale
            }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { step() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    /// Each block takes its opacity for each of the eight steps from the same table as the still glyph, starting at
    /// the shared clock's step, so every glyph lights the same cell at the same time.
    private func step() {
        let count = TerminalActivityGlyph.cells.count
        let period = TerminalActivityIndicator.period
        let offset = TerminalActivityIndicator.phase(at: Date()) * period
        for (index, block) in blocks.enumerated() {
            let values = (0..<count).map { head in TerminalActivityGlyph.opacity(stepsBehindHead: (head - index + count) % count) }
            let animation = CAKeyframeAnimation(keyPath: "opacity")
            animation.values = values
            animation.keyTimes = (0...count).map { NSNumber(value: Double($0) / Double(count)) }
            animation.calculationMode = .discrete
            animation.duration = period
            animation.repeatCount = .infinity
            animation.timeOffset = offset
            animation.isRemovedOnCompletion = false
            withoutActions { block.opacity = Float(values[0]) }
            block.add(animation, forKey: "step")
        }
    }
}

/// Changes layers at once, without Core Animation's implicit fade.
func withoutActions(_ change: () -> Void) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    change()
    CATransaction.commit()
}
