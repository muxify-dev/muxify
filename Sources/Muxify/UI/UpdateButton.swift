import SwiftUI

/// The Update Button in the header of every App Window: what the app-wide `UpdateModel` shows, with Ghostty's texts
/// and symbols. Hidden while the model is idle. A click opens the Update Popover in this App Window; Muxify never
/// opens it by itself (docs/adr/0077-an-update-shows-in-the-header-not-in-the-palette.md).
struct UpdateButton: View {
    let model: UpdateModel
    @State private var showsPopover = false
    @State private var hovering = false
    @Environment(\.interfaceFontSize) private var fontSize

    var body: some View {
        if let text = model.buttonText {
            Button {
                if model.opensPopover { showsPopover.toggle() } else { model.clickWithoutPopover() }
            } label: {
                HStack(spacing: 6) {
                    if let symbol = model.symbol {
                        Image(systemName: symbol)
                            .font(fontSize.font(12, weight: .medium))
                            .foregroundStyle(symbolColor)
                    }
                    Text(text)
                        .font(fontSize.font(12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .foregroundStyle(foreground)
                .padding(.horizontal, 8)
                .frame(height: fontSize(22))
                .background(Capsule().fill(background.opacity(hovering ? 0.85 : 1)))
                .contentShape(Capsule())
                .widthUpTo(fontSize(240))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .actsOnFirstClick()
            .help(text)
            .accessibilityLabel(text)
            .accessibilityIdentifier("update-button")
            .popover(isPresented: $showsPopover, arrowEdge: .bottom) {
                UpdatePopover(model: model, close: { showsPopover = false })
                    .environment(\.interfaceFontSize, fontSize)
            }
            .onChange(of: model.state) { _, _ in
                if !model.opensPopover { showsPopover = false }
            }
            .padding(.trailing, 8)
        }
    }

    private var background: Color {
        switch model.state {
        case .available: .accentColor
        case .failed: .orange.opacity(0.2)
        case .idle, .checking, .notFound: Color(nsColor: .controlBackgroundColor)
        }
    }

    private var foreground: Color {
        switch model.state {
        case .available: .white
        case .failed: .orange
        case .idle, .checking, .notFound: .primary
        }
    }

    private var symbolColor: Color {
        switch model.state {
        case .available: .white
        case .failed: .orange
        case .idle, .checking, .notFound: .secondary
        }
    }
}

/// The Update Popover: an available update with Skip, Later, and Install and Relaunch, or a failure with OK and Retry.
private struct UpdatePopover: View {
    let model: UpdateModel
    let close: () -> Void
    @Environment(\.interfaceFontSize) private var fontSize

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.state {
            case .available(let offer): available(offer)
            case .failed(let message): failure(message)
            case .idle, .checking, .notFound: EmptyView()
            }
        }
        .frame(width: fontSize(300))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("update-popover")
    }

    private func available(_ offer: UpdateOffer) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Update Available")
                        .font(fontSize.font(13, weight: .semibold))
                    VStack(alignment: .leading, spacing: 4) {
                        detail("Version", offer.version, id: "update-version")
                        if let size = offer.sizeText { detail("Size", size, id: "update-size") }
                        if let released = offer.releasedText { detail("Released", released, id: "update-released") }
                    }
                    .textSelection(.enabled)
                }
                HStack(spacing: 8) {
                    Button("Skip") { close(); model.skip() }
                        .accessibilityIdentifier("update-skip")
                    Button("Later") { close(); model.later() }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("update-later")
                    Spacer()
                    Button("Install and Relaunch") { close(); model.install() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("update-install")
                }
                .controlSize(fontSize.systemControlSize(at: .small))
                .font(fontSize.font(11))
            }
            .padding(16)
            if let notes = offer.notes, let title = offer.notesTitle {
                Divider()
                Link(destination: notes) {
                    HStack {
                        Image(systemName: "doc.text")
                            .font(fontSize.font(11))
                        Text(title)
                            .font(fontSize.font(11, weight: .medium))
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(fontSize.font(10))
                    }
                    .foregroundStyle(.primary)
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title)
                .accessibilityValue(notes.absoluteString)
                .accessibilityIdentifier("update-notes")
            }
        }
    }

    private func detail(_ label: String, _ value: String, id: String) -> some View {
        HStack(spacing: 6) {
            Text("\(label):")
                .foregroundStyle(.secondary)
                .frame(width: fontSize(60), alignment: .trailing)
            Text(value)
                .accessibilityLabel(label)
                .accessibilityIdentifier(id)
        }
        .font(fontSize.font(11))
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(fontSize.font(13))
                    Text("Update Failed")
                        .font(fontSize.font(13, weight: .semibold))
                }
                Text(message)
                    .font(fontSize.font(11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("update-failure-message")
            }
            HStack(spacing: 8) {
                Button("OK") { close(); model.dismissFailure() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("update-ok")
                Spacer()
                Button("Retry") { close(); model.retry() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("update-retry")
            }
            .controlSize(fontSize.systemControlSize(at: .small))
            .font(fontSize.font(11))
        }
        .padding(16)
    }
}
