import SwiftUI
import MuxifyCore

/// A lightweight HEAD read, independent of opening the much larger Git View snapshot.
/// It runs through the Environment connection, so remote paths never read local repositories.
struct HeaderGitButton: View {
    let store: WorkspaceStore
    let window: TmuxWindow
    let help: String
    @State private var head: String?
    @State private var reading = false
    @Environment(\.interfaceFontSize) private var fontSize

    var body: some View {
        HeaderTextButton(isOn: store.currentGitView?.isOpen == true, action: store.toggleGitView) {
            HStack(spacing: 6) {
                GitViewIcon(size: fontSize(14))
                Text(head ?? "Git")
                    .font(fontSize.font(13))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .widthUpTo(fontSize(180))
        }
        .help(head.map { "\(help) — \($0)" } ?? help)
        .accessibilityIdentifier("toggle-git-view")
        .accessibilityLabel(head ?? "Git")
        .accessibilityValue(store.currentGitView?.isOpen == true ? "on" : "off")
        .task {
            while !Task.isCancelled {
                if !reading {
                    reading = true
                    store.runGitScript(Self.headScript, arguments: [window.path], timeout: 5) { result in
                        let value = (try? result.get())?.trimmingCharacters(in: .whitespacesAndNewlines)
                        head = value.flatMap { $0.isEmpty ? nil : $0 }
                        reading = false
                    }
                }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    private static let headScript = """
    cd "$1" 2>/dev/null || exit 0
    git symbolic-ref --quiet --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null || true
    """
}

/// Text-sized titlebar controls share the icon controls' first-click and hover behavior.
struct HeaderTextButton<Label: View>: View {
    var isOn = false
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hovering = false
    @Environment(\.interfaceFontSize) private var fontSize

    var body: some View {
        Button(action: action) {
            label()
                .foregroundStyle(isOn ? Color.primary : Color.secondary)
                .padding(.horizontal, 8)
                .frame(height: fontSize(24))
                .background {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isOn ? Color.accentColor.opacity(0.22) : hovering ? Color.primary.opacity(0.08) : .clear)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .actsOnFirstClick()
    }
}

extension View {
    /// As wide as the view's content, up to `maxWidth`, and narrower only when it is offered less: a header control
    /// keeps its whole text while the header has room, and a maximum that grows with the Interface font size never
    /// pushes the other controls off a narrow App Window (ADR 0068).
    func widthUpTo(_ maxWidth: CGFloat) -> some View {
        // The first that fits: the content at its own width up to the maximum, then the content cut to the room left.
        ViewThatFits(in: .horizontal) {
            frame(maxWidth: maxWidth)
                .fixedSize(horizontal: true, vertical: false)
            self
        }
    }
}
