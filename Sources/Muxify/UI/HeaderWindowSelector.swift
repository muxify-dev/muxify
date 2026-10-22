import SwiftUI
import MuxifyCore

/// The Session's tmux status-line window list. Keep every Window visible inline when it fits;
/// otherwise show the selected Window and offer the same list in a dropdown.
struct HeaderWindowSelector: View {
    let store: WorkspaceStore
    let current: TmuxWindow
    @State private var hovering = false

    private var windows: [TmuxWindow] {
        store.windows.filter { $0.sessionID == current.sessionID }.sorted { $0.index < $1.index }
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 3) {
                ForEach(windows) { window in
                    HeaderTextButton(isOn: window.id == current.id, action: { store.select(window) }) {
                        Text(title(window))
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .lineLimit(1)
                    }
                    .help(window.displayTitle)
                    .accessibilityIdentifier("header-window-\(window.id)")
                    .accessibilityValue(window.id == current.id ? "selected" : "")
                }
            }
            // Measure the whole list, not a truncated version of it, before choosing the dropdown.
            .fixedSize(horizontal: true, vertical: false)

            dropdown
        }
    }

    private var dropdown: some View {
        Menu {
            ForEach(windows) { window in
                Button { store.select(window) } label: {
                    if window.id == current.id {
                        Label(title(window), systemImage: "checkmark")
                    } else {
                        Text(title(window))
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(title(current))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.accentColor.opacity(hovering ? 0.3 : 0.22))
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(maxWidth: 220)
        .onHover { hovering = $0 }
        .help("Switch Window")
        .accessibilityIdentifier("header-window-menu")
        .accessibilityLabel("Windows")
        .accessibilityValue(title(current))
        .accessibilityActions {
            ForEach(windows) { window in
                Button("Select \(title(window))") { store.select(window) }
            }
        }
        .actsOnFirstClick()
    }

    private func title(_ window: TmuxWindow) -> String { "\(window.index): \(window.name)" }
}
