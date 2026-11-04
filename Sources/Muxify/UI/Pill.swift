import SwiftUI

/// A short message at the App Window's bottom that never takes Focus or clicks (CONTEXT.md).
struct Pill: Equatable {
    enum Kind: String {
        /// A change ran: "Copied Path", "Merged".
        case confirmation
        /// An Action changed nothing, or less than the user could expect, and says why.
        case explanation

        /// An explanation is longer, so it stays longer.
        var life: TimeInterval {
            switch self {
            case .confirmation: 1.5
            case .explanation: 3.5
            }
        }
    }

    let id = UUID()
    let kind: Kind
    let title: String
    let value: String

    init(_ kind: Kind, title: String, value: String) {
        self.kind = kind
        self.title = title
        self.value = value
    }
}

/// The App Window's one Pill: a new one replaces the shown one and restarts its time.
@MainActor @Observable
final class Pills {
    private(set) var shown: Pill?
    @ObservationIgnored private var hideWork: DispatchWorkItem?

    func show(_ pill: Pill) {
        hideWork?.cancel()
        withAnimation(.spring(duration: 0.4, bounce: 0.35)) { shown = pill }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.shown?.id == pill.id else { return }
                withAnimation(.easeIn(duration: 0.2)) { self.shown = nil }
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + pill.kind.life, execute: work)
    }
}

/// Fills the App Window even with no Pill, so the Pill gets the palette's width and sits at the bottom.
struct PillOverlay: View {
    let pills: Pills
    let theme: PaletteTheme
    @Environment(\.interfaceFontSize) private var fontSize

    var body: some View {
        GeometryReader { proxy in
            VStack {
                if let pill = pills.shown {
                    PillView(pill: pill, theme: theme)
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.7, anchor: .bottom).combined(with: .opacity),
                            removal: .opacity
                        ))
                        .id(pill.id)
                }
            }
            .frame(width: PaletteMetrics.width(in: proxy.size, size: fontSize))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 28)
            .allowsHitTesting(false)
        }
    }
}

/// Springs in at the bottom. A confirmation draws its check on, then bounces it once; an explanation shows its mark
/// at once.
private struct PillView: View {
    let pill: Pill
    let theme: PaletteTheme
    @State private var showsCheck = false
    @State private var bounces = 0

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().fill(pill.kind == .confirmation ? theme.green : theme.yellow)
                switch pill.kind {
                case .confirmation: if showsCheck { check }
                case .explanation: mark
                }
            }
            .frame(width: 22, height: 22)
            Text(pill.title)
                .font(.system(size: 13, weight: .semibold))
            Text(pill.value)
                .font(pill.kind == .confirmation ? .system(size: 12, design: .monospaced) : .system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, 2)
        }
        .padding(.leading, 8)
        .padding(.trailing, 16)
        .frame(height: 38)
        .spotlightGlass(theme, cornerRadius: 19, tint: 0.6)
        .foregroundStyle(.primary)
        .environment(\.colorScheme, theme.colorScheme)
        .accessibilityElement(children: .ignore)
        // Static text keeps the value in the accessibility tree, where an element with no role drops it.
        .accessibilityAddTraits(.isStaticText)
        .accessibilityIdentifier("pill")
        .accessibilityLabel(pill.title)
        .accessibilityValue(pill.kind.rawValue + ": " + pill.value)
        .task {
            guard pill.kind == .confirmation else { return }
            try? await Task.sleep(for: .milliseconds(120))
            withAnimation(.easeOut(duration: 0.3)) { showsCheck = true }
            try? await Task.sleep(for: .milliseconds(380))
            bounces += 1
        }
    }

    private var mark: some View {
        Image(systemName: "exclamationmark")
            .font(.system(size: 11, weight: .heavy))
            .foregroundStyle(.white)
    }

    @ViewBuilder private var check: some View {
        let image = Image(systemName: "checkmark")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .symbolEffect(.bounce, value: bounces)
        if #available(macOS 26.0, *) {
            image.transition(.symbolEffect(.drawOn))
        } else {
            image.transition(.scale(scale: 0.4).combined(with: .opacity))
        }
    }
}
