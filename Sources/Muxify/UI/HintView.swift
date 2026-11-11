import SwiftUI
import MuxifyCore

private struct HintAnchors: PreferenceKey {
    static var defaultValue: [QuickSwitchTarget: Anchor<CGRect>] = [:]
    static func reduce(value: inout [QuickSwitchTarget: Anchor<CGRect>], nextValue: () -> [QuickSwitchTarget: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

struct HintBadge: View {
    let target: QuickSwitchTarget
    let triggers: [KeyTrigger]
    @Environment(\.interfaceFontSize) private var fontSize

    var body: some View {
        Text(triggers.map(\.symbol).joined(separator: " "))
            .font(fontSize.font(11, weight: .semibold, design: .monospaced))
            .foregroundStyle(.primary)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Color(red: 30 / 255, green: 31 / 255, blue: 35 / 255).opacity(0.9), in: RoundedRectangle(cornerRadius: 5))
            .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.35), lineWidth: 1) }
            .environment(\.colorScheme, .dark)
            .fixedSize()
            .allowsHitTesting(false)
            .accessibilityIdentifier(target.accessibilityID)
    }
}

struct HintKey: View {
    let target: QuickSwitchTarget
    let key: String
    @Environment(\.interfaceFontSize) private var fontSize

    var body: some View {
        Text(key)
            .font(fontSize.font(10, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
            .fixedSize()
            .allowsHitTesting(false)
            .accessibilityIdentifier(target.accessibilityID)
    }
}

/// The place of a card's Hint: just after its title, on the title's first baseline.
/// `cardHints` draws the Hint over this place, because the header hides its children from accessibility, and the card's
/// dimming must not dim the badge. The place is as wide as the key, so the title does not wrap again when the badge shows.
struct CardHintSlot: View {
    let target: QuickSwitchTarget
    @Environment(\.quickSwitchHints) private var hints

    var body: some View {
        if hints.restKey(for: target) != nil || !hints[target].isEmpty {
            CardRestKey(target: target, key: hints.restKey(for: target) ?? "")
                .hidden()
                .hintAnchor(target)
        }
    }
}

/// A card's key at rest, on a faint circle of the theme's text colour, so it does not read as one of the counts in the
/// card and does not draw the eye more than the title.
struct CardRestKey: View {
    let target: QuickSwitchTarget
    let key: String
    @Environment(\.interfaceFontSize) private var fontSize

    var body: some View {
        Text(key)
            .font(fontSize.font(10, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.primary.opacity(0.7))
            .padding(.horizontal, 4)
            .frame(minWidth: fontSize(16), minHeight: fontSize(16))
            .background(Capsule().fill(Color.primary.opacity(0.12)))
            .fixedSize()
            .allowsHitTesting(false)
            .accessibilityIdentifier(target.accessibilityID)
    }
}

/// A Window row's Hint, in the place the row keeps for it before its icon, as wide as a key.
private struct WindowHint: View {
    let target: QuickSwitchTarget
    let hints: HintPresentation
    let height: CGFloat
    @Environment(\.interfaceFontSize) private var fontSize

    var body: some View {
        Group {
            if !hints[target].isEmpty {
                HintBadge(target: target, triggers: hints[target])
            } else if let key = hints.restKey(for: target) {
                HintKey(target: target, key: key)
            }
        }
        .frame(width: fontSize(13), height: height, alignment: .topLeading)
    }
}

private struct CardHints: View {
    let anchors: [QuickSwitchTarget: Anchor<CGRect>]
    @Environment(\.quickSwitchHints) private var hints

    var body: some View {
        GeometryReader { proxy in
            ForEach(anchors.keys.sorted { $0.accessibilityID < $1.accessibilityID }, id: \.self) { target in
                if let anchor = anchors[target] {
                    let rect = proxy[anchor]
                    if case .window = target {
                        WindowHint(target: target, hints: hints, height: rect.height)
                            .offset(x: rect.minX + 5, y: rect.minY + 5)
                    } else {
                        // The badge ends where the key ends, and grows over the title.
                        Color.clear
                            .frame(width: rect.width, height: rect.height)
                            .overlay(alignment: .trailing) {
                                if !hints[target].isEmpty {
                                    HintBadge(target: target, triggers: hints[target])
                                } else if let key = hints.restKey(for: target) {
                                    CardRestKey(target: target, key: key)
                                }
                            }
                            .offset(x: rect.minX, y: rect.minY)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// Hides a card's mark while the card's Hint badge shows in its place. It reads the Hints itself, so the card's
/// header does not run again when they change.
struct HintHidesMark: ViewModifier {
    let target: QuickSwitchTarget?
    @Environment(\.quickSwitchHints) private var hints

    func body(content: Content) -> some View {
        content.opacity(target.map { hints[$0].isEmpty ? 1 : 0 } ?? 1)
    }
}

/// The room a Window row keeps for its Window Hint when the Hints reserve it. It reads the Hints itself, so the row does
/// not run again when they change.
struct WindowHintSpace: View {
    @Environment(\.quickSwitchHints) private var hints
    @Environment(\.interfaceFontSize) private var fontSize

    var body: some View {
        if hints.windowSlotReserved { Color.clear.frame(width: fontSize(10)) }
    }
}

extension View {
    func hintAnchor(_ target: QuickSwitchTarget?) -> some View {
        anchorPreference(key: HintAnchors.self, value: .bounds) { anchor in
            target.map { [$0: anchor] } ?? [:]
        }
    }

    /// Draws the Hints of the card's `CardHintSlot`s over it. The overlay reads the Hints itself, so a change of the
    /// Hints, as a switch between Topics and Sessions makes, runs only the overlay again, not the card's body.
    func cardHints() -> some View {
        overlayPreferenceValue(HintAnchors.self) { anchors in
            CardHints(anchors: anchors)
        }
        .transformPreference(HintAnchors.self) { $0 = [:] }
    }

    func quickSwitchHint(_ target: QuickSwitchTarget, hints: HintPresentation) -> some View {
        overlay(alignment: .topTrailing) {
            if !hints[target].isEmpty {
                HintBadge(target: target, triggers: hints[target]).padding(4)
            }
        }
    }
}
