import SwiftUI
import MuxifyCore

/// A search field over a ranked PickList: sections with headers, highlighted title and detail, a right
/// column, dimmed rows, and ↑↓↩ on the field. It does no matching; the list comes ranked.
struct SearchableSelect<Payload: Equatable>: View {
    /// A mode label left of the field, id "<prefix>-mode".
    var label: String? = nil
    let prompt: String
    var emptyMessage = "No matches"
    let list: PickList<Payload>
    var listHeight: CGFloat = 160
    var accessibilityPrefix = "sessionPath"
    var focusSearchOnAppear = false
    var acceptsOnClick = true
    @Binding var query: String
    @Binding var selection: String?
    /// Called only with an available row's payload.
    let onAccept: (Payload) -> Void
    @FocusState private var searching: Bool

    private var available: [PickRow<Payload>] { list.rows.filter { $0.pick.payload != nil } }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                if let label {
                    Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                        .accessibilityIdentifier(accessibilityPrefix + "-mode")
                }
                TextField(prompt, text: $query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier(accessibilityPrefix + "-search")
                    .focused($searching)
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.return) {
                        accept()
                        return .handled
                    }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if list.sections.isEmpty {
                            Text(emptyMessage).foregroundStyle(.secondary).padding(8)
                        }
                        ForEach(list.sections) { section in
                            if let title = section.title {
                                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    .padding(.horizontal, 6).padding(.top, 6)
                                    .accessibilityIdentifier(accessibilityPrefix + "-section-" + section.id)
                            }
                            ForEach(section.rows) { row in
                                Button {
                                    selection = row.id
                                    if acceptsOnClick { accept() }
                                } label: {
                                    rowLabel(row)
                                }
                                .buttonStyle(.plain)
                                .disabled(row.pick.reason != nil)
                                .opacity(row.pick.reason == nil ? 1 : 0.5)
                                .id(row.id)
                                .accessibilityIdentifier(accessibilityPrefix + "-" + row.id)
                                .accessibilityLabel([row.mark?.rawValue ?? "", row.title.text, row.detail.text, row.trailing].filter { !$0.isEmpty }
                                                        .joined(separator: ", "))
                                .accessibilityValue(row.pick.reason ?? (selection == row.id ? "selected" : ""))
                            }
                        }
                    }
                }
                .frame(height: listHeight)
                .onChange(of: selection) { _, value in
                    if let value { proxy.scrollTo(value) }
                }
            }
        }
        .onAppear { if focusSearchOnAppear { searching = true } }
        .onChange(of: query) { _, _ in selection = available.first?.id }
        .onChange(of: available.map(\.id), initial: true) { _, ids in
            if selection == nil || !ids.contains(where: { $0 == selection }) { selection = ids.first }
        }
    }

    private func rowLabel(_ row: PickRow<Payload>) -> some View {
        rowContent(row)
        .contentShape(Rectangle())
        .hoverLabel(detail: (row.pick.reason.map(Highlighted.plain) ?? row.detail).text, onlyWhenCutOff: true)
    }

    private func rowContent(_ row: PickRow<Payload>) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let symbol = row.symbol {
                Text(symbol).font(.caption).foregroundStyle(.secondary).frame(width: 14)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title.attributed).fontWeight(.medium).hoverLabelTitle()
                let detail = row.pick.reason.map(Highlighted.plain) ?? row.detail
                if !detail.text.isEmpty {
                    Text(detail.attributed).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !row.trailing.isEmpty {
                Text(row.trailing).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(6)
        .background(selection == row.id ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 4))
    }

    private func accept() {
        guard let payload = list.payload(of: selection) else { return }
        searching = false
        onAccept(payload)
    }

    private func move(_ delta: Int) {
        let available = available
        guard !available.isEmpty else { return }
        let current = available.firstIndex { $0.id == selection } ?? 0
        selection = available[min(max(current + delta, 0), available.count - 1)].id
    }
}
