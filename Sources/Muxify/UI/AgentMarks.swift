import AppKit
import SwiftUI
import MuxifyCore

/// The Agent mark of a row: a Pane row, an Agents row or a Command Palette result. The Working mark is the pixel glyph;
/// a Notification is a dot.
struct AgentMarkView: View {
    let mark: AgentMark
    var dotSize: CGFloat = 7

    @Environment(\.agentColors) private var colors
    @Environment(\.pulses) private var pulses
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let color = colors[mark].color
        if mark == .working {
            TerminalActivityIndicator(moves: pulses && !reduceMotion, color: color)
        } else {
            Circle().fill(color).frame(width: dotSize, height: dotSize)
        }
    }
}

/// The Agent mark of a card: a bar along its left edge. The Working mark's bar fades in and out.
struct AgentMarkSpine: View {
    let mark: AgentMark

    @Environment(\.agentColors) private var colors

    var body: some View {
        RoundedRectangle(cornerRadius: 2).fill(colors[mark].color)
            .breathing(mark == .working)
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

/// Fades the view in and out on the clock every card's Working mark reads, so they breathe together. It only fades,
/// never moves, and stays still with Reduce Motion or `ui.pulse: false`.
private struct Breathing: ViewModifier {
    let isOn: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.pulses) private var pulses

    private static let period: TimeInterval = 1.6

    func body(content: Content) -> some View {
        if isOn, pulses, !reduceMotion {
            // 30 fps is plenty for a slow fade, and Agents can work for hours.
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                content.opacity(0.675 + 0.325 * cos(2 * .pi * context.date.timeIntervalSinceReferenceDate / Self.period))
            }
        } else {
            content
        }
    }
}

private extension View {
    func breathing(_ isOn: Bool) -> some View { modifier(Breathing(isOn: isOn)) }
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
