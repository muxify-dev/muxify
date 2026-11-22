import SwiftUI
import MuxifyCore

/// The Open Place page (ADR 0095), in the Terminal's place as the Empty Topic page is: a search field and the Topics
/// that can fill the Open Place, each drawn with the pieces of its Sidebar card. A click on a row, or ↩ on the selected
/// row, fills the place and opens the Topic. SwiftUI draws it, as it draws the Command Palette's list: the list neither
/// animates nor drags (ADR 0083).
struct OpenPlacePageView: View {
    let store: WorkspaceStore
    @Bindable var page: OpenPlacePage
    @FocusState private var fieldFocused: Bool
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.interfaceFontSize) private var fontSize

    var body: some View {
        let choices = store.openPlaceChoices
        let selected = choices.selected(page.selectedID)?.id
        VStack(alignment: .leading, spacing: 12) {
            header(choices)
            TextField("Find a Topic", text: $page.query)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .accessibilityIdentifier("open-place-search")
            if choices.total == 0 {
                emptyState
            } else if choices.choices.isEmpty {
                Text("No Topic matches ‘\(page.query)’")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("open-place-no-match")
            } else {
                list(choices, selected: selected)
            }
        }
        .font(fontSize.font(.body))
        .controlSize(fontSize.systemControlSize)
        .frame(maxWidth: fontSize(560))
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: store.theme?.background ?? .windowBackgroundColor))
        .environment(\.colorScheme, store.theme.map { $0.isDark ? .dark : .light } ?? systemColorScheme)
        .environment(\.sidebarTypography, SidebarTypography(fontSize: fontSize, fontFamily: store.config.sidebarFontFamily))
        .environment(\.wrapsCardTitles, store.config.sidebar.wrapsTitles)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("open-place-page")
        .onAppear(perform: consumeFocusRequest)
        .onChange(of: page.fieldFocusRequested) { _, _ in consumeFocusRequest() }
        .onChange(of: fieldFocused) { _, focused in page.fieldHasFocus = focused }
        .onDisappear { page.fieldHasFocus = false }
    }

    private func header(_ choices: OpenPlaceChoices) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(store.locationTitle ?? "Open Place").font(fontSize.font(.title2, weight: .semibold))
                .accessibilityIdentifier("open-place-title")
            Text(page.query.isEmpty || choices.total == 0 ? "Choose what takes this place"
                 : "\(choices.choices.count) of \(choices.total) Topics")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("open-place-count")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No Guest Topics or Benched Topics").font(fontSize.font(.title3, weight: .semibold))
            Text("A new Topic is a Guest, so it shows here.").foregroundStyle(.secondary)
            Button("New Topic" + (store.config.keybinds.firstTrigger(for: .newTopic).map { " (\($0.symbol))" } ?? "")) {
                store.presentNewTopic()
            }
            .accessibilityIdentifier("open-place-new-topic")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("open-place-empty")
    }

    private func list(_ choices: OpenPlaceChoices, selected: String?) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(OpenPlaceChoices.Section.allCases, id: \.self) { section in
                        let rows = choices.choices(in: section)
                        if !rows.isEmpty {
                            Text(section.title)
                                .font(fontSize.font(11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.top, section == .guests ? 0 : 8)
                                .accessibilityIdentifier("open-place-section-" + section.title.lowercased())
                            ForEach(rows) { choice in
                                OpenPlaceRow(store: store, choice: choice, isSelected: choice.id == selected,
                                             listHasFocus: page.fieldHasFocus)
                                    .id(choice.id)
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .onChange(of: selected) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }

    private func consumeFocusRequest() {
        guard page.fieldFocusRequested else { return }
        page.fieldFocusRequested = false
        DispatchQueue.main.async { fieldFocused = true }
    }
}

/// One card that can fill the place, a Topic or a Board Session, drawn as its closed Sidebar card: the title, the Tags,
/// the Topic Note and the summary of its Sessions, with the Agent mark on its spine. The selected row is tinted in the accent colour while the
/// search field has Focus, and in grey without it, as a list without Focus shows its selection on macOS.
private struct OpenPlaceRow: View {
    let store: WorkspaceStore
    let choice: OpenPlaceChoices.Choice
    let isSelected: Bool
    let listHasFocus: Bool
    @Environment(\.interfaceFontSize) private var fontSize

    private var row: BoardModel.Row { choice.row }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        let formatted = store.cardText(row)
        let tags = store.cardTags(row).map { CardTags(placement: $0.placement, items: $0.items, identifier: "open-place-" + $0.identifier) }
        Button { store.fillOpenPlaceFromPage(with: choice.card) } label: {
            VStack(alignment: .leading, spacing: 0) {
                CardHeader(title: choice.title.text, isOpen: false, mark: row.mark, isGuest: row.isGuest,
                           isBoardSession: row.id.isBoardSession,
                           notes: (row.isGuest ? ["Guest"] : []) + (row.idleLabel.map { [$0] } ?? []),
                           summary: formatted.summary, tags: tags, note: choice.note?.text,
                           titleMarks: choice.title.marks, noteMarks: choice.note?.marks ?? []) {
                    if let label = row.idleLabel { Text(label).font(fontSize.font(10)).foregroundStyle(.secondary) }
                }
                if !choice.matchedSessions.isEmpty {
                    matchedSessions.padding(.leading, 13).padding(.trailing, 10).padding(.bottom, 7)
                }
            }
            .cardTagsOverlay(tags) { store.fillOpenPlaceFromPage(with: choice.card) }
            .opacity(row.state == .dormant || row.state == .empty ? 0.55 : 1)
            .background {
                if isSelected { shape.fill(listHasFocus ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.18)) }
            }
            .overlay(alignment: .leading) {
                if let mark = row.mark {
                    RowMarkSpine(mark: mark).frame(width: 3).padding(.vertical, 8).padding(.leading, 4).allowsHitTesting(false)
                }
            }
            .overlay { shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1).allowsHitTesting(false) }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .takesFirstClick()
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(choice.title.text)
        .accessibilityAction { store.fillOpenPlaceFromPage(with: choice.card) }
        .accessibilityValue(isSelected ? "selected" : "")
        .accessibilityIdentifier("open-place-row-" + row.id.accessibilityID)
    }

    /// The Sessions whose names the query matched, which the card shows only in its summary.
    private var matchedSessions: some View {
        let text = choice.matchedSessions.reduce(AttributedString()) { line, name in
            line + (line.characters.isEmpty ? AttributedString() : AttributedString(" · ")) + name.attributed
        }
        return Text(text).font(fontSize.font(11)).foregroundStyle(.secondary).lineLimit(1)
    }
}
