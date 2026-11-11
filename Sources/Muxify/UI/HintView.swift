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
        Text(HintBadgeMetrics.text(triggers))
            .font(fontSize.font(HintBadgeMetrics.fontSize, weight: .semibold, design: .monospaced))
            .foregroundStyle(.primary)
            .padding(.horizontal, HintBadgeMetrics.horizontalPadding).padding(.vertical, HintBadgeMetrics.verticalPadding)
            .background(Color(red: HintBadgeMetrics.fill.red, green: HintBadgeMetrics.fill.green, blue: HintBadgeMetrics.fill.blue)
                .opacity(HintBadgeMetrics.fillOpacity), in: RoundedRectangle(cornerRadius: HintBadgeMetrics.cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: HintBadgeMetrics.cornerRadius)
                    .strokeBorder(.white.opacity(HintBadgeMetrics.borderOpacity), lineWidth: HintBadgeMetrics.borderWidth)
            }
            .environment(\.colorScheme, .dark)
            .fixedSize()
            .allowsHitTesting(false)
            .accessibilityIdentifier(target.accessibilityID)
    }
}

/// The sizes and colours of a Hint's badge, for both versions of the Sessions list (ADR 0074). The font size is at 12,
/// and grows with the Interface font size.
enum HintBadgeMetrics {
    /// The keys are semibold and monospaced.
    static let fontSize: CGFloat = 11
    static let horizontalPadding: CGFloat = 5
    static let verticalPadding: CGFloat = 2
    static let cornerRadius: CGFloat = 5
    /// The box is this colour in sRGB at `fillOpacity`, with a border of white at `borderOpacity`. The keys are the text
    /// colour of the dark scheme, also in a light theme.
    static let fill = (red: 30.0 / 255, green: 31.0 / 255, blue: 35.0 / 255)
    static let fillOpacity = 0.9
    static let borderOpacity = 0.35
    static let borderWidth: CGFloat = 1

    /// The keys of the badge, joined by a space, such as "⌃2".
    static func text(_ triggers: [KeyTrigger]) -> String { triggers.map(\.symbol).joined(separator: " ") }
}

/// Where a Window row's Hint stands and how its key at rest looks, for both versions of the Sessions list (ADR 0074).
enum WindowHintMetrics {
    /// The Hint stands this far right of and below the row's top left corner, in the room the row keeps for it.
    static let inset: CGFloat = 5
    /// The key at rest is medium and monospaced, in the secondary text colour, at 12.
    static let keyFontSize: CGFloat = 10
}

struct HintKey: View {
    let target: QuickSwitchTarget
    let key: String
    @Environment(\.interfaceFontSize) private var fontSize

    var body: some View {
        Text(key)
            .font(fontSize.font(WindowHintMetrics.keyFontSize, weight: .medium, design: .monospaced))
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
            .font(fontSize.font(CardRestKeyMetrics.fontSize, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.primary.opacity(CardRestKeyMetrics.textOpacity))
            .padding(.horizontal, CardRestKeyMetrics.horizontalPadding)
            .frame(minWidth: fontSize(CardRestKeyMetrics.minSide), minHeight: fontSize(CardRestKeyMetrics.minSide))
            .background(Capsule().fill(Color.primary.opacity(CardRestKeyMetrics.fillOpacity)))
            .fixedSize()
            .allowsHitTesting(false)
            .accessibilityIdentifier(target.accessibilityID)
    }
}

/// The sizes and colours of a card's key at rest, for both versions of the card (ADR 0074). The sizes are at 12, and
/// grow with the Interface font size.
enum CardRestKeyMetrics {
    /// The key is semibold, in the rounded design.
    static let fontSize: CGFloat = 10
    static let horizontalPadding: CGFloat = 4
    /// The capsule is at least this wide and this high.
    static let minSide: CGFloat = 16
    /// The key is the text colour at this opacity, and its capsule at `fillOpacity`.
    static let textOpacity = 0.7
    static let fillOpacity = 0.12
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

extension View {
    func hintAnchor(_ target: QuickSwitchTarget?) -> some View {
        anchorPreference(key: HintAnchors.self, value: .bounds) { anchor in
            target.map { [$0: anchor] } ?? [:]
        }
    }

    func cardHints(_ hints: HintPresentation) -> some View {
        overlayPreferenceValue(HintAnchors.self) { anchors in
            GeometryReader { proxy in
                ForEach(anchors.keys.sorted { $0.accessibilityID < $1.accessibilityID }, id: \.self) { target in
                    if let anchor = anchors[target] {
                        let rect = proxy[anchor]
                        if case .window = target {
                            WindowHint(target: target, hints: hints, height: rect.height)
                                .offset(x: rect.minX + WindowHintMetrics.inset, y: rect.minY + WindowHintMetrics.inset)
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
