import AppKit
import SwiftUI
import MuxifyCore

/// Hosts the Git View: a popup over the whole App Window, Sidebar and
/// Browser too, like `tmux display-popup`, or fullscreen in the terminal's
/// place.
struct GitViewOverlay: View {
    enum Placement { case window, terminal }

    let gitView: GitView
    let config: GitViewConfig
    let placement: Placement

    var body: some View {
        if gitView.isOpen {
            let colors = gitView.colors
            // Each Window's Git View is drawn afresh, with its own scroll
            // positions and focus.
            switch (config.display, placement) {
            case (.fullscreen, .terminal):
                GitNavigator(gitView: gitView, colors: colors)
                    .id(gitView.windowID)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("git-view")
            case (.popup, .window):
                GeometryReader { proxy in
                    ZStack {
                        Color.black.opacity(colors.isDark ? 0.35 : 0.16)
                            .contentShape(Rectangle())
                            .onTapGesture { gitView.close() }
                        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
                        GitNavigator(gitView: gitView, colors: colors)
                            .id(gitView.windowID)
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("git-view")
                            .clipShape(shape)
                            .overlay(shape.strokeBorder(Color(nsColor: colors.separator)))
                            .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
                            .frame(width: proxy.size.width * config.width, height: proxy.size.height * config.height)
                    }
                }
            default:
                EmptyView()
            }
        }
    }
}

/// The Git View's symbol, in the header and on a Sidebar Window whose Git
/// View is open: three commits, one branching off. Drawn from a 16×16 SVG
/// with a 1.5 stroke, in the foreground style.
struct GitViewIcon: View {
    var size: CGFloat = 14

    var body: some View {
        Outline()
            .stroke(style: StrokeStyle(lineWidth: size * 1.5 / 16, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
    }

    private struct Outline: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            for center in [CGPoint(x: 4.5, y: 3.5), CGPoint(x: 11.5, y: 3.5), CGPoint(x: 4.5, y: 12.5)] {
                path.addEllipse(in: CGRect(x: center.x - 1.75, y: center.y - 1.75, width: 3.5, height: 3.5))
            }
            path.move(to: CGPoint(x: 5.25, y: 8.25))
            path.addCurve(to: CGPoint(x: 11.25, y: 5.75), control1: CGPoint(x: 8.25, y: 8.25), control2: CGPoint(x: 11.25, y: 8.75))
            path.move(to: CGPoint(x: 4.75, y: 10.25))
            path.addLine(to: CGPoint(x: 4.75, y: 5.75))
            let scale = min(rect.width, rect.height) / 16
            return path.applying(CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: scale, y: scale))
        }
    }
}

/// The colors a Navigator view draws with, from the Ghostty theme.
private struct Palette {
    let colors: GitColors

    func color(_ color: NSColor) -> Color { Color(nsColor: color) }
    var background: Color { color(colors.background) }
    var chrome: Color { color(colors.chrome) }
    var code: Color { color(colors.code) }
    var dim: Color { color(colors.dim) }
    var separator: Color { color(colors.separator) }
    var softSeparator: Color { color(colors.softSeparator) }
    /// The file header bar: between the code's background and the chrome.
    var header: Color { color(colors.background.blended(withFraction: 0.45, of: colors.chrome) ?? colors.chrome) }
    var fill: Color { Color.primary.opacity(colors.isDark ? 0.055 : 0.045) }
    var fill2: Color { Color.primary.opacity(colors.isDark ? 0.09 : 0.075) }
    /// lazygit's green for staged, red for not.
    var staged: Color { color(colors.addedText) }
    var unstaged: Color { color(colors.removedText) }
}

/// Xcode's source control navigator, in the Ghostty theme: a toolbar, the
/// list pane with its Git View tabs, and the selection's diff.
private struct GitNavigator: View {
    @Bindable var gitView: GitView
    let colors: GitColors
    @Environment(\.interfaceFontSize) private var fontSize

    var body: some View {
        let palette = Palette(colors: colors)
        GeometryReader { proxy in
            VStack(spacing: 0) {
                if let snapshot = gitView.snapshot {
                    GitToolbar(gitView: gitView, snapshot: snapshot, palette: palette, isCompact: proxy.size.width < fontSize(900))
                    HStack(spacing: 0) {
                        GitListPane(gitView: gitView, palette: palette)
                            .frame(width: GitListMetrics.paneWidth(in: proxy.size.width, size: fontSize))
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("git-list-pane")
                            .background(palette.chrome)
                            .overlay(alignment: .trailing) { palette.separator.frame(width: 1) }
                        GitDiffPane(gitView: gitView, palette: palette)
                    }
                } else {
                    placeholder(palette)
                }
            }
        }
        .background(palette.background)
        .overlay(alignment: .bottom) {
            if let message = gitView.writeError {
                GitWriteErrorBanner(gitView: gitView, message: message, palette: palette)
            }
        }
        .overlay {
            ZStack {
                if gitView.isCommitOpen, let snapshot = gitView.snapshot {
                    GitCommitBox(gitView: gitView, snapshot: snapshot, palette: palette)
                        .transition(.opacity)
                }
                if let menu = gitView.menu {
                    GitMenuView(gitView: gitView, menu: menu, palette: palette)
                        .transition(.opacity)
                }
                if let prompt = gitView.prompt {
                    GitPromptView(gitView: gitView, prompt: prompt, palette: palette)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: gitView.isCommitOpen)
            .animation(.easeOut(duration: 0.15), value: gitView.menu != nil)
            .animation(.easeOut(duration: 0.15), value: gitView.prompt != nil)
        }
        .background(GitKeyCatcher(gitView: gitView))
        .environment(\.colorScheme, colors.isDark ? .dark : .light)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("git-view")
        // Each key, named by its Config spelling, so scripts/verify can press it without typing.
        .accessibilityActions {
            ForEach(GitView.keyMap.map(\.0), id: \.self) { name in
                Button { gitView.performKey(named: name) } label: { Text(verbatim: name) }
            }
        }
    }

    private func placeholder(_ palette: Palette) -> some View {
        VStack(spacing: 10) {
            if let error = gitView.error {
                Image(systemName: "exclamationmark.triangle")
                    .font(fontSize.font(28, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(error)
                    .font(fontSize.font(13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                Button("Close") { gitView.close() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(fontSize.systemControlSize)
            } else {
                ProgressView().controlSize(.small)
                Text("Reading \(Paths.tildify(gitView.folder, home: gitView.store?.homeDirectory ?? Paths.home))…")
                    .font(fontSize.font(13))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.background)
        .contentShape(Rectangle())
        .onTapGesture { gitView.focusKeyView() }
    }
}

// MARK: - Toolbar

private struct GitToolbar: View {
    @Bindable var gitView: GitView
    let snapshot: GitSnapshot
    let palette: Palette
    let isCompact: Bool
    @FocusState private var filterFocused: Bool
    @Environment(\.interfaceFontSize) private var fontSize

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "folder").font(fontSize.font(13)).foregroundStyle(.secondary)
                Text(snapshot.repositoryName).font(fontSize.font(13, weight: .semibold))
            }
            .lineLimit(1)
            if !isCompact {
                if snapshot.worktreeName != nil {
                    GitTag(text: "linked worktree", symbol: "rectangle.split.2x1", style: .tint(palette.colors.cyan), palette: palette)
                }
                if snapshot.upstream == nil, !snapshot.isDetached {
                    GitTag(text: "no upstream", symbol: "cloud", style: .gray, palette: palette)
                }
            }
            if let title = snapshot.operationTitle {
                GitTag(text: title, symbol: Self.symbol(for: snapshot.operation), style: .tint(palette.colors.yellow), palette: palette)
                    .help(snapshot.operation?.commitBlock ?? "\(title): m continues or aborts it.")
            }
            if let comparison = snapshot.comparison { aheadBehind(comparison) }
            if let text = comparingText {
                GitTag(text: text, symbol: "arrow.left.arrow.right", style: .tint(palette.colors.magenta), palette: palette)
                    .help("W on the base, or ⎋, ends the comparison")
            }
            if let text = copiedText {
                GitTag(text: text, symbol: "doc.on.doc", style: .tint(palette.colors.cyan), palette: palette)
                    .help("V cherry-picks the copied commits onto the branch you're on; ⌃R forgets them")
            }
            Spacer(minLength: 8)
            filterField
            Picker("Diff layout", selection: $gitView.layout) {
                Text("Unified").tag(GitView.Layout.unified)
                Text("Split").tag(GitView.Layout.split)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(fontSize.systemControlSize)
            .fixedSize()
            .help("Show the diff unified or side by side")
            ForEach(gitView.networkActivity, id: \.self) { activity in
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(activity).font(fontSize.font(11.5, weight: .medium)).foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .fixedSize()
            }
            if gitView.isReading || gitView.isWriting {
                ProgressView().controlSize(.small).frame(width: fontSize(28), height: fontSize(28))
            } else {
                GitIconButton(symbol: "arrow.clockwise", help: "Refresh (R)") { gitView.refresh(showingProgress: true) }
            }
            GitIconButton(symbol: "xmark", help: closeHelp) { gitView.close() }
        }
        .padding(.horizontal, 12)
        .frame(height: fontSize(48))
        .background(palette.chrome)
        .overlay(alignment: .bottom) { palette.separator.frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("git-toolbar")
        .accessibilityLabel(shownText)
    }

    /// The text the toolbar shows, for the accessibility label.
    private var shownText: String {
        var parts = [snapshot.repositoryName]
        if snapshot.worktreeName != nil { parts.append("linked worktree") }
        if snapshot.upstream == nil, !snapshot.isDetached { parts.append("no upstream") }
        if let title = snapshot.operationTitle { parts.append(title) }
        if let comparison = snapshot.comparison { parts.append("↑\(comparison.ahead) ↓\(comparison.behind) vs \(comparison.base)") }
        if let text = comparingText { parts.append(text) }
        if let text = copiedText { parts.append(text) }
        parts += gitView.networkActivity
        return parts.joined(separator: " · ")
    }

    /// W: "Comparing main", and "main → 1a2b3c4" while something else is
    /// selected.
    private var comparingText: String? {
        guard let base = gitView.base else { return nil }
        return gitView.compared.map { "\(base.name) → \($0.name)" } ?? "Comparing \(base.name)"
    }

    /// C: "2 copied", while commits are copied.
    private var copiedText: String? {
        let count = gitView.copiedCommits.count
        return count == 0 ? nil : "\(count) copied"
    }

    private static func symbol(for operation: GitOperation?) -> String {
        operation?.symbol ?? "magnifyingglass"
    }

    private var closeHelp: String {
        let trigger = gitView.store?.config.keybinds.firstTrigger(for: .toggleGitView)
        return trigger.map { "Close (q, \($0.symbol))" } ?? "Close (q)"
    }

    private func aheadBehind(_ comparison: GitComparison) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.up").font(fontSize.font(9, weight: .bold))
            Text(verbatim: "\(comparison.ahead)")
            Image(systemName: "arrow.down").font(fontSize.font(9, weight: .bold)).padding(.leading, 3)
            Text(verbatim: "\(comparison.behind)")
            if !isCompact {
                Text("vs \(comparison.base)").font(fontSize.font(11, weight: .medium)).foregroundStyle(.tertiary).padding(.leading, 4)
            }
        }
        .font(fontSize.font(11, weight: .semibold))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .frame(height: fontSize(19))
        .background(Capsule().fill(palette.fill2))
        .help("Commits ahead of and behind \(comparison.base)")
    }

    private var filterPrompt: String {
        switch gitView.list {
        case .changes: "Filter changes"
        case .history, .branch: "Filter commits"
        case .branches: "Filter branches"
        case .stashes: "Filter stashes"
        case .files: "Filter files"
        }
    }

    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(fontSize.font(13)).foregroundStyle(.tertiary)
            TextField("", text: $gitView.filter, prompt: Text(filterPrompt).foregroundColor(.secondary))
                .textFieldStyle(.plain)
                .font(fontSize.font(13))
                .focused($filterFocused)
                .onSubmit { gitView.filterDidEnd() }
            if !gitView.filter.isEmpty {
                Button { gitView.filter = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(fontSize.font(12)).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .frame(minWidth: fontSize(140), idealWidth: fontSize(230), maxWidth: fontSize(230))
        .frame(height: fontSize(28))
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(palette.fill))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(palette.softSeparator, lineWidth: 0.5))
        .help("Filter (/)")
        .onChange(of: filterFocused) { _, focused in
            if focused { gitView.isFiltering = true } else if gitView.isFiltering { gitView.filterDidEnd() }
        }
        .onChange(of: gitView.wantsFilterFocus) { _, wants in
            guard wants else { return }
            gitView.wantsFilterFocus = false
            filterFocused = true
        }
        .onChange(of: gitView.isFiltering) { _, filtering in
            if !filtering { filterFocused = false }
        }
    }
}

// MARK: - List pane

/// One tab at a time: its list, the Diff files of the selected commit or
/// stash under it, and the tabs along the bottom.
private struct GitListPane: View {
    let gitView: GitView
    let palette: Palette
    @Environment(\.interfaceFontSize) private var fontSize

    var body: some View {
        let listLevel = gitView.listLevel
        let filesLevel = gitView.filesLevel
        // The list above the Diff files takes what its rows need, up to
        // half; neither resizes when the keys move between them or through
        // the commits.
        let listNeeds = GitListMetrics.listHeight(rows: gitView.rows(for: listLevel).count, size: fontSize)
        VStack(spacing: 0) {
            GeometryReader { proxy in
                VStack(spacing: 0) {
                    VStack(spacing: 0) {
                        GitListHeader(gitView: gitView, level: listLevel, palette: palette)
                        GitListView(gitView: gitView, level: listLevel, palette: palette)
                            // Another list starts at its top, on its selection.
                            .id("\(gitView.tab.rawValue) \(listLevel.list.rawValue) \(listLevel.owner?.id ?? "")")
                    }
                    .frame(height: filesLevel == nil ? proxy.size.height : min(listNeeds, (proxy.size.height / 2).rounded()))
                    if let filesLevel {
                        VStack(spacing: 0) {
                            GitListHeader(gitView: gitView, level: filesLevel, palette: palette)
                            GitListView(gitView: gitView, level: filesLevel, palette: palette)
                                .id("files \(filesLevel.owner?.id ?? "")")
                        }
                        .frame(maxHeight: .infinity)
                        .overlay(alignment: .top) { palette.separator.frame(height: 1) }
                    }
                }
            }
            GitTabBar(gitView: gitView, palette: palette)
        }
    }
}

/// Above a list: its tab's name, the way back out of a branch and its
/// name, or the Diff files and whose they are; and how many items it has.
private struct GitListHeader: View {
    let gitView: GitView
    let level: GitView.Level
    let palette: Palette
    @Environment(\.interfaceFontSize) private var fontSize

    var body: some View {
        let hasKeys = level.list == gitView.list
        HStack(spacing: 6) {
            if level.list == .files {
                Image(systemName: "doc.on.doc")
                    .font(fontSize.font(11, weight: .semibold))
                    .foregroundStyle(hasKeys ? Color.accentColor : Color.secondary)
                    .frame(width: fontSize(16))
                    .padding(.leading, 4)
                Text("Diff files").font(fontSize.font(12, weight: .bold)).foregroundStyle(hasKeys ? Color.primary : Color.secondary)
                if let owner = level.owner { ownerLabel(owner) }
            } else if case .branch? = level.owner {
                Button { gitView.goBack(from: .branch) } label: {
                    Image(systemName: "chevron.left")
                        .font(fontSize.font(11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: fontSize(22), height: fontSize(22))
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(palette.fill2))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Back to Branches (⎋)")
                if let owner = level.owner { ownerLabel(owner) }
            } else {
                Text(gitView.tab.title)
                    .font(fontSize.font(12, weight: .bold))
                    .padding(.leading, 6)
            }
            Spacer(minLength: 4)
            Text(verbatim: "\(gitView.count(for: level))")
                .font(fontSize.font(11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .frame(height: fontSize(18))
                .background(Capsule().fill(palette.fill2))
        }
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .frame(height: fontSize(GitListMetrics.designHeaderHeight))
        .overlay(alignment: .bottom) { palette.softSeparator.frame(height: 1) }
    }

    /// The branch gone into, or the commit or stash the Diff files are of.
    @ViewBuilder
    private func ownerLabel(_ owner: GitView.Item) -> some View {
        HStack(spacing: 6) {
            switch owner {
            case .branch(let branch):
                Image(systemName: branch.isHead ? "checkmark" : "arrow.triangle.branch")
                    .font(fontSize.font(11, weight: .semibold))
                    .foregroundStyle(branch.isHead ? Color.accentColor : Color.secondary)
                Text(branch.name).font(fontSize.font(12, weight: .bold)).truncationMode(.middle)
            case .commit(let commit):
                Text(String(commit.sha.prefix(7))).font(fontSize.font(11, design: .monospaced)).foregroundStyle(.tertiary)
            case .stash(let stash):
                Text(stash.ref).font(fontSize.font(11, design: .monospaced)).foregroundStyle(.tertiary)
            default:
                EmptyView()
            }
        }
        .lineLimit(1)
    }
}

/// The Git View tabs along the list pane's bottom, with their keys. A
/// click on the tab shown goes back to its own list.
private struct GitTabBar: View {
    let gitView: GitView
    let palette: Palette
    @Environment(\.interfaceFontSize) private var fontSize

    private enum Style { case full, titles, symbols }

    var body: some View {
        // Titles go first when the list pane is narrow, then symbols.
        ViewThatFits(in: .horizontal) {
            bar(.full)
            bar(.titles)
            bar(.symbols)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) { palette.separator.frame(height: 1) }
    }

    private func bar(_ style: Style) -> some View {
        HStack(spacing: 2) {
            ForEach(GitTab.allCases) { tab in button(tab, style: style) }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(palette.fill2))
    }

    private func button(_ tab: GitTab, style: Style) -> some View {
        let isSelected = gitView.tab == tab
        return Button { gitView.selectTab(tab) } label: {
            HStack(spacing: 5) {
                if style != .titles {
                    Image(systemName: tab.symbol)
                        .font(fontSize.font(11, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                }
                if style != .symbols {
                    Text(tab.title).font(fontSize.font(11.5, weight: isSelected ? .semibold : .medium))
                }
                if let badge = badge(tab) {
                    Text(verbatim: "\(badge)")
                        .font(fontSize.font(10, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .frame(height: fontSize(15))
                        .background(Capsule().fill(palette.fill2))
                }
            }
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
            .frame(height: fontSize(24))
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(palette.background)
                        .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(tab.title) (\(tab.key))")
        .accessibilityIdentifier("git-tab-\(tab.rawValue)")
        .accessibilityValue(isSelected ? "selected" : "")
    }

    /// The changes and stashes there are.
    private func badge(_ tab: GitTab) -> Int? {
        let count = switch tab {
        case .changes: gitView.snapshot?.changes.count ?? 0
        case .stashes: gitView.snapshot?.stashes.count ?? 0
        case .history, .branches: 0
        }
        return count > 0 ? count : nil
    }
}

/// A list's rows; the History's and a branch's with their graph.
private struct GitListView: View {
    let gitView: GitView
    let level: GitView.Level
    let palette: Palette
    @Environment(\.interfaceFontSize) private var fontSize

    private var lane: CGFloat { fontSize(GitListMetrics.designLane) }

    var body: some View {
        let rows = gitView.rows(for: level)
        let selection = level.selection
        let hasKeys = gitView.focus == .list && level.list == gitView.list
        let lanes = min(8, rows.compactMap { $0.graph?.width }.max() ?? 0)
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        rowView(row, isSelected: row.item != nil && row.item?.id == selection, hasKeys: hasKeys,
                                graphWidth: CGFloat(lanes) * lane)
                    }
                }
                .padding(6)
            }
            .scrollIndicators(.automatic)
            .accessibilityIdentifier("git-list-\(level.list.rawValue)")
            .onChange(of: selection) { _, id in
                if let id { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) } }
            }
            .onAppear {
                if let selection { proxy.scrollTo(selection, anchor: .center) }
            }
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func rowView(_ row: GitView.Row, isSelected: Bool, hasKeys: Bool, graphWidth: CGFloat) -> some View {
        if let item = row.item {
            let onAccent = isSelected && hasKeys
            itemRow(item, row: row, onAccent: onAccent, graphWidth: graphWidth)
                .padding(.leading, 6 + CGFloat(row.depth) * 14)
                .padding(.trailing, 8)
                .frame(height: GitListMetrics.rowHeight(fontSize))
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(onAccent ? Color.accentColor : Color.primary.opacity(0.1))
                    }
                }
                .foregroundStyle(onAccent ? Color.white : Color.primary)
                .environment(\.gitOnAccent, onAccent)
                .contentShape(Rectangle())
                .onTapGesture { gitView.select(item, in: level) }
                // A click selects the row also while the App Window is not key, as the Sidebar's rows do.
                .takesFirstClick()
                .accessibilityElement(children: .ignore)
                // An element with a role carries its value into the accessibility tree, where a check reads it.
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("git-row-\(item.id)")
                .accessibilityLabel(accessibilityName(item, row: row))
                .accessibilityValue(accessibilityValue(item, isSelected: isSelected, level: level))
                .id(row.id)
        } else {
            Text(row.text)
                .font(fontSize.font(12))
                .foregroundStyle(.tertiary)
                .padding(.leading, 14)
                .frame(height: fontSize(GitListMetrics.designNoteHeight))
                .id(row.id)
        }
    }

    private func accessibilityName(_ item: GitView.Item, row: GitView.Row) -> String {
        switch item {
        case .change(let change): change.name
        case .folder: row.text
        case .commit(let commit): commit.subject
        case .stash(let stash): GitNavigatorText.stashTitle(stash.message)
        case .branch(let branch): branch.name
        case .file(let path): (path as NSString).lastPathComponent
        }
    }

    /// `selected=1 status="M "`: whether the row is the selection, and a
    /// change's or file's two status letters; ` base=1` on the base, ` copied=1` on a copied commit.
    private func accessibilityValue(_ item: GitView.Item, isSelected: Bool, level: GitView.Level) -> String {
        let status: String? = switch item {
        case .change(let change): String(change.index) + String(change.worktree)
        case .file(let path): Self.letter(gitView.ownerFiles(for: level)?.first { $0.path == path }?.change).text
        case .folder, .commit, .stash, .branch: nil
        }
        let copied: Bool = if case .commit(let commit) = item { gitView.isCopied(commit) } else { false }
        return "selected=\(isSelected ? 1 : 0)" + (status.map { " status=\"\($0)\"" } ?? "")
            + (item.id == gitView.base?.id ? " base=1" : "")
            + (copied ? " copied=1" : "")
    }

    @ViewBuilder
    private func itemRow(_ item: GitView.Item, row: GitView.Row, onAccent: Bool, graphWidth: CGFloat) -> some View {
        let secondary = onAccent ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(.tertiary)
        let mono = fontSize.font(11, design: .monospaced)
        HStack(spacing: 6) {
            switch item {
            case .folder(let tree, let path):
                let isOpen = gitView.collapsedFolders[tree]?.contains(path) != true || !gitView.filter.isEmpty
                Image(systemName: "chevron.right")
                    .font(fontSize.font(9, weight: .bold))
                    .foregroundStyle(secondary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .frame(width: fontSize(12), height: fontSize(20))
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.easeOut(duration: 0.12)) { gitView.toggleFolder(path, in: tree) } }
                Image(systemName: "folder.fill")
                    .font(fontSize.font(12))
                    .foregroundStyle(onAccent ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                Text(row.text).font(fontSize.font(13)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
            case .change(let change):
                Color.clear.frame(width: fontSize(12))
                status(change, onAccent: onAccent)
                GitFileTile(path: change.path, size: 15)
                Text(change.name)
                    .font(fontSize.font(13))
                    .foregroundStyle(onAccent ? Color.white : change.isStaged ? palette.staged : palette.unstaged)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                counts(change.additions, change.deletions, onAccent: onAccent)
            case .file(let path):
                let file = gitView.ownerFiles(for: level)?.first { $0.path == path }
                let letter = Self.letter(file?.change)
                Color.clear.frame(width: fontSize(12))
                Text(letter.text)
                    .font(fontSize.font(11.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(onAccent ? Color.white : palette.color(palette.colors.strong(letter.color(palette.colors))))
                    .frame(width: fontSize(12))
                GitFileTile(path: path, size: 15)
                Text((path as NSString).lastPathComponent).font(fontSize.font(13)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                counts(file?.isBinary == true ? nil : file?.additions, file?.deletions, onAccent: onAccent)
            case .commit(let commit):
                if let graph = row.graph {
                    GitGraphCell(row: graph, isMerge: commit.isMerge, palette: palette, lane: lane)
                        .frame(width: graphWidth, height: GitListMetrics.rowHeight(fontSize), alignment: .leading)
                        .clipped()
                }
                Text(String(commit.sha.prefix(7)))
                    .font(mono)
                    .foregroundStyle(onAccent ? Color.white.opacity(0.85) : palette.color(palette.colors.strong(Self.color(commit.status, palette.colors))))
                    .fixedSize()
                refs(commit, onAccent: onAccent)
                Text(commit.subject).font(fontSize.font(13)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                copiedMark(commit, onAccent: onAccent)
                baseMark(item, onAccent: onAccent)
                Text(GitRepository.age(of: commit.date)).font(fontSize.font(11)).foregroundStyle(secondary)
            case .stash(let stash):
                Text(stash.ref).font(mono).foregroundStyle(secondary)
                Text(GitNavigatorText.stashTitle(stash.message)).font(fontSize.font(13)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                baseMark(item, onAccent: onAccent)
                Text(GitRepository.age(of: stash.date)).font(fontSize.font(11)).foregroundStyle(secondary)
            case .branch(let branch):
                if branch.isHead {
                    Image(systemName: "checkmark")
                        .font(fontSize.font(11, weight: .bold))
                        .foregroundStyle(onAccent ? Color.white : Color.accentColor)
                        .frame(width: fontSize(15))
                } else {
                    Image(systemName: "arrow.triangle.branch").font(fontSize.font(12)).foregroundStyle(secondary).frame(width: fontSize(15))
                }
                Text(branch.name)
                    .font(fontSize.font(13, weight: branch.isHead ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                branchTags(branch, onAccent: onAccent)
                Spacer(minLength: 4)
                baseMark(item, onAccent: onAccent)
                if let date = branch.date {
                    Text(GitRepository.age(of: date)).font(fontSize.font(11)).foregroundStyle(secondary)
                }
                // A click goes into its commits.
                Image(systemName: "chevron.right").font(fontSize.font(10, weight: .bold)).foregroundStyle(secondary)
            }
        }
    }

    /// C copied it: V cherry-picks it onto the branch you're on.
    @ViewBuilder
    private func copiedMark(_ commit: GitCommit, onAccent: Bool) -> some View {
        if gitView.isCopied(commit) {
            GitTag(text: "copied", symbol: "doc.on.doc", style: .tint(palette.colors.cyan), palette: palette,
                   height: 16, fontSize: 10, onAccent: onAccent)
                .help("Copied: V cherry-picks it onto the branch you're on, C takes it out again")
        }
    }

    /// W marked it: the others are compared with it.
    @ViewBuilder
    private func baseMark(_ item: GitView.Item, onAccent: Bool) -> some View {
        if item.id == gitView.base?.id {
            GitTag(text: "base", symbol: "arrow.left.arrow.right", style: .tint(palette.colors.magenta), palette: palette,
                   height: 16, fontSize: 10, onAccent: onAccent)
                .help("The base: what's selected is compared with it (W)")
        }
    }

    /// Another worktree's branch, a gone upstream, and commits ahead of and
    /// behind the branch you're on.
    @ViewBuilder
    private func branchTags(_ branch: GitBranch, onAccent: Bool) -> some View {
        if branch.worktreePath != nil, !branch.isHead {
            GitTag(text: "worktree", symbol: "rectangle.split.2x1", style: .gray, palette: palette, height: 16, fontSize: 10, onAccent: onAccent)
        }
        if branch.track == "gone" {
            GitTag(text: "gone", style: .tint(palette.colors.red), palette: palette, height: 16, fontSize: 10, onAccent: onAccent)
                .help("Its upstream was deleted")
        }
        if !branch.isHead, branch.ahead > 0 || branch.behind > 0 {
            GitTag(text: "↑\(branch.ahead) ↓\(branch.behind)", style: .gray, palette: palette, height: 16, fontSize: 10, onAccent: onAccent)
                .help("\(branch.ahead) commits ahead of and \(branch.behind) behind the branch you're on")
        }
    }

    /// The first branch at a commit, else its first tag or remote branch,
    /// and how many more; the card lists them all.
    @ViewBuilder
    private func refs(_ commit: GitCommit, onAccent: Bool) -> some View {
        let all = commit.refs.map { ($0, palette.colors.green) } + commit.tags.map { ($0, palette.colors.yellow) }
            + commit.remotes.map { ($0, palette.colors.cyan) }
        if let first = all.first {
            GitTag(text: first.0, symbol: commit.refs.isEmpty && !commit.tags.isEmpty ? "tag" : nil, style: .tint(first.1),
                   palette: palette, height: 16, fontSize: 10, onAccent: onAccent)
                .help((commit.refs + commit.tags + commit.remotes).joined(separator: ", "))
            if all.count > 1 {
                GitTag(text: "+\(all.count - 1)", style: .gray, palette: palette, height: 16, fontSize: 10, onAccent: onAccent)
                    .help((commit.refs + commit.tags + commit.remotes).joined(separator: ", "))
            }
        }
    }

    /// `M ` green, ` M` red, `MM` both, `??` red: lazygit's letters. A
    /// click stages or unstages, as space does.
    private func status(_ change: GitChange, onAccent: Bool) -> some View {
        HStack(spacing: 0) {
            Text(String(change.index))
                .foregroundStyle(onAccent ? Color.white : change.isUntracked || change.isConflict ? palette.unstaged : palette.staged)
            Text(String(change.worktree))
                .foregroundStyle(onAccent ? Color.white : palette.unstaged)
        }
        .font(fontSize.font(11.5, weight: .bold, design: .monospaced))
        .frame(width: fontSize(16), height: fontSize(20), alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { gitView.toggleStaged(.change(change)) }
        .help(Self.statusHelp(change))
    }

    private static func statusHelp(_ change: GitChange) -> String {
        let state = change.isUntracked ? "Untracked" : change.isConflict ? "Conflict"
            : change.groups.map { $0 == .staged ? "Staged" : "Unstaged" }.joined(separator: " and ")
        return "\(state). Click, or space, to \(change.isStaged ? "unstage" : "stage") it."
    }

    @ViewBuilder
    private func counts(_ additions: Int?, _ deletions: Int?, onAccent: Bool) -> some View {
        HStack(spacing: 5) {
            if let additions {
                if additions > 0 {
                    Text(verbatim: "+\(additions)").foregroundStyle(onAccent ? Color.white.opacity(0.85) : palette.staged)
                }
                if let deletions, deletions > 0 {
                    Text(verbatim: "−\(deletions)").foregroundStyle(onAccent ? Color.white.opacity(0.85) : palette.unstaged)
                }
            } else {
                Text("bin").foregroundStyle(onAccent ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(.tertiary))
            }
        }
        .font(fontSize.font(11, design: .monospaced))
        .fixedSize()
    }

    /// A file of a commit: `A` added, `D` deleted, `M` modified, `R` renamed.
    static func letter(_ change: GitPatchFile.Change?) -> (text: String, color: (GitColors) -> NSColor) {
        switch change {
        case .added?: ("A", \.green)
        case .deleted?: ("D", \.red)
        case .renamed?: ("R", \.cyan)
        case .copied?: ("C", \.cyan)
        case .modified?, nil: ("M", \.yellow)
        }
    }

    /// lazygit's hashes: red until pushed, yellow until in main, then green.
    static func color(_ status: GitCommit.Status, _ colors: GitColors) -> NSColor {
        switch status {
        case .unpushed: colors.red
        case .pushed: colors.yellow
        case .merged: colors.green
        }
    }
}

/// A row of the History graph: lanes, curves where they fork and merge,
/// and the commit's dot, a ring for a merge.
private struct GitGraphCell: View {
    let row: GitGraphRow
    let isMerge: Bool
    let palette: Palette
    let lane: CGFloat
    @Environment(\.gitOnAccent) private var onAccent
    @Environment(\.interfaceFontSize) private var fontSize

    var body: some View {
        let colors = palette.colors
        let laneColors = [colors.blue, colors.magenta, colors.green, colors.yellow, colors.cyan, colors.red].map(palette.color)
        Canvas { context, size in
            func x(_ index: Int) -> CGFloat { lane * (CGFloat(index) + 0.5) }
            let middle = size.height / 2
            let style = StrokeStyle(lineWidth: 1.6, lineCap: .round)
            for edge in row.edges {
                let (from, to): (CGPoint, CGPoint) = switch edge.kind {
                case .through: (CGPoint(x: x(edge.lane), y: 0), CGPoint(x: x(edge.lane), y: size.height))
                case .into: (CGPoint(x: x(edge.lane), y: 0), CGPoint(x: x(row.lane), y: middle))
                case .out: (CGPoint(x: x(row.lane), y: middle), CGPoint(x: x(edge.lane), y: size.height))
                }
                var path = Path()
                path.move(to: from)
                if from.x == to.x {
                    path.addLine(to: to)
                } else {
                    let turn = (from.y + to.y) / 2
                    path.addCurve(to: to, control1: CGPoint(x: from.x, y: turn), control2: CGPoint(x: to.x, y: turn))
                }
                context.stroke(path, with: .color(laneColors[edge.color % laneColors.count]), style: style)
            }
            let radius = fontSize(4)
            let dot = Path(ellipseIn: CGRect(x: x(row.lane) - radius, y: middle - radius, width: 2 * radius, height: 2 * radius))
            let color = laneColors[row.color % laneColors.count]
            if isMerge {
                context.fill(dot, with: .color(onAccent ? Color.accentColor : palette.chrome))
                context.stroke(dot, with: .color(onAccent ? .white : color), lineWidth: 1.8)
            } else {
                context.fill(dot, with: .color(onAccent ? .white : color))
            }
        }
    }
}

enum GitNavigatorText {
    /// `On master: wip` → `wip`.
    static func stashTitle(_ message: String) -> String {
        guard message.hasPrefix("On ") || message.hasPrefix("WIP on "), let colon = message.range(of: ": ") else { return message }
        return String(message[colon.upperBound...])
    }

    /// What a file's bar says happened to it.
    static func kind(of file: GitPatchFile?, change: GitChange?, colors: GitColors) -> (title: String, color: NSColor)? {
        if change?.isUntracked == true || file?.group == .untracked { return ("Untracked", colors.green) }
        if change?.isConflict == true { return ("Conflict", colors.red) }
        switch file?.change {
        case .added?: return ("Added", colors.green)
        case .deleted?: return ("Deleted", colors.red)
        case .renamed?: return ("Renamed", colors.cyan)
        case .copied?: return ("Copied", colors.cyan)
        case .modified?: return ("Modified", colors.yellow)
        case nil: return nil
        }
    }

    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Diff pane

private struct GitDiffPane: View {
    @Bindable var gitView: GitView
    let palette: Palette
    @State private var isDragging = false
    /// The rows' width, which sets where long lines wrap.
    @State private var contentWidth: CGFloat = 0

    private static let space = "gitDiff"
    /// The code's size, which follows the Terminal; so do its gutters and hunk headers (`GitDiffMetrics.swift`).
    private var fontSize: CGFloat { gitView.fontSize }
    /// The Interface font size, for the diff's own text that is not code: its empty state, notes and bars.
    @Environment(\.interfaceFontSize) private var interfaceFontSize

    /// Code wraps every `columns` characters, so a character's place on
    /// screen follows from its offset.
    private var metrics: GitView.TextMetrics {
        GitView.TextMetrics(fontSize: fontSize, layout: gitView.layout, width: contentWidth > 0 ? contentWidth : gitView.diffWidth,
                            widestNumber: gitView.widestLineNumber)
    }

    var body: some View {
        let metrics = metrics
        VStack(spacing: 0) {
            if let header = gitView.fileHeader {
                GitFileHeader(gitView: gitView, header: header, palette: palette)
            }
            if gitView.diffRows.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(gitView.diffRows) { row in
                                rowView(row, metrics: metrics)
                            }
                        }
                        .scrollTargetLayout()
                        .background(GeometryReader { geometry in
                            Color.clear
                                .onAppear { contentWidth = geometry.size.width }
                                .onChange(of: geometry.size.width) { _, width in contentWidth = width }
                        })
                    }
                    .scrollPosition(id: $gitView.scrollRow, anchor: .top)
                    .scrollIndicators(.automatic)
                    .coordinateSpace(.named(Self.space))
                    .background(GeometryReader { geometry in
                        Color.clear
                            .onAppear { measure(geometry.size) }
                            .onChange(of: geometry.size) { _, size in measure(size) }
                    })
                    .onAppear {
                        gitView.textMetrics = metrics
                        // Its Window selected again: where it was left.
                        if let row = gitView.scrollRow { proxy.scrollTo(row, anchor: .top) }
                    }
                    // Keys moved the cursor out of sight: scroll just enough.
                    .onChange(of: metrics) { _, metrics in gitView.textMetrics = metrics }
                    .onChange(of: gitView.cursor?.row) { _, row in
                        guard let row, !isDragging else { return }
                        if let frame = gitView.lineFrames[row], frame.minY >= 0, frame.maxY <= gitView.diffHeight { return }
                        proxy.scrollTo(row)
                    }
                }
                .background(palette.background)
                .simultaneousGesture(TapGesture().onEnded {
                    if gitView.focus != .diff { gitView.setFocus(.diff) }
                })
            }
        }
        .overlay(alignment: .top) {
            // The diff has the keys: a hairline of accent under the header.
            if gitView.focus == .diff { Color.accentColor.frame(height: 2).opacity(0.7) }
        }
    }

    private func measure(_ size: CGSize) {
        gitView.diffHeight = size.height
        gitView.diffWidth = size.width
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            if gitView.list == .changes, gitView.snapshot?.changes.isEmpty == true {
                Image(systemName: "checkmark.circle").font(interfaceFontSize.font(28, weight: .light)).foregroundStyle(.tertiary)
                Text("Working tree clean").font(interfaceFontSize.font(13)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.background)
    }

    @ViewBuilder
    private func rowView(_ row: GitView.DiffRow, metrics: GitView.TextMetrics) -> some View {
        switch row.kind {
        case .card:
            if let content = gitView.content { GitCard(gitView: gitView, content: content, palette: palette) }
        case .file(let index):
            if let file = gitView.content?.patch.files.first(where: { $0.id == index }) {
                GitFileBar(file: file, palette: palette)
                    .padding(.top, row.id <= 1 ? 0 : 14)
            }
        case .part(let group):
            partBar(group)
        case .hunk(let fileIndex, let hunkIndex):
            if let hunk = gitView.content?.patch.files.first(where: { $0.id == fileIndex })?.hunks[hunkIndex] {
                hunkHeader(hunk, metrics: metrics)
            }
        case .line(let line):
            selectable(row, metrics: metrics) { unifiedLine(line, id: row.id, metrics: metrics) }
        case .pair(let old, let new):
            selectable(row, metrics: metrics) {
                HStack(spacing: 0) {
                    splitSide(old, number: old?.old, id: "\(row.id)-old", metrics: metrics)
                    palette.softSeparator.frame(width: 1)
                    splitSide(new, number: new?.new, id: "\(row.id)-new", metrics: metrics)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        case .binary:
            note("Binary file not shown")
        case .wholeFile:
            bar(symbol: "arrow.up.and.down.text.horizontal", text: "Show the whole file", metrics: metrics) { gitView.showWholeFile() }
        case .endOfFile:
            endOfFile
        case .omitted(let count):
            note("\(count) more lines not shown")
        case .message(let text):
            Text(text)
                .font(interfaceFontSize.font(13))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Selecting

    /// A line the mouse selects in: lines from the line numbers, code by
    /// the character, a word with a double click; on a split diff, on the
    /// side clicked.
    private func selectable<Line: View>(_ row: GitView.DiffRow, metrics: GitView.TextMetrics,
                                        @ViewBuilder line: () -> Line) -> some View {
        line()
            .overlay(alignment: .topLeading) { selection(row, metrics: metrics) }
            .contentShape(Rectangle())
            .onGeometryChange(for: CGRect.self) { geometry in
                geometry.frame(in: .named(Self.space))
            } action: { frame in
                gitView.lineFrames[row.id] = frame
            }
            .onDisappear { gitView.lineFrames[row.id] = nil }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            gitView.textMetrics = metrics
                            gitView.mouseDown(at: value.startLocation, row: row.id, clicks: Self.clicks(),
                                              extending: NSEvent.modifierFlags.contains(.shift))
                        }
                        gitView.mouseDragged(to: value.location)
                    }
                    .onEnded { _ in
                        isDragging = false
                        gitView.mouseUp()
                    }
            )
    }

    /// 2 for a double click; only a mouse event has a count.
    private static func clicks() -> Int {
        guard let event = NSApp.currentEvent, [.leftMouseDown, .leftMouseDragged, .leftMouseUp].contains(event.type) else { return 1 }
        return event.clickCount
    }

    @ViewBuilder
    private func selection(_ row: GitView.DiffRow, metrics: GitView.TextMetrics) -> some View {
        if let selection = gitView.selection(inRow: row.id) {
            GeometryReader { geometry in
                let isSplit = gitView.layout == .split
                let width = isSplit ? (geometry.size.width - 1) / 2 : geometry.size.width
                let left = isSplit && gitView.side == .new ? width + 1 : 0
                switch selection {
                case .whole:
                    Color.accentColor.opacity(0.2)
                        .overlay(alignment: .leading) { Color.accentColor.frame(width: 2) }
                        .frame(width: width)
                        .offset(x: left)
                case .characters(let range):
                    let length = gitView.line(at: row.id)?.shown.count ?? 0
                    Path { path in
                        for rect in Self.rects(for: range, length: length, metrics: metrics) {
                            path.addRect(rect.offsetBy(dx: left + metrics.codeX, dy: 0))
                        }
                    }
                    .fill(Color.accentColor.opacity(0.38))
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// The characters' boxes, a box per wrapped line; past the end, half a
    /// character for the line break.
    static func rects(for range: Range<Int>, length: Int, metrics: GitView.TextMetrics) -> [CGRect] {
        var rects: [CGRect] = []
        let wraps = max(0, (length - 1) / metrics.columns)
        var start = range.lowerBound
        while start < range.upperBound {
            let wrap = min(start / metrics.columns, wraps)
            let end = min(range.upperBound, (wrap + 1) * metrics.columns, max(length, start + 1))
            let width = start >= length ? 0.5 : CGFloat(end - start)
            rects.append(CGRect(x: CGFloat(start - wrap * metrics.columns) * metrics.charWidth, y: CGFloat(wrap) * metrics.lineHeight,
                                width: width * metrics.charWidth, height: metrics.lineHeight))
            start = max(end, start + 1)
        }
        return rects
    }

    // MARK: Lines

    private func codeFont(_ metrics: GitView.TextMetrics) -> Font { .system(size: metrics.fontSize, design: .monospaced) }

    private func unifiedLine(_ line: GitDiffLine, id: Int, metrics: GitView.TextMetrics) -> some View {
        lineView(line, id: "\(id)", metrics: metrics) {
            number(line.old, id: "\(id)-old", metrics: metrics)
            number(line.new, id: "\(id)-new", metrics: metrics)
        }
    }

    @ViewBuilder
    private func splitSide(_ line: GitDiffLine?, number value: Int?, id: String, metrics: GitView.TextMetrics) -> some View {
        Group {
            if let line {
                lineView(line, id: id, metrics: metrics) {
                    number(line.kind == .note ? nil : value, id: id, metrics: metrics)
                }
            } else {
                palette.fill
            }
        }
        .frame(maxWidth: .infinity, minHeight: metrics.lineHeight, maxHeight: .infinity, alignment: .topLeading)
    }

    /// A line: its code after the gutter, the line numbers and the marker over it. The line is one element, its code.
    /// The gutter is another, `git-gutter-<id>`, as wide as its columns, and each number one more, as wide as its text,
    /// so their frames show in a dump.
    private func lineView<Numbers: View>(_ line: GitDiffLine, id: String, metrics: GitView.TextMetrics,
                                         @ViewBuilder numbers: () -> Numbers) -> some View {
        code(line, metrics: metrics)
            .padding(.leading, metrics.codeX)
            .background {
                HStack(spacing: 0) {
                    band(line.kind, gutter: true).frame(width: metrics.gutterWidth)
                    band(line.kind, gutter: false)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isStaticText)
            .accessibilityIdentifier("git-line-\(id)")
            .accessibilityLabel(line.text)
            .accessibilityValue(line.accessibilityValue)
            .overlay(alignment: .topLeading) {
                HStack(spacing: 0) {
                    HStack(spacing: 0, content: numbers)
                        .background {
                            // An element of the gutter's own: one that contains the numbers is only as wide as they are.
                            Color.clear
                                .accessibilityElement()
                                .accessibilityIdentifier("git-gutter-\(id)")
                                .accessibilityLabel("Line numbers")
                        }
                    marker(line.kind, metrics: metrics)
                }
            }
    }

    private func number(_ value: Int?, id: String, metrics: GitView.TextMetrics) -> some View {
        Text(value.map(String.init) ?? "")
            .font(.system(size: GitView.TextMetrics.numberSize(metrics.fontSize), design: .monospaced))
            .foregroundStyle(palette.dim)
            .lineLimit(1)
            .accessibilityIdentifier("git-number-\(id)")
            .accessibilityHidden(value == nil)
            .padding(.trailing, metrics.numberPadding)
            .frame(width: metrics.numberWidth, height: metrics.lineHeight, alignment: .trailing)
    }

    private func marker(_ kind: GitDiffLine.Kind, metrics: GitView.TextMetrics) -> some View {
        Text(kind == .added ? "+" : kind == .removed ? "−" : " ")
            .font(codeFont(metrics))
            .foregroundStyle(kind == .added ? palette.color(palette.colors.addedText) : palette.color(palette.colors.removedText))
            .frame(width: metrics.markerWidth, height: metrics.lineHeight)
            .accessibilityHidden(true)
    }

    /// The code, a line of `columns` characters at a time.
    private func code(_ line: GitDiffLine, metrics: GitView.TextMetrics) -> some View {
        let text = line.kind == .note ? AttributedString(line.shown) : line.styled ?? AttributedString(line.shown)
        let wraps = max(1, (line.shown.count + metrics.columns - 1) / metrics.columns)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<wraps, id: \.self) { wrap in
                Text(wraps == 1 ? text : Self.slice(text, from: wrap * metrics.columns, count: metrics.columns))
                    .font(codeFont(metrics))
                    .italic(line.kind == .note)
                    .foregroundStyle(line.kind == .note ? palette.dim : palette.code)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(height: metrics.lineHeight, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 12)
    }

    private static func slice(_ text: AttributedString, from start: Int, count: Int) -> AttributedString {
        let characters = text.characters
        guard let lower = characters.index(characters.startIndex, offsetBy: start, limitedBy: characters.endIndex) else {
            return AttributedString()
        }
        let upper = characters.index(lower, offsetBy: count, limitedBy: characters.endIndex) ?? characters.endIndex
        return AttributedString(text[lower..<upper])
    }

    private func band(_ kind: GitDiffLine.Kind, gutter: Bool) -> Color {
        let colors = palette.colors
        switch kind {
        case .added: return palette.color(gutter ? colors.addedGutter : colors.addedLine)
        case .removed: return palette.color(gutter ? colors.removedGutter : colors.removedLine)
        case .context, .note: return .clear
        }
    }

    // MARK: Bars

    /// `@@ −16,6 +16,7 @@ enum ConfigAction {`; its button shows the
    /// whole file. Its text and its height follow the code; its button is as wide as a unified line's line numbers.
    private func hunkHeader(_ hunk: GitHunk, metrics: GitView.TextMetrics) -> some View {
        let canExpand = gitView.diffRows.contains { if case .wholeFile = $0.kind { true } else { false } }
        let font = Font.system(size: GitView.TextMetrics.hunkSize(metrics.fontSize), design: .monospaced)
        return HStack(spacing: 10) {
            Button { gitView.showWholeFile() } label: {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: metrics.fontSize))
                    .foregroundStyle(.tertiary)
                    .opacity(canExpand ? 1 : 0)
                    .frame(width: 2 * metrics.numberWidth, height: metrics.hunkHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canExpand)
            .help("Show the whole file")
            Text(hunk.header.replacingOccurrences(of: "-", with: "−"))
                .font(font)
                .foregroundStyle(.tertiary)
                .fixedSize()
            Text(hunk.styledContext ?? AttributedString(hunk.context))
                .font(font)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(height: metrics.hunkHeight)
        .background(palette.fill)
        .overlay(alignment: .top) { palette.softSeparator.frame(height: 1) }
        .overlay(alignment: .bottom) { palette.softSeparator.frame(height: 1) }
    }

    /// Above the unstaged and the staged part of a change with both.
    private func partBar(_ group: GitChange.Group) -> some View {
        HStack(spacing: 8) {
            Circle().fill(group == .staged ? palette.staged : palette.unstaged)
                .frame(width: interfaceFontSize(7), height: interfaceFontSize(7))
            Text("\(group.title) changes").font(interfaceFontSize.font(12, weight: .semibold)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.leading, 18)
        .frame(height: interfaceFontSize(30))
        .background(palette.header)
        .overlay(alignment: .bottom) { palette.separator.frame(height: 1) }
    }

    /// Its symbol stands over the hunk headers' buttons.
    private func bar(symbol: String, text: String, metrics: GitView.TextMetrics, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(interfaceFontSize.font(12)).frame(width: 2 * metrics.numberWidth)
                Text(text).font(interfaceFontSize.font(12))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .frame(height: interfaceFontSize(30))
            .background(palette.fill)
            .overlay(alignment: .top) { palette.softSeparator.frame(height: 1) }
            .overlay(alignment: .bottom) { palette.softSeparator.frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(interfaceFontSize.font(12))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
    }

    /// `End of Keybinds.swift  ] next file: GhosttyRuntime.swift  [ previous: Config.swift`
    private var endOfFile: some View {
        HStack(spacing: 6) {
            if let header = gitView.fileHeader {
                Text("End of").foregroundStyle(.tertiary)
                Text((header.path as NSString).lastPathComponent).fontWeight(.semibold).foregroundStyle(.secondary)
                if let next = gitView.neighbor(forward: true) {
                    GitKeyCap(text: "]", palette: palette).padding(.leading, 10)
                    Text("next file:").foregroundStyle(.tertiary)
                    Button(Self.name(next)) { gitView.select(next) }.buttonStyle(.link)
                }
                if let previous = gitView.neighbor(forward: false) {
                    GitKeyCap(text: "[", palette: palette).padding(.leading, 10)
                    Text("previous:").foregroundStyle(.tertiary)
                    Button(Self.name(previous)) { gitView.select(previous) }.buttonStyle(.link)
                }
            }
        }
        .font(interfaceFontSize.font(12))
        .lineLimit(1)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private static func name(_ item: GitView.Item) -> String {
        switch item {
        case .change(let change): change.name
        case .file(let path): (path as NSString).lastPathComponent
        default: ""
        }
    }
}

/// Above a single file's diff: its path, +/− counts and how it changed, and
/// which hunk the pane is on.
private struct GitFileHeader: View {
    let gitView: GitView
    let header: GitView.FileHeader
    let palette: Palette
    @Environment(\.interfaceFontSize) private var fontSize

    var body: some View {
        GitPathBar(path: header.path, additions: header.additions, deletions: header.deletions, palette: palette, height: 46) {
            if let kind = GitNavigatorText.kind(of: header.files.first, change: header.change, colors: palette.colors) {
                GitTag(text: kind.title, style: .tint(kind.color), palette: palette)
            }
            if let change = header.change, !change.isUntracked, !change.isConflict {
                ForEach(change.groups, id: \.self) { group in
                    GitTag(text: group.title, style: .tint(group == .staged ? palette.colors.green : palette.colors.red), palette: palette)
                }
            }
        } trailing: {
            let position = gitView.hunkPosition
            if position.count > 0 {
                Text(verbatim: "Hunk \(position.current) of \(position.count)")
                    .font(fontSize.font(11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                GitIconButton(symbol: "arrow.up", help: "Previous hunk (⌥↑)") { gitView.jumpToHunk(forward: false) }
                GitIconButton(symbol: "arrow.down", help: "Next hunk (⌥↓)") { gitView.jumpToHunk(forward: true) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("git-file-header")
        .accessibilityLabel(header.path)
    }
}

/// A file's bar in a diff of several files: a commit's, a stash's, a
/// branch's or a folder's.
private struct GitFileBar: View {
    let file: GitPatchFile
    let palette: Palette

    var body: some View {
        GitPathBar(path: file.path, additions: file.additions, deletions: file.deletions, palette: palette, height: 40) {
            if let kind = GitNavigatorText.kind(of: file, change: nil, colors: palette.colors) {
                GitTag(text: kind.title, style: .tint(kind.color), palette: palette)
            }
            if let group = file.group, group != .untracked {
                GitTag(text: group.title, style: .tint(group == .staged ? palette.colors.green : palette.colors.red), palette: palette)
            }
        } trailing: {
            EmptyView()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("git-file-bar-\(file.id)")
        .accessibilityLabel(file.path)
    }
}

private struct GitPathBar<Tags: View, Trailing: View>: View {
    let path: String
    let additions: Int
    let deletions: Int
    let palette: Palette
    /// The bar's height at 12, which grows with its text.
    let height: CGFloat
    @ViewBuilder let tags: Tags
    @ViewBuilder let trailing: Trailing
    @Environment(\.interfaceFontSize) private var fontSize

    var body: some View {
        let folder = (path as NSString).deletingLastPathComponent
        HStack(spacing: 10) {
            GitFileTile(path: path, size: 14)
            HStack(spacing: 0) {
                if !folder.isEmpty { Text(folder + "/").foregroundStyle(.secondary) }
                Text((path as NSString).lastPathComponent).fontWeight(.semibold)
            }
            .font(fontSize.font(13))
            .lineLimit(1)
            .truncationMode(.head)
            stat("+\(additions)", additions > 0 ? (palette.colors.addedText, palette.colors.addedLine) : nil)
            stat("−\(deletions)", deletions > 0 ? (palette.colors.removedText, palette.colors.removedLine) : nil)
            tags
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 14)
        .frame(height: fontSize(height))
        // Its tags and counts keep their width, so in a diff too narrow for them, as beside a List pane grown with the
        // Interface font size, the bar is cut at its end instead of pushing the List pane out of the Git View.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .clipped()
        .background(palette.header)
        .overlay(alignment: .bottom) { palette.separator.frame(height: 1) }
    }

    /// Gray for a zero count.
    private func stat(_ text: String, _ colors: (text: NSColor, background: NSColor)?) -> some View {
        Text(text)
            .font(fontSize.font(11, weight: .semibold, design: .monospaced))
            .foregroundStyle(colors.map { AnyShapeStyle(palette.color($0.text)) } ?? AnyShapeStyle(.tertiary))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(colors.map { palette.color($0.background) } ?? palette.fill2))
            .fixedSize()
    }
}

/// Above a commit's, stash's or folder's files: what it is, who made it,
/// and how much it changes; a branch's latest commits; a comparison's two
/// ends.
private struct GitCard: View {
    let gitView: GitView
    let content: GitView.Content
    let palette: Palette
    @Environment(\.interfaceFontSize) private var fontSize

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch content.header {
            case .commit(let commit, let detail):
                commitCard(commit, detail)
            case .branch(let branch, let log):
                branchCard(branch, log)
            case .stash(let stash):
                stashCard(stash)
            case .folder(let path, let changes):
                folderCard(path, changes)
            case .comparison(let base, let target):
                comparisonCard(base, target)
            case .change:
                EmptyView()
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.header)
        .overlay(alignment: .bottom) { palette.separator.frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("git-card")
        .accessibilityLabel(title)
    }

    /// What the card is about: a commit's subject, a branch's name, a stash's message, a folder's path.
    private var title: String {
        switch content.header {
        case .commit(let commit, let detail): detail?.title ?? commit.subject
        case .branch(let branch, _): branch.name
        case .stash(let stash): GitNavigatorText.stashTitle(stash.message)
        case .folder(let path, _): path == GitTree.root ? "/" : path
        case .change(let change): change.path
        case .comparison(let base, let target?): "\(base.name) → \(target.name)"
        case .comparison(let base, nil): "Comparing \(base.name)"
        }
    }

    /// W: both ends and what changes from one to the other; on the base
    /// itself, what to do next.
    private func comparisonCard(_ base: GitView.Item, _ target: GitView.Item?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.left.arrow.right").font(fontSize.font(15)).foregroundStyle(.secondary)
                Text(title).font(fontSize.font(17, weight: .semibold)).textSelection(.enabled)
            }
            end(base, role: "Base")
            if let target {
                end(target, role: "Compared")
                summary
            } else {
                Text("Select another commit, branch or stash to compare it with. W here, or ⎋, ends the comparison.")
                    .font(fontSize.font(13))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// One end of a comparison: its name, its commit and what it says.
    private func end(_ item: GitView.Item, role: String) -> some View {
        HStack(spacing: 8) {
            Text(role).font(fontSize.font(12)).foregroundStyle(.tertiary).frame(width: fontSize(64), alignment: .leading)
            switch item {
            case .branch(let branch):
                GitTag(text: branch.name, symbol: "arrow.triangle.branch", style: .tint(palette.colors.green), palette: palette)
                hashChip(branch.sha)
            case .stash(let stash):
                GitTag(text: stash.ref, symbol: "archivebox", style: .gray, palette: palette)
                hashChip(stash.sha)
                Text(GitNavigatorText.stashTitle(stash.message)).font(fontSize.font(13)).foregroundStyle(.secondary).lineLimit(1)
            case .commit(let commit):
                hashChip(commit.sha)
                Text(commit.subject).font(fontSize.font(13)).foregroundStyle(.secondary).lineLimit(1)
            default:
                EmptyView()
            }
        }
    }

    private func commitCard(_ commit: GitCommit, _ detail: GitCommitDetail?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(detail?.title ?? commit.subject)
                .font(fontSize.font(17, weight: .semibold))
                .textSelection(.enabled)
            if let body = detail?.body, !body.isEmpty {
                Text(body)
                    .font(fontSize.font(13))
                    .foregroundStyle(.secondary)
                    .lineLimit(8)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                avatar(commit.initials, name: commit.author)
                Text(commit.author).font(fontSize.font(13, weight: .semibold))
                Text("committed \(GitNavigatorText.relative(commit.date))").font(fontSize.font(13)).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                hashChip(commit.sha)
                if let parents = detail?.parents, !parents.isEmpty {
                    Text(parents.count == 1 ? "parent" : "parents").font(fontSize.font(12)).foregroundStyle(.tertiary)
                    ForEach(parents, id: \.self) { hashChip($0) }
                }
                ForEach(commit.refs + commit.remotes, id: \.self) { ref in
                    GitTag(text: ref, symbol: "arrow.triangle.branch",
                           style: .tint(commit.refs.contains(ref) ? palette.colors.green : palette.colors.cyan), palette: palette)
                }
                ForEach(commit.tags, id: \.self) { tag in
                    GitTag(text: tag, symbol: "tag", style: .tint(palette.colors.yellow), palette: palette)
                }
            }
            summary
        }
    }

    /// What the branch is, and its latest commits; a click on one goes
    /// into the branch's commits on it.
    private func branchCard(_ branch: GitBranch, _ log: GitLog?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: branch.isHead ? "checkmark" : "arrow.triangle.branch")
                    .font(fontSize.font(15, weight: branch.isHead ? .bold : .regular))
                    .foregroundStyle(branch.isHead ? Color.accentColor : Color.secondary)
                Text(branch.name).font(fontSize.font(17, weight: .semibold)).textSelection(.enabled)
                if let upstream = branch.upstream {
                    GitTag(text: upstream, symbol: "cloud", style: branch.isInSync ? .tint(palette.colors.green) : .gray, palette: palette)
                }
                if branch.track == "gone" {
                    GitTag(text: "gone", style: .tint(palette.colors.red), palette: palette).help("Its upstream was deleted")
                }
            }
            Text(subtitle(branch))
                .font(fontSize.font(13))
                .foregroundStyle(.secondary)
            if let error = log?.error {
                Text(error).font(fontSize.font(13)).foregroundStyle(.secondary).textSelection(.enabled)
            } else if let log {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(log.commits.prefix(12)) { commit in
                        Button { gitView.enter(.branch(branch), selecting: .commit(commit)) } label: {
                            HStack(spacing: 8) {
                                avatar(commit.initials, name: commit.author, size: 16)
                                Text(String(commit.sha.prefix(7))).font(fontSize.font(11, design: .monospaced)).foregroundStyle(.tertiary)
                                Text(commit.subject).font(fontSize.font(13)).lineLimit(1)
                                Spacer(minLength: 8)
                                Text(GitRepository.age(of: commit.date)).font(fontSize.font(11)).foregroundStyle(.tertiary)
                            }
                            .frame(height: fontSize(22))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading its history…").font(fontSize.font(13)).foregroundStyle(.secondary)
                }
                .frame(height: fontSize(22))
            }
            Button { gitView.enter(.branch(branch)) } label: {
                HStack(spacing: 6) {
                    Text("Show its history").font(fontSize.font(12, weight: .semibold))
                    GitKeyCap(text: "↩", palette: palette)
                }
                .padding(.horizontal, 10)
                .frame(height: fontSize(26))
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(palette.fill2))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// How it stands against the branch you're on, and where else it's
    /// checked out.
    private func subtitle(_ branch: GitBranch) -> String {
        guard !branch.isHead else { return "The branch you're on." }
        let head = gitView.snapshot?.head ?? "HEAD"
        func commits(_ count: Int) -> String { count == 1 ? "1 commit" : "\(count) commits" }
        var text = switch (branch.ahead, branch.behind) {
        case (0, 0): "Even with \(head)."
        case (let ahead, 0): "\(commits(ahead)) ahead of \(head)."
        case (0, let behind): "\(commits(behind)) behind \(head)."
        case (let ahead, let behind): "\(commits(ahead)) ahead of and \(behind) behind \(head)."
        }
        if let path = branch.worktreePath {
            text += " Checked out in \(Paths.tildify(path, home: gitView.store?.homeDirectory ?? Paths.home))."
        }
        return text
    }

    private func stashCard(_ stash: GitStash) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(GitNavigatorText.stashTitle(stash.message))
                .font(fontSize.font(17, weight: .semibold))
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Image(systemName: "archivebox").font(fontSize.font(13)).foregroundStyle(.secondary)
                Text(stash.message.components(separatedBy: ": ").first ?? "").font(fontSize.font(13, weight: .semibold))
                Text("stashed \(GitNavigatorText.relative(stash.date))").font(fontSize.font(13)).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                GitTag(text: stash.ref, style: .gray, palette: palette)
                hashChip(stash.sha)
            }
            summary
        }
    }

    private func folderCard(_ path: String, _ changes: [GitChange]) -> some View {
        let staged = changes.filter(\.isStaged).count
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill").font(fontSize.font(15)).foregroundStyle(.secondary)
                Text(path == GitTree.root ? "/" : path + "/").font(fontSize.font(17, weight: .semibold)).textSelection(.enabled)
            }
            Text(verbatim: "\(changes.count) changed file\(changes.count == 1 ? "" : "s") in this folder"
                 + (staged > 0 ? ", \(staged) of them staged" : ""))
                .font(fontSize.font(13))
                .foregroundStyle(.secondary)
            summary
        }
    }

    /// `6 files changed +379 −61` and a bar split in proportion.
    private var summary: some View {
        let patch = content.patch
        let total = max(1, patch.additions + patch.deletions)
        let count = Set(patch.files.map(\.path)).count
        return HStack(spacing: 8) {
            Text(verbatim: "\(count) file\(count == 1 ? "" : "s") changed").font(fontSize.font(13)).foregroundStyle(.secondary)
            Text(verbatim: "+\(patch.additions)").foregroundStyle(palette.color(palette.colors.addedText))
            Text(verbatim: "−\(patch.deletions)").foregroundStyle(palette.color(palette.colors.removedText))
            HStack(spacing: 0) {
                palette.color(palette.colors.green).frame(width: 170 * CGFloat(patch.additions) / CGFloat(total))
                palette.color(palette.colors.red).frame(width: 170 * CGFloat(patch.deletions) / CGFloat(total))
            }
            .frame(width: 170, height: 6, alignment: .leading)
            .background(palette.fill2)
            .clipShape(Capsule())
        }
        .font(fontSize.font(12, weight: .semibold, design: .monospaced))
    }

    /// A circle `size` points across at 12, with the author's initials in it.
    private func avatar(_ initials: String, name: String, size: CGFloat = 22) -> some View {
        let side = fontSize(size)
        return Circle()
            .fill(palette.color(palette.colors.author(name)).gradient)
            .frame(width: side, height: side)
            .overlay(Text(initials).font(.system(size: side * 0.42, weight: .semibold)).foregroundStyle(.white))
    }

    /// Copies the full hash.
    private func hashChip(_ sha: String) -> some View {
        Button { gitView.copy(sha, title: "Copied Hash", shown: String(sha.prefix(8))) } label: {
            HStack(spacing: 5) {
                Text(String(sha.prefix(8))).font(fontSize.font(11.5, design: .monospaced))
                Image(systemName: "doc.on.doc").font(fontSize.font(10)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 7)
            .frame(height: fontSize(20))
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(palette.fill2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Copy \(sha)")
    }
}

// MARK: - Committing

/// c: the commit message box, as lazygit's: what the commit takes, its
/// summary and description. ↩ in the summary or ⌘↩ commits; ⎋ closes it
/// and keeps the message.
private struct GitCommitBox: View {
    @Bindable var gitView: GitView
    let snapshot: GitSnapshot
    let palette: Palette
    @FocusState private var field: Field?
    @State private var isShown = false
    @Environment(\.interfaceFontSize) private var fontSize

    private enum Field { case summary, description }

    var body: some View {
        let staged = snapshot.changes.filter { $0.groups.contains(.staged) }
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                Color.black.opacity(palette.colors.isDark ? 0.32 : 0.14)
                    .contentShape(Rectangle())
                    .onTapGesture { gitView.closeCommit() }
                card(staged: staged)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("git-commit-box")
                    .frame(width: GitPopupMetrics.width(GitPopupMetrics.designCommitBoxWidth, in: proxy.size.width, size: fontSize))
                    .padding(.top, max(20, proxy.size.height * 0.1))
                    .scaleEffect(isShown ? 1 : 0.97, anchor: .top)
                    .offset(y: isShown ? 0 : -6)
            }
        }
        .onAppear {
            withAnimation(.spring(duration: 0.28, bounce: 0.2)) { isShown = true }
            DispatchQueue.main.async { field = .summary }
        }
    }

    private func card(staged: [GitChange]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(staged: staged)
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 14)
            editor
                .padding(.horizontal, 18)
            if snapshot.isDetached {
                notice("Detached at \(snapshot.head). This commit won't be on any branch.",
                       symbol: "exclamationmark.triangle.fill", color: palette.colors.yellow)
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
            }
            if snapshot.isMerging, let title = snapshot.operationTitle {
                notice("\(title): this commit concludes the merge.", symbol: "arrow.triangle.merge", color: palette.colors.blue)
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
            }
            // Concluding a merge can take nothing more than its resolutions.
            if !staged.isEmpty || !snapshot.isMerging {
                fileList(staged)
                    .padding(.horizontal, 18)
                    .padding(.top, 16)
            }
            if let error = gitView.commitError {
                errorCallout(error)
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
            }
            footer(canCommit: !staged.isEmpty || snapshot.isMerging)
                .padding(.top, 16)
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(palette.chrome))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(palette.separator))
        .shadow(color: .black.opacity(0.35), radius: 32, y: 14)
    }

    private func header(staged: [GitChange]) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.gradient)
                .frame(width: fontSize(32), height: fontSize(32))
                .overlay(Image(systemName: "checkmark").font(fontSize.font(14, weight: .bold)).foregroundStyle(.white))
            VStack(alignment: .leading, spacing: 3) {
                Text("Commit").font(fontSize.font(15, weight: .semibold))
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.branch").font(fontSize.font(10, weight: .semibold))
                    Text(snapshot.head).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                    Text(verbatim: "·").foregroundStyle(.tertiary)
                    Text(staged.count == 1 ? "1 staged file" : "\(staged.count) staged files")
                }
                .font(fontSize.font(12))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            GitIconButton(symbol: "xmark", help: "Close, keeping the message (⎋)") { gitView.closeCommit() }
        }
    }

    /// The summary in large type over the description, in one field.
    private var editor: some View {
        let count = gitView.commitSummary.count
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField("", text: $gitView.commitSummary, prompt: Text("Summary").foregroundColor(.secondary))
                    .textFieldStyle(.plain)
                    .font(fontSize.font(15, weight: .semibold))
                    .focused($field, equals: .summary)
                    .onSubmit { gitView.commit() }
                    .accessibilityIdentifier("git-commit-summary")
                if count > 0 {
                    // As lazygit counts it; past 72 it wraps in most tools.
                    Text(verbatim: "\(count)")
                        .font(fontSize.font(11, weight: .medium, design: .monospaced))
                        .foregroundStyle(count > 72 ? AnyShapeStyle(palette.color(palette.colors.strong(palette.colors.yellow))) : AnyShapeStyle(.tertiary))
                        .help("Summaries read best in 72 characters or fewer")
                }
            }
            .padding(.horizontal, 14)
            .frame(height: fontSize(46))
            palette.softSeparator.frame(height: 1).padding(.horizontal, 14)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $gitView.commitDescription)
                    .font(fontSize.font(13))
                    .scrollContentBackground(.hidden)
                    .focused($field, equals: .description)
                    .accessibilityIdentifier("git-commit-description")
                if gitView.commitDescription.isEmpty {
                    Text("Description (optional)")
                        .font(fontSize.font(13))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 10)
            .frame(height: fontSize(124))
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(palette.background))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(field == nil ? palette.softSeparator : Color.accentColor.opacity(0.8), lineWidth: field == nil ? 1 : 1.5)
        )
        .animation(.easeOut(duration: 0.12), value: field)
    }

    /// What the commit takes: the staged files. Unstaged since the box
    /// opened, there's nothing to commit.
    private func fileList(_ files: [GitChange]) -> some View {
        let yellow = palette.color(palette.colors.strong(palette.colors.yellow))
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if files.isEmpty {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(yellow)
                    Text("Nothing is staged anymore, so there's nothing to commit").foregroundStyle(yellow)
                } else {
                    Text("Staged").foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(verbatim: "\(files.count)")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .frame(height: fontSize(17))
                    .background(Capsule().fill(palette.fill2))
            }
            .font(fontSize.font(11.5, weight: .semibold))
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(files) { change in fileRow(change) }
                }
            }
            .frame(height: GitPopupMetrics.fileListHeight(files: files.count, size: fontSize))
            .scrollIndicators(.automatic)
        }
    }

    private func fileRow(_ change: GitChange) -> some View {
        let folder = (change.path as NSString).deletingLastPathComponent
        return HStack(spacing: 8) {
            HStack(spacing: 0) {
                Text(String(change.index))
                    .foregroundStyle(change.isUntracked || change.isConflict ? palette.unstaged : palette.staged)
                Text(String(change.worktree)).foregroundStyle(palette.unstaged)
            }
            .font(fontSize.font(11, weight: .bold, design: .monospaced))
            .frame(width: fontSize(16), alignment: .leading)
            GitFileTile(path: change.path, size: 14)
            Text(change.name).font(fontSize.font(12.5)).lineLimit(1)
            if !folder.isEmpty {
                Text(folder).font(fontSize.font(11.5)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 0)
        }
        .frame(height: GitPopupMetrics.fileRowHeight(fontSize))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("git-commit-file:\(change.path)")
    }

    /// What's different about this commit: it's on a detached HEAD, or
    /// concludes a merge.
    private func notice(_ text: String, symbol: String, color: NSColor) -> some View {
        let strong = palette.color(palette.colors.strong(color))
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).font(fontSize.font(11.5))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(fontSize.font(12, weight: .medium))
        .foregroundStyle(strong)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(palette.color(palette.colors.tint(color))))
    }

    private func errorCallout(_ error: String) -> some View {
        let red = palette.color(palette.colors.strong(palette.colors.red))
        return HStack(alignment: .top, spacing: 9) {
            Image(systemName: "xmark.octagon.fill").font(fontSize.font(13)).foregroundStyle(red)
            VStack(alignment: .leading, spacing: 4) {
                Text("The commit failed").font(fontSize.font(12, weight: .semibold)).foregroundStyle(red)
                ScrollView(.vertical) {
                    Text(error)
                        .font(fontSize.font(11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: fontSize(110))
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(palette.color(palette.colors.tint(palette.colors.red))))
    }

    private func footer(canCommit hasStaged: Bool) -> some View {
        let canCommit = hasStaged && !gitView.commitSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !gitView.isCommitting
        return HStack(spacing: 10) {
            Spacer(minLength: 0)
            Button { gitView.closeCommit() } label: {
                HStack(spacing: 6) {
                    Text("Cancel").font(fontSize.font(12.5, weight: .medium))
                    Text(verbatim: "esc").font(fontSize.font(10.5, weight: .medium)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .frame(height: fontSize(30))
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(palette.fill2))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close, keeping the message (⎋)")
            .accessibilityIdentifier("git-commit-cancel")
            Button { gitView.commit() } label: {
                HStack(spacing: 7) {
                    if gitView.isCommitting {
                        ProgressView().controlSize(.mini).environment(\.colorScheme, .dark)
                        Text("Committing…")
                    } else {
                        Text("Commit to \(snapshot.head)").lineLimit(1).truncationMode(.middle)
                        Text(verbatim: "⌘↩").font(fontSize.font(11)).foregroundStyle(.white.opacity(0.7))
                    }
                }
                .font(fontSize.font(12.5, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: fontSize(30))
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.accentColor.gradient))
                .opacity(canCommit || gitView.isCommitting ? 1 : 0.45)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canCommit)
            .help("Commit (↩ in the summary, or ⌘↩)")
            .accessibilityIdentifier("git-commit-submit")
        }
        .padding(.horizontal, 18)
        .frame(height: fontSize(58))
        .background(Color.primary.opacity(palette.colors.isDark ? 0.03 : 0.025))
        .overlay(alignment: .top) { palette.softSeparator.frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("git-commit-footer")
    }
}

// MARK: - Menus

/// A Git View menu, such as lazygit's Discard changes menu on d: its title
/// and what it's on, then its choices, each with its key. j and k move the
/// highlight, ↩ runs the highlighted choice, and ⎋ closes it.
private struct GitMenuView: View {
    let gitView: GitView
    let menu: GitMenu
    let palette: Palette
    @State private var isShown = false
    @State private var hovered: String?
    @Environment(\.interfaceFontSize) private var fontSize

    private var red: Color { palette.color(palette.colors.strong(palette.colors.red)) }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                Color.black.opacity(palette.colors.isDark ? 0.32 : 0.14)
                    .contentShape(Rectangle())
                    .onTapGesture { gitView.closeMenu() }
                card
                    .frame(width: GitPopupMetrics.width(GitPopupMetrics.designMenuWidth, in: proxy.size.width, size: fontSize))
                    .padding(.top, max(20, proxy.size.height * 0.16))
                    .scaleEffect(isShown ? 1 : 0.97, anchor: .top)
                    .offset(y: isShown ? 0 : -6)
            }
        }
        .onAppear { withAnimation(.spring(duration: 0.28, bounce: 0.2)) { isShown = true } }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)
            if !menu.agents.isEmpty { agents }
            VStack(spacing: 2) {
                ForEach(Array(menu.choices.enumerated()), id: \.element.id) { index, choice in
                    row(choice, isHighlighted: menu.highlighted == index)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
            footer
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(palette.chrome))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(palette.separator))
        .shadow(color: .black.opacity(0.35), radius: 32, y: 14)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("git-menu")
        .accessibilityLabel(menu.title)
        // Each choice by its key, and the menu's own keys, so scripts/verify can press them without typing.
        .accessibilityActions {
            ForEach(menu.choices) { choice in
                Button { gitView.chooseMenu(key: choice.key) } label: { Text(verbatim: choice.key) }
            }
            ForEach(["enter", "escape", "j", "k"], id: \.self) { name in
                Button { gitView.performKey(named: name) } label: { Text(verbatim: name) }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(menu.isDestructive ? red.gradient : palette.color(palette.colors.strong(palette.colors.blue)).gradient)
                .frame(width: fontSize(30), height: fontSize(30))
                .overlay(Image(systemName: menu.symbol).font(fontSize.font(13, weight: .semibold)).foregroundStyle(.white))
            VStack(alignment: .leading, spacing: 3) {
                Text(menu.title).font(fontSize.font(14.5, weight: .semibold))
                if let subject = menu.subject {
                    HStack(spacing: 5) {
                        switch subject {
                        case .folder(let path, let files):
                            Image(systemName: "folder").font(fontSize.font(11))
                            Text(path == GitTree.root ? "/" : path).fontWeight(.medium).lineLimit(1).truncationMode(.head)
                            if let files {
                                Text(verbatim: "·").foregroundStyle(.tertiary)
                                Text(files == 1 ? "1 file" : "\(files) files")
                            }
                        case .file(let path):
                            GitFileTile(path: path, size: 13)
                            Text((path as NSString).lastPathComponent).fontWeight(.medium).lineLimit(1)
                            let folder = (path as NSString).deletingLastPathComponent
                            if !folder.isEmpty {
                                Text(folder).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                            }
                        case .text(let text):
                            Text(text).lineLimit(2)
                        }
                    }
                    .font(fontSize.font(12))
                    .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// The Agent guard's warning: the Agents working in the Worktree, which this would change the files under.
    private var agents: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(menu.agents.count == 1 ? "An Agent is working here" : "\(menu.agents.count) Agents are working here",
                  systemImage: "exclamationmark.triangle.fill")
                .font(fontSize.font(12, weight: .semibold))
            ForEach(menu.agents, id: \.self) { name in
                Text(name).font(fontSize.font(11.5)).lineLimit(1).padding(.leading, 20)
            }
        }
        .foregroundStyle(red)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(red.opacity(0.12)))
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("git-menu-agents")
        .accessibilityLabel(menu.agents.joined(separator: "\n"))
    }

    /// ↩ runs the highlighted one; j and k move between them.
    private func row(_ choice: GitMenu.Choice, isHighlighted: Bool) -> some View {
        Button { gitView.choose(choice) } label: {
            HStack(spacing: 10) {
                GitKeyCap(text: choice.key.hasPrefix("shift+") ? choice.key.dropFirst("shift+".count).uppercased() : choice.key,
                          palette: palette)
                VStack(alignment: .leading, spacing: 2) {
                    Text(choice.title)
                        .font(fontSize.font(13, weight: .semibold))
                        .foregroundStyle(choice.isDestructive ? red : Color.primary)
                    if let note = choice.note {
                        Text(note).font(fontSize.font(11.5)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if isHighlighted {
                    Text(verbatim: "↩").font(fontSize.font(11)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: fontSize(choice.note == nil ? 36 : 48))
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHighlighted ? palette.fill2 : hovered == choice.id && choice.isEnabled ? palette.fill : .clear)
            )
            .opacity(choice.isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!choice.isEnabled)
        .onHover { hovered = $0 ? choice.id : hovered == choice.id ? nil : hovered }
        .accessibilityIdentifier("git-menu-choice-\(choice.key)")
        .accessibilityLabel(choice.title)
        .accessibilityValue("highlighted=\(isHighlighted ? 1 : 0) enabled=\(choice.isEnabled ? 1 : 0)")
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if let footnote = menu.footnote {
                Image(systemName: "exclamationmark.triangle").font(fontSize.font(11))
                Text(footnote).font(fontSize.font(11.5)).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("git-menu-footnote")
            }
            Spacer(minLength: 8)
            Button { gitView.closeMenu() } label: {
                HStack(spacing: 6) {
                    Text("Cancel").font(fontSize.font(12.5, weight: .medium))
                    Text(verbatim: "esc").font(fontSize.font(10.5, weight: .medium)).foregroundStyle(.tertiary)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .frame(height: fontSize(28))
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(palette.fill2))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close (⎋)")
            .accessibilityIdentifier("git-menu-cancel")
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: fontSize(48))
        .background(Color.primary.opacity(palette.colors.isDark ? 0.03 : 0.025))
        .overlay(alignment: .top) { palette.softSeparator.frame(height: 1) }
    }
}

// MARK: - Prompts

/// A Git View prompt: one line for one value, over the Git View as a menu is.
/// ↩ submits and ⎋ cancels; the field is `git-prompt-field`, and the prompt's
/// actions are `enter` and `escape`.
private struct GitPromptView: View {
    @Bindable var gitView: GitView
    let prompt: GitPrompt
    let palette: Palette
    @FocusState private var isFocused: Bool
    @State private var isShown = false
    @Environment(\.interfaceFontSize) private var fontSize

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                Color.black.opacity(palette.colors.isDark ? 0.32 : 0.14)
                    .contentShape(Rectangle())
                    .onTapGesture { gitView.closePrompt() }
                card
                    .frame(width: GitPopupMetrics.width(GitPopupMetrics.designPromptWidth, in: proxy.size.width, size: fontSize))
                    .padding(.top, max(20, proxy.size.height * 0.16))
                    .scaleEffect(isShown ? 1 : 0.97, anchor: .top)
                    .offset(y: isShown ? 0 : -6)
            }
        }
        .onAppear {
            withAnimation(.spring(duration: 0.28, bounce: 0.2)) { isShown = true }
            DispatchQueue.main.async { isFocused = true }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)
            field
                .padding(.horizontal, 16)
                .padding(.bottom, suggestions.isEmpty ? 16 : 8)
            if !suggestions.isEmpty {
                suggestionList
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
            footer
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(palette.chrome))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(palette.separator))
        .shadow(color: .black.opacity(0.35), radius: 32, y: 14)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("git-prompt")
        .accessibilityLabel(prompt.title)
        // The keys, so scripts/verify can press them without typing.
        .accessibilityActions {
            ForEach(["enter", "escape"] + (suggestions.isEmpty ? [] : ["down", "up"]), id: \.self) { name in
                Button {
                    switch name {
                    case "enter": gitView.submitPrompt()
                    case "escape": gitView.closePrompt()
                    default: gitView.moveSuggestion(by: name == "down" ? 1 : -1)
                    }
                } label: { Text(verbatim: name) }
            }
        }
    }

    private var suggestions: [String] { gitView.promptSuggestions }

    /// What matches as it is typed; ↓/↑ choose, and a click takes one. Each row is `git-prompt-suggestion-<n>`, and its
    /// value says whether it is the one chosen.
    private var suggestionList: some View {
        let chosen = gitView.promptSuggestion
        return VStack(spacing: 2) {
            ForEach(Array(suggestions.enumerated()), id: \.element) { index, name in
                let isChosen = name == chosen
                Button { gitView.submitSuggestion(name) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.branch").font(fontSize.font(10.5)).foregroundStyle(.secondary)
                        Text(name).font(fontSize.font(12.5)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: fontSize(26))
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(isChosen ? Color.accentColor.opacity(0.22) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("git-prompt-suggestion-\(index)")
                .accessibilityLabel(name)
                .accessibilityValue(isChosen ? "chosen" : "")
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(palette.color(palette.colors.strong(palette.colors.blue)).gradient)
                .frame(width: fontSize(30), height: fontSize(30))
                .overlay(Image(systemName: prompt.symbol).font(fontSize.font(13, weight: .semibold)).foregroundStyle(.white))
            VStack(alignment: .leading, spacing: 3) {
                Text(prompt.title).font(fontSize.font(14.5, weight: .semibold))
                if case .text(let text)? = prompt.subject {
                    Text(text).font(fontSize.font(12)).foregroundStyle(.secondary).lineLimit(4)
                }
            }
            Spacer(minLength: 0)
            if prompt.isSecret {
                Label("Hidden", systemImage: "lock.fill")
                    .font(fontSize.font(11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .help("What you type is hidden")
                    .accessibilityIdentifier("git-prompt-secret")
            }
        }
    }

    private var field: some View {
        Group {
            if prompt.isSecret {
                SecureField("", text: $gitView.promptText, prompt: Text(prompt.placeholder).foregroundColor(.secondary))
            } else {
                TextField("", text: $gitView.promptText, prompt: Text(prompt.placeholder).foregroundColor(.secondary))
            }
        }
        .textFieldStyle(.plain)
        .font(fontSize.font(13.5))
        .focused($isFocused)
        .onSubmit { gitView.submitPrompt() }
        .padding(.horizontal, 12)
        .frame(height: fontSize(38))
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(palette.background))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isFocused ? Color.accentColor.opacity(0.8) : palette.softSeparator, lineWidth: isFocused ? 1.5 : 1)
        )
        .accessibilityIdentifier("git-prompt-field")
        .accessibilityLabel(prompt.title)
    }

    private var footer: some View {
        let canSubmit = prompt.accepts(gitView.promptText)
        return HStack(spacing: 8) {
            Spacer(minLength: 8)
            Button { gitView.closePrompt() } label: {
                HStack(spacing: 6) {
                    Text("Cancel").font(fontSize.font(12.5, weight: .medium))
                    Text(verbatim: "esc").font(fontSize.font(10.5, weight: .medium)).foregroundStyle(.tertiary)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .frame(height: fontSize(28))
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(palette.fill2))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close (⎋)")
            .accessibilityIdentifier("git-prompt-cancel")
            Button { gitView.submitPrompt() } label: {
                HStack(spacing: 6) {
                    Text(prompt.submitTitle).font(fontSize.font(12.5, weight: .semibold))
                    Text(verbatim: "↩").font(fontSize.font(10.5, weight: .medium)).opacity(0.7)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: fontSize(28))
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.accentColor))
                .opacity(canSubmit ? 1 : 0.45)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .help("\(prompt.submitTitle) (↩)")
            .accessibilityIdentifier("git-prompt-submit")
        }
        .padding(.horizontal, 16)
        .frame(height: fontSize(48))
        .background(Color.primary.opacity(palette.colors.isDark ? 0.03 : 0.025))
        .overlay(alignment: .top) { palette.softSeparator.frame(height: 1) }
    }
}

/// A stage, unstage or commit that failed, and what git said.
private struct GitWriteErrorBanner: View {
    let gitView: GitView
    let message: String
    let palette: Palette
    @Environment(\.interfaceFontSize) private var fontSize

    var body: some View {
        let red = palette.color(palette.colors.strong(palette.colors.red))
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").font(fontSize.font(13)).foregroundStyle(red)
            Text(message)
                .font(fontSize.font(12))
                .lineLimit(6)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("git-write-error")
            Button { gitView.dismissWriteError() } label: {
                Image(systemName: "xmark").font(fontSize.font(10, weight: .bold)).foregroundStyle(.secondary).frame(width: fontSize(18), height: fontSize(18))
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(maxWidth: fontSize(560))
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(palette.header))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(red.opacity(0.5)))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .padding(16)
    }
}

// MARK: - Pieces

private struct GitTag: View {
    enum Style {
        case gray
        case tint(NSColor)
    }

    let text: String
    var symbol: String?
    let style: Style
    let palette: Palette
    /// The tag's height and its text's size at 12, which grow with the Interface font size.
    var height: CGFloat = 19
    var fontSize: CGFloat = 11
    var onAccent = false
    @Environment(\.interfaceFontSize) private var interfaceFontSize

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(interfaceFontSize.font(fontSize - 1, weight: .semibold)) }
            Text(text).lineLimit(1)
        }
        .font(interfaceFontSize.font(fontSize, weight: .semibold))
        .foregroundStyle(foreground)
        .padding(.horizontal, height > 18 ? 8 : 6)
        .frame(height: interfaceFontSize(height))
        .background(Capsule().fill(background))
        .fixedSize()
    }

    private var foreground: Color {
        if onAccent { return .white }
        switch style {
        case .gray: return .secondary
        case .tint(let color): return palette.color(palette.colors.strong(color))
        }
    }

    private var background: Color {
        if onAccent { return .white.opacity(0.2) }
        switch style {
        case .gray: return palette.fill2
        case .tint(let color): return palette.color(palette.colors.tint(color))
        }
    }
}

/// A small app-icon-like tile for a file's type, `size` points square at 12. It sits beside the file's name, so it
/// grows with the Interface font size.
private struct GitFileTile: View {
    let path: String
    let size: CGFloat
    @Environment(\.gitOnAccent) private var onAccent
    @Environment(\.interfaceFontSize) private var interfaceFontSize

    var body: some View {
        let side = interfaceFontSize(size)
        let (symbol, colors) = Self.look((path as NSString).pathExtension.lowercased())
        if let colors {
            RoundedRectangle(cornerRadius: side * 0.24, style: .continuous)
                .fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
                .frame(width: side, height: side)
                .overlay(Image(systemName: symbol).font(.system(size: side * 0.6, weight: .semibold)).foregroundStyle(.white))
        } else {
            Image(systemName: symbol)
                .font(.system(size: side * 0.85))
                .foregroundStyle(onAccent ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                .frame(width: side, height: side)
        }
    }

    private static func look(_ ext: String) -> (String, [Color]?) {
        switch ext {
        case "swift": ("swift", [Color(red: 0.98, green: 0.6, blue: 0.25), Color(red: 0.94, green: 0.29, blue: 0.17)])
        case "md", "markdown": ("doc.text", [Color(red: 0.48, green: 0.55, blue: 0.64), Color(red: 0.4, green: 0.47, blue: 0.56)])
        case "json", "yml", "yaml", "toml", "plist": ("curlybraces", [Color(red: 0.45, green: 0.5, blue: 0.6), Color(red: 0.36, green: 0.41, blue: 0.5)])
        case "js", "ts", "tsx", "jsx", "mjs": ("curlybraces", [Color(red: 0.95, green: 0.78, blue: 0.2), Color(red: 0.86, green: 0.64, blue: 0.1)])
        case "sh", "bash", "zsh", "fish": ("terminal", [Color(red: 0.3, green: 0.32, blue: 0.36), Color(red: 0.2, green: 0.21, blue: 0.24)])
        case "py": ("chevron.left.forwardslash.chevron.right", [Color(red: 0.3, green: 0.5, blue: 0.8), Color(red: 0.2, green: 0.4, blue: 0.7)])
        default: ("doc", nil)
        }
    }
}

private struct GitIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.interfaceFontSize) private var fontSize

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(fontSize.font(14))
                .foregroundStyle(.secondary)
                .frame(width: fontSize(28), height: fontSize(28))
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(hovering ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

private struct GitKeyCap: View {
    let text: String
    let palette: Palette
    @Environment(\.interfaceFontSize) private var fontSize

    var body: some View {
        Text(text)
            .font(fontSize.font(10.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(minWidth: fontSize(18), minHeight: fontSize(17))
            .background(RoundedRectangle(cornerRadius: 4).fill(palette.fill2))
            .overlay(alignment: .bottom) { palette.separator.frame(height: 1).padding(.horizontal, 2) }
    }
}

private struct GitOnAccentKey: EnvironmentKey {
    static let defaultValue = false
}

private extension EnvironmentValues {
    /// A row on the accent-colored selection, where details turn white.
    var gitOnAccent: Bool {
        get { self[GitOnAccentKey.self] }
        set { self[GitOnAccentKey.self] = newValue }
    }
}

/// Takes keyboard focus for the Git View, so typing never reaches the
/// terminal underneath; WorkspaceStore's key monitor hands the keys to the
/// Git View.
private struct GitKeyCatcher: NSViewRepresentable {
    let gitView: GitView

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.gitView = gitView
        gitView.keyView = view
        return view
    }

    func updateNSView(_ view: KeyView, context: Context) {
        view.gitView = gitView
        gitView.keyView = view
    }

    final class KeyView: NSView {
        weak var gitView: GitView?

        override var acceptsFirstResponder: Bool { true }
        /// Keys the Git View doesn't use go nowhere, without a beep.
        override func keyDown(with event: NSEvent) {}
        override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in self?.gitView?.keyViewDidAppear() }
        }
    }
}

private extension GitDiffLine {
    /// `kind=added old=- new=3 marks=6..<9`: what the line is, its numbers,
    /// and the columns of its changed words, if any.
    var accessibilityValue: String {
        let kind = switch kind {
        case .context: "context"
        case .added: "added"
        case .removed: "removed"
        case .note: "note"
        }
        let marks = marks.isEmpty ? "" : " marks=" + marks.map { "\($0.lowerBound)..<\($0.upperBound)" }.joined(separator: ",")
        return "kind=\(kind) old=\(old.map(String.init) ?? "-") new=\(new.map(String.init) ?? "-")" + marks
    }
}
