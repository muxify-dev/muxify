import SwiftUI
import MuxifyCore

/// Hosts the Command Palette and its "Copied" pill over the App Window.
struct CommandPaletteOverlay: View {
    let palette: CommandPalette

    var body: some View {
        // Fills the App Window even with nothing shown, so the pill gets its
        // width and sits at the bottom.
        GeometryReader { proxy in
            ZStack {
                if palette.isOpen {
                    SpotlightPalette(palette: palette)
                        .transition(.opacity)
                }
                VStack {
                    if let copied = palette.copied {
                        CopiedPill(copied: copied, theme: palette.theme)
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.7, anchor: .bottom).combined(with: .opacity),
                                removal: .opacity
                            ))
                            .id(copied.id)
                    }
                }
                .frame(width: SpotlightPalette.width(in: proxy.size))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 28)
                .allowsHitTesting(false)
            }
        }
    }
}

/// Like macOS 26 Spotlight: a glass bar near the top that grows as results
/// come in, with the actions in a menu that opens by the selected row.
private struct SpotlightPalette: View {
    @Bindable var palette: CommandPalette
    @FocusState private var focused: Bool
    @Environment(\.agentColors) private var agentColors

    private let rowHeight: CGFloat = 52
    private let fieldFont = Font.system(size: 24)

    static func width(in size: CGSize) -> CGFloat { min(700, size.width - 48) }

    var body: some View {
        let theme = palette.theme
        let results = palette.results
        let selected = palette.selected(in: results)
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { palette.close() }
                VStack(spacing: 0) {
                    if let breadcrumb = palette.breadcrumb {
                        Text(breadcrumb).font(.system(size: 13, weight: .medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20).padding(.top, 14)
                            .accessibilityIdentifier("palette-breadcrumb")
                    }
                    field(selected)
                    Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1).padding(.horizontal, 20)
                    if palette.flow == nil { sourceButtons(selected: selected) }
                    else { flowControls(selected) }
                    if !results.rows.isEmpty {
                        list(results, selected: selected, theme: theme)
                    } else if !palette.query.isEmpty && !palette.acceptsText {
                        Text("No Results")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                    }
                    if let note = palette.stepNote {
                        Text(note).font(.system(size: 12)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20).padding(.vertical, 8)
                            .accessibilityIdentifier("palette-note")
                    }
                    if palette.flow != nil { flowFooter }
                }
                .padding(.bottom, results.rows.isEmpty ? 2 : 10)
                .frame(width: Self.width(in: proxy.size))
                .spotlightGlass(theme)
                .overlayPreferenceValue(SelectedRowBounds.self) { anchor in
                    if palette.showsActions, let anchor, let selected {
                        GeometryReader { panel in
                            actionsMenu(selected, theme: theme)
                                .padding(.trailing, 16)
                                .frame(width: panel.size.width, alignment: .trailing)
                                .offset(y: panel[anchor].maxY + 2)
                        }
                    }
                }
                .padding(.top, max(24, proxy.size.height * 0.13))
            }
        }
        // The Sidebar's label colors, which read better on glass than the
        // Ghostty foreground (Solarized's is a mid gray).
        .foregroundStyle(.primary)
        .environment(\.colorScheme, theme.colorScheme)
        .onAppear { focusField() }
        .onChange(of: palette.invocation) { _, _ in focusField() }
    }

    private func focusField() {
        focused = true
        DispatchQueue.main.async {
            focused = true
            if palette.acceptsText, let field = palette.store?.terminalHost.window?.firstResponder as? NSTextView,
               field.isFieldEditor {
                field.setSelectedRange(NSRange(location: 0, length: field.string.utf16.count))
            }
        }
    }

    // MARK: Field

    private func field(_ selected: PickRow<PaletteItem>?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            ForEach(palette.fieldChips) { chip in
                FieldChipView(chip: chip, theme: palette.theme)
            }
            ZStack(alignment: .leading) {
                if !palette.acceptsText { ghost(selected) }
                TextField("", text: $palette.query, prompt: Text(palette.placeholder).foregroundColor(.secondary))
                    .textFieldStyle(.plain)
                    .font(fieldFont)
                    .focused($focused)
                    .accessibilityIdentifier("palette-search")
                    .accessibilityAction(named: "Close") { palette.close() }
                    .accessibilityAction(named: "Back") { palette.back() }
                    .accessibilityAction(named: "Accept") { palette.acceptSelected() }
                    .accessibilityAction(named: "Confirm") { palette.acceptSelected(commandReturn: true) }
                    .accessibilityAction(named: "Toggle Choice") { palette.toggleSelected() }
                    .accessibilityAction(named: "Space") { _ = palette.handleFlow(KeyTrigger(modifiers: [], key: .character(" "))) }
                    .accessibilityAction(named: "Check All Shown") { _ = palette.handleFlow(KeyTrigger(modifiers: .command, key: .character("a"))) }
                    // ← with the caret at the start of the text, →, and ⌫ and ⌦ on a chip.
                    .accessibilityAction(named: "Select Previous Chip") { palette.receiveChipKey(.left(caretAtStart: true)) }
                    .accessibilityAction(named: "Select Next Chip") { palette.receiveChipKey(.right) }
                    .accessibilityAction(named: "Select Next Row") { palette.move(1, in: palette.results) }
                    .accessibilityAction(named: "Remove Selected Chip Backward") {
                        if palette.fieldChips.contains(where: \.isSelected) { palette.receiveChipKey(.deleteBackward(textIsEmpty: palette.query.isEmpty)) }
                    }
                    .accessibilityAction(named: "Remove Selected Chip Forward") { palette.receiveChipKey(.deleteForward) }
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 62)
    }

    private func controlTitle(_ title: String, _ action: PaletteAction) -> String {
        palette.shortcut(for: action).map { title + " " + $0 } ?? title
    }

    @ViewBuilder private func flowControls(_ selected: PickRow<PaletteItem>?) -> some View {
        HStack(spacing: 8) {
            if case .move(let draft) = palette.flow {
                ForEach(Array(MoveDraft.Scope.allCases.enumerated()), id: \.element) { index, scope in
                    Button(controlTitle(scope.rawValue, [.choosePane, .chooseWindow, .chooseSession][index])) { palette.changeMoveScope(scope) }
                        .buttonStyle(.bordered)
                        .tint(draft.scope == scope ? .accentColor : .secondary)
                        .accessibilityIdentifier("palette-scope-" + scope.rawValue.lowercased())
                }
                if draft.scope == .pane, palette.store?.browser(for: draft.window.id).activeTab != nil {
                    Button(controlTitle(draft.includesTab ? "✓ Tab" : "＋ Tab", .toggleIncludeTab)) { palette.toggleTab() }
                        .accessibilityIdentifier("palette-include-tab")
                        .accessibilityValue(draft.includesTab ? "on" : "off")
                }
            }
            if case .addSession = palette.flow,
               case .choice(.sessionPath(let sessionPath)) = selected?.pick.payload?.ref, sessionPath.worktree != nil {
                Button(controlTitle((palette.newWorktree ? "✓ " : "") + "New Worktree", .toggleNewWorktree)) { palette.newWorktree.toggle() }
                    .buttonStyle(.bordered)
                    .tint(palette.newWorktree ? .accentColor : .secondary)
                    .accessibilityIdentifier("palette-new-worktree")
                    .accessibilityValue(palette.newWorktree ? "on" : "off")
            }
            if palette.canSuggestTitle {
                Button(controlTitle("Suggest title", .suggestTopicTitle)) { palette.suggestTitle() }
                    .accessibilityIdentifier("palette-suggest-title")
            }
            Spacer()
        }
        .font(.system(size: 12)).padding(.horizontal, 20).padding(.vertical, 6)
    }

    private var flowFooter: some View {
        HStack(spacing: 12) {
            if case .confirm = palette.flow { Text("Empty field: Space changes a row").foregroundStyle(.secondary) }
            if case .check = palette.flow { Text("Space or ⇥ checks a row · ⌘A checks all shown").foregroundStyle(.secondary) }
            Spacer()
            Button("Cancel · esc") { palette.close() }.accessibilityIdentifier("palette-cancel")
            Button(palette.requiresCommandReturn ? "Confirm · ⌘↩" : "Accept · ↩") {
                palette.acceptSelected(commandReturn: palette.requiresCommandReturn)
            }
            .accessibilityIdentifier("palette-accept")
            .disabled(!palette.canAccept)
        }
        .font(.system(size: 12)).padding(.horizontal, 20).padding(.vertical, 8)
    }

    /// Spotlight's completion after the caret: the rest of the selected title.
    private func ghost(_ selected: PickRow<PaletteItem>?) -> some View {
        let query = palette.query
        let title = selected?.title.text ?? ""
        return HStack(spacing: 0) {
            Text(query).hidden()
            if !query.isEmpty, selected != nil {
                if title.lowercased().hasPrefix(query.lowercased()) {
                    Text(title.dropFirst(query.count)).foregroundStyle(.secondary)
                } else {
                    Text(" – \(title)").foregroundStyle(.secondary)
                }
            }
        }
        .font(fieldFont)
        .lineLimit(1)
        .allowsHitTesting(false)
    }

    // MARK: Source buttons and results

    /// The Source buttons, on or off, and at the far end the way into the actions menu
    /// (whose first entry is Jump To).
    private func sourceButtons(selected: PickRow<PaletteItem>?) -> some View {
        HStack(spacing: 7) {
            ForEach(Array(palette.sourceButtons.enumerated()), id: \.element) { offset, source in
                let isOn = palette.selection.contains(source)
                Text(source.title)
                    .font(.system(size: 13))
                    .foregroundStyle(isOn ? Color.primary : Color.secondary)
                    .padding(.horizontal, 11)
                    .frame(height: 26)
                    .background(Capsule().fill(Color.primary.opacity(isOn ? 0.16 : 0.06)))
                    .contentShape(Capsule())
                    .onTapGesture { palette.toggleSource(source) }
                    .help("⌘\(offset + 1)")
            }
            Spacer()
            if selected != nil {
                HStack(spacing: 5) {
                    Text("Actions")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.showsActions ? Color.primary : Color.secondary)
                    if let shortcut = palette.shortcut(for: .showActions) { KeyCap(text: shortcut) }
                }
                .contentShape(Rectangle())
                .onTapGesture { palette.toggleActions(for: selected) }
            }
        }
        .frame(height: 26)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private func list(_ results: PickList<PaletteItem>, selected: PickRow<PaletteItem>?, theme: PaletteTheme) -> some View {
        let headers = results.sections.filter { $0.title != nil }.count
        let height = CGFloat(results.rows.count) * rowHeight + CGFloat(headers) * headerHeight
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(results.sections) { section in
                        if let title = section.title {
                            Text(title)
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                                .frame(height: headerHeight, alignment: .bottomLeading)
                                .accessibilityIdentifier("palette-section-" + section.id)
                        }
                        ForEach(section.rows) { row in
                            self.row(row, isSelected: row.id == selected?.id, theme: theme)
                                .id(row.id)
                                .onTapGesture { palette.perform(.jumpTo, on: row) }
                        }
                    }
                }
                .padding(.horizontal, 10)
            }
            .scrollIndicators(.never)
            // A half row shows there is more.
            .frame(height: min(height, 6.5 * rowHeight))
            .onChange(of: selected?.id) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }

    private let headerHeight: CGFloat = 24

    private func accessibilityLabel(_ row: PickRow<PaletteItem>) -> String {
        let parts: [String] = [row.mark?.rawValue ?? "", row.title.text] + row.tags.map(\.text.text) + [row.detail.text, row.trailing]
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// The title, then the Topic's Tags as chips. The title is cut off before a chip is.
    private func titleLine(_ row: PickRow<PaletteItem>, theme: PaletteTheme) -> some View {
        HStack(spacing: 6) {
            Text(row.title.attributed).font(.system(size: 15)).lineLimit(1)
            ForEach(row.tags, id: \.text.text) { tag in
                Text(tag.text.attributed)
                    .lineLimit(1)
                    .chip(color: tag.color?.color ?? theme.magenta, isSelected: false, theme: theme, size: 12, cornerRadius: 5)
                    .fixedSize()
            }
        }
    }

    private func row(_ row: PickRow<PaletteItem>, isSelected: Bool, theme: PaletteTheme) -> some View {
        let item = row.pick.payload
        let check = palette.rowCheck(row)
        return HStack(spacing: 12) {
            if let check { CheckBoxView(check: check) }
            if let item { PaletteIcon(source: .item(item), theme: theme) } else { Color.clear.frame(width: 32, height: 32) }
            VStack(alignment: .leading, spacing: 1) {
                titleLine(row, theme: theme)
                let detail = row.pick.reason.map(Highlighted.plain) ?? row.detail
                if !detail.text.isEmpty {
                    Text(detail.attributed).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            if let mark = row.mark { RowMarkView(mark: mark) }
            if let item, let status = item.status {
                Text(item.mark == .agent(.done) ? "Done · Unread" : status.rawValue.capitalized)
                    .font(.system(size: 12.5))
                    .foregroundStyle(item.mark.map { $0.color(agentColors) } ?? .secondary)
            } else if !row.trailing.isEmpty {
                Text(row.trailing).font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: rowHeight)
        .opacity(item == nil ? 0.45 : 1)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(isSelected ? 0.09 : 0)))
        .contentShape(Rectangle())
        .anchorPreference(key: SelectedRowBounds.self, value: .bounds) { isSelected ? $0 : nil }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("palette-row-" + row.id)
        .accessibilityLabel(accessibilityLabel(row))
        .accessibilityValue(row.pick.reason ?? [check?.box.accessibilityValue, isSelected ? "selected" : nil]
                                .compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default) { palette.perform(.jumpTo, on: row) }
        .accessibilityActions {
            ForEach(palette.actions(for: row), id: \.self) { action in
                Button(palette.title(of: action, for: row)) { palette.perform(action, on: row) }
            }
        }
    }

    // MARK: Actions

    private func actionsMenu(_ item: PickRow<PaletteItem>, theme: PaletteTheme) -> some View {
        let actions = palette.actions(for: item)
        return VStack(alignment: .leading, spacing: 1) {
            Text(item.title.text)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            ForEach(Array(actions.enumerated()), id: \.element) { offset, action in
                HStack(spacing: 9) {
                    PaletteIcon(source: .action(action), theme: theme, size: 20)
                    Text(palette.title(of: action, for: item)).font(.system(size: 13)).lineLimit(1)
                    Spacer(minLength: 12)
                    if let shortcut = palette.shortcut(for: action) {
                        Text(shortcut).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 6)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(offset == palette.actionIndex ? 0.1 : 0)))
                .contentShape(Rectangle())
                .onTapGesture { palette.perform(action, on: item) }
            }
        }
        .padding(6)
        .frame(width: 290)
        // Nearly opaque: the rows under it would show through as blobs.
        .spotlightGlass(theme, cornerRadius: 16, tint: 0.9)
    }
}

/// Where the selected row is, so the actions menu can open under it.
private struct SelectedRowBounds: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// App-icon sized: Agents and Windows as a little terminal with the
/// program's logo (and the Agent's Status as a badge), Topics as a diamond,
/// Sessions as a folder, SessionPaths as an empty folder and Worktrees as a
/// branch, actions as a tile in a theme color.
struct PaletteIcon: View {
    enum Source {
        case item(PaletteItem)
        case action(PaletteAction)
    }

    let source: Source
    let theme: PaletteTheme
    var size: CGFloat = 32

    var body: some View {
        let tile = RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
        switch source {
        case .item(let item) where item.kind == .session:
            Image(systemName: "folder.fill")
                .font(.system(size: size * 0.78))
                .foregroundStyle(theme.cyan.gradient)
                .frame(width: size, height: size)
        case .item(let item) where item.kind == .sessionPath || item.kind == .worktree:
            Image(systemName: item.kind == .worktree ? "arrow.triangle.branch" : "folder")
                .font(.system(size: size * (item.kind == .worktree ? 0.6 : 0.72)))
                .foregroundStyle(theme.cyan)
                .frame(width: size, height: size)
        case .item(let item) where item.kind == .tag:
            Image(systemName: "number")
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(item.color?.color ?? theme.magenta)
                .frame(width: size, height: size)
        case .item(let item) where [.topic, .snoozedTopic, .settledTopic].contains(item.kind):
            Image(systemName: topicSymbol(item))
                .font(.system(size: size * 0.6))
                .foregroundStyle(item.kind == .topic ? theme.magenta : Color.secondary)
                .frame(width: size, height: size)
        case .item(let item):
            tile.fill(theme.background)
                .overlay(tile.strokeBorder(Color.primary.opacity(0.14)))
                .overlay(Logo(name: item.logo ?? "terminal", size: size * 0.56))
                .frame(width: size, height: size)
                .overlay(alignment: .bottomTrailing) {
                    if let mark = item.mark {
                        RowMarkView(mark: mark, dotSize: size * 0.36)
                            .padding(mark == .agent(.working) ? 2 : 0)
                            .background {
                                if mark == .agent(.working) {
                                    RoundedRectangle(cornerRadius: 3).fill(theme.background)
                                }
                            }
                            .overlay {
                                if mark != .agent(.working) {
                                    Circle().strokeBorder(theme.background, lineWidth: 2)
                                }
                            }
                            .offset(x: size * 0.1, y: size * 0.1)
                    }
                }
        case .action(let action):
            tile.fill(color(action).gradient)
                .overlay(Image(systemName: symbol(action))
                    .font(.system(size: size * 0.44, weight: .semibold))
                    .foregroundStyle(.white))
                .frame(width: size, height: size)
        }
    }

    private func color(_ action: PaletteAction) -> Color {
        switch action {
        case .newSession: theme.green
        case .copyFolder: theme.cyan
        case .copyTmuxTarget: theme.magenta
        case .pasteFolder: theme.green
        case .snoozeTopic: theme.yellow
        default: theme.blue
        }
    }

    private func symbol(_ action: PaletteAction) -> String {
        switch action {
        case .newSession: "plus"
        case .copyFolder: "doc.on.doc.fill"
        case .copyTmuxTarget: "number"
        case .pasteFolder: "text.cursor"
        case .snoozeTopic: "moon.zzz.fill"
        default: "arrow.up.forward"
        }
    }

    /// Open, Dormant (no live Session), Snoozed or Settled.
    private func topicSymbol(_ item: PaletteItem) -> String {
        switch item.kind {
        case .snoozedTopic: return "moon.zzz"
        case .settledTopic: return "checkmark.circle"
        default:
            if case .topic(_, nil) = item.ref { return "diamond" }
            return "diamond.fill"
        }
    }
}

/// Springs in at the bottom after a Copy; its check is drawn on, then bounces
/// once.
private struct CopiedPill: View {
    let copied: PaletteCopy
    let theme: PaletteTheme
    @State private var showsCheck = false
    @State private var bounces = 0

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().fill(theme.green)
                if showsCheck { check }
            }
            .frame(width: 22, height: 22)
            Text(copied.title)
                .font(.system(size: 13, weight: .semibold))
            Text(copied.value)
                .font(.system(size: 12, design: .monospaced))
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
        .task {
            try? await Task.sleep(for: .milliseconds(120))
            withAnimation(.easeOut(duration: 0.3)) { showsCheck = true }
            try? await Task.sleep(for: .milliseconds(380))
            bounces += 1
        }
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

/// A Tag chip in the search field, in its Tag's colour. ⌫ in the empty field removes the last one, and ← selects one.
private struct FieldChipView: View {
    let chip: FieldChip
    let theme: PaletteTheme

    var body: some View {
        Text(chip.title).lineLimit(1)
            .chip(color: chip.color?.color ?? theme.magenta, isSelected: chip.isSelected, theme: theme, size: 17, cornerRadius: 7)
            // As wide as its text, up to one width for every chip; a cut-off title shows whole on hover.
            .frame(maxWidth: 180)
            .fixedSize()
            .help(chip.title)
            .accessibilityElement(children: .ignore)
            // A static text element carries its value into the accessibility tree, where a check reads the selection.
            .accessibilityAddTraits(.isStaticText)
            .accessibilityLabel(chip.title)
            .accessibilityValue(chip.isSelected ? "selected" : "")
            .accessibilityIdentifier(chip.id)
    }
}

/// The box of a check step's row: empty, a dash when some of a Tag's Topics are checked, a check mark when all are.
/// A Tag row's box has the Tag's colour, as its Tag Mark on a card has.
private struct CheckBoxView: View {
    let check: RowCheck

    var body: some View {
        let color = check.color?.color ?? Color.accentColor
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        ZStack {
            if check.box == .none {
                shape.strokeBorder(Color.secondary.opacity(0.7), lineWidth: 1.5)
            } else {
                shape.fill(color)
                Image(systemName: check.box == .all ? "checkmark" : "minus")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 16, height: 16)
    }
}

extension CheckBox {
    var accessibilityValue: String? {
        switch self {
        case .none: nil
        case .some: "partly checked"
        case .all: "checked"
        }
    }
}

private struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium, design: .rounded))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
    }
}

private extension View {
    /// The look of a chip, in the search field and after a row's title, so a Tag looks the same in both.
    func chip(color: Color, isSelected: Bool, theme: PaletteTheme, size: CGFloat, cornerRadius: CGFloat) -> some View {
        font(.system(size: size, weight: .medium))
            .foregroundStyle(isSelected ? theme.background : color)
            .padding(.horizontal, size * 0.53)
            .padding(.vertical, size * 0.18)
            .background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(isSelected ? color : color.opacity(0.16)))
    }

    /// Liquid Glass tinted with the Sidebar's chrome, or a material before macOS 26.
    @ViewBuilder
    func spotlightGlass(_ theme: PaletteTheme, cornerRadius: CGFloat = 26, tint: Double = 0.45) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            self
                .glassEffect(.regular.tint(theme.chrome.opacity(tint)), in: shape)
                .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
        } else {
            self
                .background(shape.fill(theme.chrome.opacity(tint + 0.1)))
                .background(shape.fill(.ultraThinMaterial))
                .clipShape(shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.12)))
                .shadow(color: .black.opacity(0.25), radius: 28, y: 12)
        }
    }
}
