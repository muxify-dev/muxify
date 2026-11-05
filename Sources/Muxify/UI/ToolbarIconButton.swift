import SwiftUI

/// Browser toolbar control. Its symbol and its square grow with the Interface font size (ADR 0067).
struct ToolbarIconButton: View {
    /// The button's side at 12.
    static let designSide: CGFloat = 26

    let systemName: String
    let help: String
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.interfaceFontSize) private var fontSize

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(fontSize.font(13, weight: .medium))
                .frame(width: fontSize(Self.designSide), height: fontSize(Self.designSide))
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(hovering && isEnabled ? Color.primary.opacity(0.08) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEnabled ? .secondary : .quaternary)
        .onHover { hovering = $0 }
        .help(help)
    }
}
