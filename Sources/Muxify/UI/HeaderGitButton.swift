import SwiftUI
import MuxifyCore

/// A lightweight HEAD read, independent of opening the much larger Git View snapshot.
/// It runs through the Environment connection, so remote paths never read local repositories.
/// The read also tells the store whether the folder is in a repository; the button hides when it is not, unless this
/// Window's Git View is open, and the read goes on while it is hidden, so a `cd` into a repository brings it back.
struct HeaderGitButton: View {
    let store: WorkspaceStore
    let window: TmuxWindow
    let help: String
    @State private var head: String?
    @State private var reading = false
    @Environment(\.interfaceFontSize) private var fontSize

    var body: some View {
        let isOpen = store.currentGitView?.isOpen == true
        HStack(spacing: 0) {
            if store.gitViewRefusal(in: window.path, open: isOpen) == nil {
                HeaderTextButton(isOn: isOpen, action: store.toggleGitView) {
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
                .accessibilityValue(isOpen ? "on" : "off")
                .padding(.trailing, 8)
            }
            // Always here, so the read runs while the button is hidden.
            Color.clear.frame(width: 0, height: 0)
                .task {
                    while !Task.isCancelled {
                        if !reading {
                            reading = true
                            store.runGitScript(GitHeadRead.script, arguments: [window.path], timeout: 5) { result in
                                let read = GitHeadRead(result)
                                head = read.head
                                store.recordHeadRead(read, of: window.path)
                                reading = false
                            }
                        }
                        do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    }
                }
        }
    }
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
