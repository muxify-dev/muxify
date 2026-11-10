import AppKit
import SwiftUI
import MuxifyCore

/// The Agent mark of a row: a Pane row, an Agents row or a Command Palette result. The Working mark is the pixel glyph;
/// a Notification is a dot.
struct AgentMarkView: View {
    let mark: AgentMark
    /// The dot's size; by default `designDotSize` grown with the Interface font size, as it sits beside a row's text.
    var dotSize: CGFloat? = nil

    /// The dot's size at 12.
    static let designDotSize: CGFloat = 7

    @Environment(\.interfaceFontSize) private var fontSize

    @Environment(\.agentColors) private var colors
    @Environment(\.pulses) private var pulses
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let color = colors[mark].color
        if mark == .working {
            TerminalActivityIndicator(moves: pulses && !reduceMotion, color: color)
        } else {
            let dotSize = dotSize ?? fontSize(Self.designDotSize)
            Circle().fill(color).frame(width: dotSize, height: dotSize)
        }
    }
}

/// The Agent mark of a card: a bar along its left edge. The Working mark's bar fades in and out, and stays still with
/// Reduce Motion or `ui.pulse: false`.
struct AgentMarkSpine: View {
    let mark: AgentMark

    @Environment(\.agentColors) private var colors
    @Environment(\.pulses) private var pulses
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let cornerRadius: CGFloat = 2

    var body: some View {
        let color = colors[mark].color
        if mark == .working, pulses, !reduceMotion {
            // The shape stays the view that callers label and identify; the layer on it only shows.
            RoundedRectangle(cornerRadius: Self.cornerRadius).fill(Color.clear)
                .overlay { BreathingBar(color: color, cornerRadius: Self.cornerRadius).accessibilityHidden(true) }
        } else {
            RoundedRectangle(cornerRadius: Self.cornerRadius).fill(color)
        }
    }
}

extension MarkColor {
    /// A pair follows the appearance of the view that draws it.
    var color: Color {
        if case .single(let color) = self { return Color(nsColor: color.nsColor) }
        return Color(nsColor: NSColor(name: nil) { nsColor(in: $0) })
    }

    func nsColor(in appearance: NSAppearance) -> NSColor {
        switch self {
        case .single(let color): color.nsColor
        case .pair(let light, let dark): appearance.isDark ? dark.nsColor : light.nsColor
        }
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

extension MarkColor.Single {
    var nsColor: NSColor {
        switch self {
        case .system(let name):
            let colors: [SystemColorName: NSColor] = [
                .blue: .systemBlue, .orange: .systemOrange, .red: .systemRed, .green: .systemGreen, .yellow: .systemYellow,
                .purple: .systemPurple, .pink: .systemPink, .teal: .systemTeal, .gray: .systemGray,
            ]
            return colors[name]!
        case .rgb(let red, let green, let blue):
            return NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
        }
    }
}

/// The Working mark's bar. Core Animation fades it in and out on the clock every card's Working mark reads, so they
/// breathe together, and SwiftUI does no work while it fades: see `TerminalActivityIndicator` for why.
private struct BreathingBar: NSViewRepresentable {
    let color: Color
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> BreathingBarView { BreathingBarView() }

    func updateNSView(_ view: BreathingBarView, context: Context) {
        view.bar.cornerRadius = cornerRadius
        let color = color.resolve(in: context.environment).cgColor
        if view.bar.backgroundColor != color { withoutActions { view.bar.backgroundColor = color } }
    }
}

final class BreathingBarView: NSView {
    static let period: TimeInterval = 1.6
    let bar = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(bar)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        withoutActions { bar.frame = bounds }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        // One cycle of 0.675 + 0.325 cos(2π t / period), from the shared clock's point in it.
        let samples = 32
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = (0...samples).map { 0.675 + 0.325 * cos(2 * .pi * Double($0) / Double(samples)) }
        animation.duration = Self.period
        animation.repeatCount = .infinity
        // Begin now, not when the transaction commits, or the bar lags the clock by the wait for the commit.
        animation.beginTime = bar.convertTime(CACurrentMediaTime(), from: nil)
        animation.timeOffset = Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period)
        animation.isRemovedOnCompletion = false
        bar.add(animation, forKey: "breathe")
    }
}

private struct PulsesKey: EnvironmentKey {
    static let defaultValue = true
}

private struct AgentColorsKey: EnvironmentKey {
    static let defaultValue = AgentColors()
}

extension EnvironmentValues {
    /// `ui.pulse` in the Config.
    var pulses: Bool {
        get { self[PulsesKey.self] }
        set { self[PulsesKey.self] = newValue }
    }

    /// `ui.agent_colors` in the Config.
    var agentColors: AgentColors {
        get { self[AgentColorsKey.self] }
        set { self[AgentColorsKey.self] = newValue }
    }
}
