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

    var body: some View {
        HeaderTextButton(isOn: store.currentGitView?.isOpen == true, action: store.toggleGitView) {
            HStack(spacing: 6) {
                GitViewIcon(size: 14)
                Text(head ?? "Git")
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: 180)
            .fixedSize(horizontal: true, vertical: false)
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

    var body: some View {
        Button(action: action) {
            label()
                .foregroundStyle(isOn ? Color.primary : Color.secondary)
                .padding(.horizontal, 8)
                .frame(height: 24)
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
