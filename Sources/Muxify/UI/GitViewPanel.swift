import AppKit
import SwiftUI
import MuxifyCore

/// Hosts the Git View: a popup over the whole App Window, sidebar and
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
            switch (config.display, placement) {
            case (.fullscreen, .terminal):
                GitNavigator(gitView: gitView, colors: colors)
            case (.popup, .window):
                GeometryReader { proxy in
                    ZStack {
                        Color.black.opacity(colors.isDark ? 0.35 : 0.16)
                            .contentShape(Rectangle())
                            .onTapGesture { gitView.close() }
                        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
                        GitNavigator(gitView: gitView, colors: colors)
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

/// Xcode's source control navigator, in the Ghostty theme, with lazygit's
/// panels: a toolbar, the panels of changes, history, stashes and Diff
/// files, and the selection's diff.
private struct GitNavigator: View {
    @Bindable var gitView: GitView
    let colors: GitColors

    var body: some View {
        let palette = Palette(colors: colors)
        GeometryReader { proxy in
            VStack(spacing: 0) {
                if let snapshot = gitView.snapshot {
                    GitToolbar(gitView: gitView, snapshot: snapshot, palette: palette, isCompact: proxy.size.width < 900)
                    HStack(spacing: 0) {
                        GitSidebar(gitView: gitView, palette: palette)
                            .frame(width: min(380, max(240, proxy.size.width * 0.3)))
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
        .background(GitKeyCatcher(gitView: gitView))
        .environment(\.colorScheme, colors.isDark ? .dark : .light)
    }

    private func placeholder(_ palette: Palette) -> some View {
        VStack(spacing: 10) {
            if let error = gitView.error {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(error)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                Button("Close") { gitView.close() }
                    .keyboardShortcut(.cancelAction)
            } else {
                ProgressView().controlSize(.small)
                Text("Reading \(Paths.tildify(gitView.folder, home: gitView.store?.homeDirectory ?? Paths.home))…")
                    .font(.system(size: 13))
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
    @State private var showsBranches = false

    var body: some View {
        HStack(spacing: 10) {
            branchPill
            HStack(spacing: 6) {
                Image(systemName: "folder").font(.system(size: 13)).foregroundStyle(.secondary)
                Text(snapshot.repositoryName).font(.system(size: 13, weight: .semibold))
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
            if let comparison = snapshot.comparison { aheadBehind(comparison) }
            Spacer(minLength: 8)
            filterField
            Picker("Diff layout", selection: $gitView.layout) {
                Text("Unified").tag(GitView.Layout.unified)
                Text("Split").tag(GitView.Layout.split)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Show the diff unified or side by side")
            if gitView.isReading {
                ProgressView().controlSize(.small).frame(width: 28, height: 28)
            } else {
                GitIconButton(symbol: "arrow.clockwise", help: "Refresh (R)") { gitView.refresh(showingProgress: true) }
            }
            GitIconButton(symbol: "xmark", help: closeHelp) { gitView.close() }
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
        .background(palette.chrome)
        .overlay(alignment: .bottom) { palette.separator.frame(height: 1) }
    }

    private var closeHelp: String {
        let trigger = gitView.store?.config.keybinds.firstTrigger(for: .toggleGitView)
        return trigger.map { "Close (q, \($0.symbol))" } ?? "Close (q)"
    }

    /// The branch you're on; a click, or 3, lists the branches to compare.
    private var branchPill: some View {
        Button { showsBranches.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 14)).foregroundStyle(Color.accentColor)
                Text(snapshot.isDetached ? "detached at \(snapshot.head)" : snapshot.head)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.leading, 9)
            .padding(.trailing, 10)
            .frame(height: 28)
            .background(Capsule().fill(palette.fill))
            .overlay(Capsule().strokeBorder(palette.separator, lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Branches (3); what this one changes (1)")
        .popover(isPresented: $showsBranches, arrowEdge: .bottom) {
            GitBranchMenu(branches: snapshot.branches, current: currentBranch, palette: palette) { branch in
                showsBranches = false
                gitView.select(branch)
            }
        }
        .onChange(of: gitView.wantsBranches) { _, wants in
            guard wants else { return }
            gitView.wantsBranches = false
            showsBranches = true
        }
        .onChange(of: showsBranches) { _, shows in
            if !shows { gitView.focusKeyView() }
        }
    }

    private var currentBranch: String? {
        if case .branch(let branch)? = gitView.owner { return branch.name }
        return nil
    }

    private func aheadBehind(_ comparison: GitComparison) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.up").font(.system(size: 9, weight: .bold))
            Text(verbatim: "\(comparison.ahead)")
            Image(systemName: "arrow.down").font(.system(size: 9, weight: .bold)).padding(.leading, 3)
            Text(verbatim: "\(comparison.behind)")
            if !isCompact {
                Text("vs \(comparison.base)").font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary).padding(.leading, 4)
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .frame(height: 19)
        .background(Capsule().fill(palette.fill2))
        .help("Commits ahead of and behind \(comparison.base)")
    }

    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(.tertiary)
            TextField("", text: $gitView.filter, prompt: Text("Filter files, commits, stashes").foregroundColor(.secondary))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($filterFocused)
                .onSubmit { gitView.filterDidEnd() }
            if !gitView.filter.isEmpty {
                Button { gitView.filter = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .frame(minWidth: 140, idealWidth: 230, maxWidth: 230)
        .frame(height: 28)
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

/// The local branches, the current one first; j/k or the arrows and enter
/// pick one to compare.
private struct GitBranchMenu: View {
    let branches: [GitBranch]
    let current: String?
    let palette: Palette
    let choose: (GitBranch) -> Void
    @State private var highlighted = 0
    @FocusState private var isFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(branches.enumerated()), id: \.element.id) { index, branch in
                        row(branch, isHighlighted: index == highlighted)
                            .id(index)
                            .onHover { if $0 { highlighted = index } }
                            .onTapGesture { choose(branch) }
                    }
                }
                .padding(6)
            }
            .frame(width: 320, height: min(400, CGFloat(branches.count) * 26 + 12))
            .focusable()
            .focusEffectDisabled()
            .focused($isFocused)
            .onKeyPress(keys: [.downArrow, .upArrow, .return, "j", "k"]) { press in
                guard !branches.isEmpty else { return .ignored }
                switch press.key {
                case .downArrow, "j": highlighted = min(highlighted + 1, branches.count - 1)
                case .upArrow, "k": highlighted = max(highlighted - 1, 0)
                default: choose(branches[highlighted])
                }
                proxy.scrollTo(highlighted)
                return .handled
            }
            .onAppear {
                highlighted = branches.firstIndex { $0.name == current } ?? 0
                DispatchQueue.main.async { isFocused = true }
            }
        }
    }

    private func row(_ branch: GitBranch, isHighlighted: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: branch.isHead ? "checkmark" : "arrow.triangle.branch")
                .font(.system(size: 12, weight: branch.isHead ? .bold : .regular))
                .foregroundStyle(isHighlighted ? Color.white : branch.isHead ? Color.accentColor : Color.secondary)
                .frame(width: 14)
            Text(branch.name).fontWeight(branch.isHead ? .semibold : .regular).lineLimit(1)
            if branch.worktreePath != nil, !branch.isHead {
                GitTag(text: "worktree", style: .gray, palette: palette, height: 16, fontSize: 10, onAccent: isHighlighted)
            }
            Spacer(minLength: 16)
            if branch.ahead > 0 || branch.behind > 0 {
                Text(verbatim: "↑\(branch.ahead) ↓\(branch.behind)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(isHighlighted ? Color.white.opacity(0.85) : Color.secondary)
            }
            if let date = branch.date {
                Text(GitRepository.age(of: date))
                    .font(.system(size: 11))
                    .foregroundStyle(isHighlighted ? Color.white.opacity(0.85) : Color.secondary)
                    .frame(minWidth: 24, alignment: .trailing)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(isHighlighted ? Color.white : Color.primary)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(isHighlighted ? Color.accentColor : .clear))
        .contentShape(Rectangle())
        .help(branch.isHead ? "What \(branch.name) changes since it left main" : "What \(branch.name) has that your branch doesn't")
    }
}

// MARK: - Panels

/// lazygit's panels, stacked: the one with the keys gets the most room.
private struct GitSidebar: View {
    let gitView: GitView
    let palette: Palette

    static let headerHeight: CGFloat = 30
    static let rowHeight: CGFloat = 24
    private static let padding: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            let panels = gitView.panels
            let rows = panels.map { gitView.rows(in: $0) }
            // The History and Diff files take any room, so moving through
            // commits doesn't resize the panels; Diff files saying "No
            // changes" don't.
            let heights = GitView.panelHeights(
                wants: panels.indices.map { index in
                    let isNote = rows[index].count == 1 && rows[index][0].item == nil && rows[index][0].text != "Reading…"
                    return (panels[index] == .history || panels[index] == .files) && !isNote
                        ? nil : Self.headerHeight + CGFloat(max(1, rows[index].count)) * Self.rowHeight + Self.padding
                },
                weights: panels.map { $0 == gitView.panel ? 2 : 1 },
                minimum: Self.headerHeight + 2 * Self.rowHeight + Self.padding,
                total: proxy.size.height
            )
            VStack(spacing: 0) {
                ForEach(panels, id: \.self) { panel in
                    let index = panels.firstIndex(of: panel)!
                    GitPanelView(gitView: gitView, panel: panel, rows: rows[index], palette: palette, isFirst: index == 0)
                        .frame(height: max(0, heights[index]))
                }
                Spacer(minLength: 0)
            }
            .animation(.easeOut(duration: 0.16), value: gitView.panel)
            .animation(.easeOut(duration: 0.16), value: panels)
        }
    }
}

private struct GitPanelView: View {
    let gitView: GitView
    let panel: GitPanel
    let rows: [GitView.Row]
    let palette: Palette
    let isFirst: Bool

    private static let lane: CGFloat = 11

    var body: some View {
        let isActive = gitView.panel == panel
        let selection = gitView.selections[panel]
        let hasKeys = isActive && gitView.focus == .list
        let lanes = min(8, rows.compactMap { $0.graph?.width }.max() ?? 0)
        VStack(spacing: 0) {
            header(isActive: isActive)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            rowView(row, isSelected: row.item != nil && row.item?.id == selection, hasKeys: hasKeys,
                                    graphWidth: CGFloat(lanes) * Self.lane)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
                }
                .scrollIndicators(.automatic)
                .onChange(of: selection) { _, id in
                    if let id { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) } }
                }
                .onAppear {
                    if let selection { proxy.scrollTo(selection) }
                }
            }
        }
        .overlay(alignment: .top) {
            if !isFirst { palette.separator.frame(height: 1) }
        }
        .clipped()
    }

    private func header(isActive: Bool) -> some View {
        let count = gitView.count(in: panel)
        return HStack(spacing: 6) {
            Image(systemName: panel.symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .frame(width: 16)
            Text(panel.title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(isActive ? Color.primary : Color.secondary)
            if panel == .files, let owner = gitView.owner {
                Text(ownerName(owner))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Text(verbatim: "\(count)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 7)
                .frame(height: 18)
                .background(Capsule().fill(isActive ? Color.accentColor.opacity(0.15) : palette.fill2))
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .frame(height: GitSidebar.headerHeight)
        .contentShape(Rectangle())
        .onTapGesture { gitView.activate(panel) }
        .help(panel.key.map { "\(panel.title) (\($0), tab for the next panel)" } ?? "The files of the selection (enter on a commit or stash, esc to go back)")
    }

    private func ownerName(_ owner: GitView.Item) -> String {
        switch owner {
        case .commit(let commit): String(commit.sha.prefix(7))
        case .stash(let stash): stash.ref
        case .branch(let branch): branch.name
        default: ""
        }
    }

    @ViewBuilder
    private func rowView(_ row: GitView.Row, isSelected: Bool, hasKeys: Bool, graphWidth: CGFloat) -> some View {
        if let item = row.item {
            let onAccent = isSelected && hasKeys
            itemRow(item, row: row, onAccent: onAccent, graphWidth: graphWidth)
                .padding(.leading, 6 + CGFloat(row.depth) * 14)
                .padding(.trailing, 8)
                .frame(height: GitSidebar.rowHeight)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(onAccent ? Color.accentColor : Color.primary.opacity(0.1))
                    }
                }
                .foregroundStyle(onAccent ? Color.white : Color.primary)
                .environment(\.gitOnAccent, onAccent)
                .contentShape(Rectangle())
                .onTapGesture { gitView.select(item, in: panel) }
                .id(row.id)
        } else {
            Text(row.text)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .padding(.leading, 14)
                .frame(height: 22)
                .id(row.id)
        }
    }

    @ViewBuilder
    private func itemRow(_ item: GitView.Item, row: GitView.Row, onAccent: Bool, graphWidth: CGFloat) -> some View {
        let secondary = onAccent ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(.tertiary)
        let mono = Font.system(size: 11, design: .monospaced)
        HStack(spacing: 6) {
            switch item {
            case .folder(let tree, let path):
                let isOpen = gitView.collapsedFolders[tree]?.contains(path) != true || !gitView.filter.isEmpty
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(secondary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .frame(width: 12, height: 20)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.easeOut(duration: 0.12)) { gitView.toggleFolder(path, in: tree) } }
                Image(systemName: "folder.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(onAccent ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                Text(row.text).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
            case .change(let change):
                Color.clear.frame(width: 12)
                status(change, onAccent: onAccent)
                GitFileTile(path: change.path, size: 15)
                Text(change.name)
                    .font(.system(size: 13))
                    .foregroundStyle(onAccent ? Color.white : change.isStaged ? palette.staged : palette.unstaged)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                counts(change.additions, change.deletions, onAccent: onAccent)
            case .file(let path):
                let file = gitView.ownerFiles?.first { $0.path == path }
                let letter = Self.letter(file?.change)
                Color.clear.frame(width: 12)
                Text(letter.text)
                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(onAccent ? Color.white : palette.color(palette.colors.strong(letter.color(palette.colors))))
                    .frame(width: 12)
                GitFileTile(path: path, size: 15)
                Text((path as NSString).lastPathComponent).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                counts(file?.isBinary == true ? nil : file?.additions, file?.deletions, onAccent: onAccent)
            case .commit(let commit):
                if let graph = row.graph {
                    GitGraphCell(row: graph, isMerge: commit.isMerge, palette: palette, lane: Self.lane)
                        .frame(width: graphWidth, height: GitSidebar.rowHeight, alignment: .leading)
                        .clipped()
                }
                Text(String(commit.sha.prefix(7)))
                    .font(mono)
                    .foregroundStyle(onAccent ? Color.white.opacity(0.85) : palette.color(palette.colors.strong(Self.color(commit.status, palette.colors))))
                    .fixedSize()
                refs(commit, onAccent: onAccent)
                Text(commit.subject).font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Text(GitRepository.age(of: commit.date)).font(.system(size: 11)).foregroundStyle(secondary)
            case .stash(let stash):
                Text(stash.ref).font(mono).foregroundStyle(secondary)
                Text(GitNavigatorText.stashTitle(stash.message)).font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Text(GitRepository.age(of: stash.date)).font(.system(size: 11)).foregroundStyle(secondary)
            case .branch:
                EmptyView()
            }
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

    /// `M ` green, ` M` red, `MM` both, `??` red: lazygit's letters.
    private func status(_ change: GitChange, onAccent: Bool) -> some View {
        HStack(spacing: 0) {
            Text(String(change.index))
                .foregroundStyle(onAccent ? Color.white : change.isUntracked || change.isConflict ? palette.unstaged : palette.staged)
            Text(String(change.worktree))
                .foregroundStyle(onAccent ? Color.white : palette.unstaged)
        }
        .font(.system(size: 11.5, weight: .bold, design: .monospaced))
        .frame(width: 16, alignment: .leading)
        .help(Self.statusHelp(change))
    }

    private static func statusHelp(_ change: GitChange) -> String {
        if change.isUntracked { return "Untracked" }
        if change.isConflict { return "Conflict" }
        return change.groups.map { $0 == .staged ? "Staged" : "Unstaged" }.joined(separator: " and ")
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
        .font(.system(size: 11, design: .monospaced))
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
            let dot = Path(ellipseIn: CGRect(x: x(row.lane) - 4, y: middle - 4, width: 8, height: 8))
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

    private static let space = "gitDiff"
    private var fontSize: CGFloat { gitView.fontSize }
    private var lineHeight: CGFloat { (fontSize * 1.6).rounded() }

    var body: some View {
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
                                rowView(row)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollPosition(id: $gitView.scrollRow, anchor: .top)
                    .scrollIndicators(.automatic)
                    .coordinateSpace(.named(Self.space))
                    .background(GeometryReader { geometry in
                        Color.clear
                            .onAppear { measure(geometry.size) }
                            .onChange(of: geometry.size) { _, size in measure(size) }
                    })
                    // Keys moved the cursor out of sight: scroll just enough.
                    .onChange(of: gitView.cursor) { _, cursor in
                        guard let cursor, !isDragging else { return }
                        if let frame = gitView.lineFrames[cursor], frame.minY >= 0, frame.maxY <= gitView.diffHeight { return }
                        proxy.scrollTo(cursor)
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
            if gitView.panel == .changes, gitView.snapshot?.changes.isEmpty == true {
                Image(systemName: "checkmark.circle").font(.system(size: 28, weight: .light)).foregroundStyle(.tertiary)
                Text("Working tree clean").font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.background)
    }

    @ViewBuilder
    private func rowView(_ row: GitView.DiffRow) -> some View {
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
                hunkHeader(hunk)
            }
        case .line(let line):
            selectable(row) { unifiedLine(line) }
        case .pair(let old, let new):
            selectable(row) {
                HStack(spacing: 0) {
                    splitSide(old, number: old?.old)
                    palette.softSeparator.frame(width: 1)
                    splitSide(new, number: new?.new)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        case .binary:
            note("Binary file not shown")
        case .wholeFile:
            bar(symbol: "arrow.up.and.down.text.horizontal", text: "Show the whole file") { gitView.showWholeFile() }
        case .endOfFile:
            endOfFile
        case .omitted(let count):
            note("\(count) more lines not shown")
        case .message(let text):
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Selecting

    /// A line that a click selects, shift-click extends and dragging
    /// selects to; on a split diff, on the side clicked.
    private func selectable<Line: View>(_ row: GitView.DiffRow, @ViewBuilder line: () -> Line) -> some View {
        let isSplit = gitView.layout == .split
        return line()
            .overlay {
                if gitView.isLineSelected(row.id) {
                    HStack(spacing: 0) {
                        if isSplit, gitView.side == .new { Color.clear }
                        Color.accentColor.opacity(0.2)
                            .overlay(alignment: .leading) { Color.accentColor.frame(width: 2) }
                        if isSplit, gitView.side == .old { Color.clear }
                    }
                    .allowsHitTesting(false)
                }
            }
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
                        if isDragging {
                            gitView.dragLine(to: value.location)
                        } else {
                            isDragging = true
                            let side: GitView.Side = isSplit && value.startLocation.x < gitView.diffWidth / 2 ? .old : .new
                            gitView.pressLine(row.id, side: side, extending: NSEvent.modifierFlags.contains(.shift))
                        }
                    }
                    .onEnded { _ in isDragging = false }
            )
    }

    // MARK: Lines

    private var codeFont: Font { .system(size: fontSize, design: .monospaced) }
    private var numberFont: Font { .system(size: fontSize - 1, design: .monospaced) }

    private func unifiedLine(_ line: GitDiffLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            number(line.old)
            number(line.new)
            marker(line.kind)
            code(line)
        }
        .frame(minHeight: lineHeight)
        .background {
            HStack(spacing: 0) {
                band(line.kind, gutter: true).frame(width: 92)
                band(line.kind, gutter: false)
            }
        }
    }

    @ViewBuilder
    private func splitSide(_ line: GitDiffLine?, number value: Int?) -> some View {
        Group {
            if let line {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    number(line.kind == .note ? nil : value)
                    marker(line.kind)
                    code(line)
                }
                .background {
                    HStack(spacing: 0) {
                        band(line.kind, gutter: true).frame(width: 46)
                        band(line.kind, gutter: false)
                    }
                }
            } else {
                palette.fill
            }
        }
        .frame(maxWidth: .infinity, minHeight: lineHeight, maxHeight: .infinity, alignment: .leading)
    }

    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .font(numberFont)
            .foregroundStyle(palette.dim)
            .lineLimit(1)
            .padding(.trailing, 9)
            .frame(width: 46, alignment: .trailing)
    }

    private func marker(_ kind: GitDiffLine.Kind) -> some View {
        Text(kind == .added ? "+" : kind == .removed ? "−" : " ")
            .font(codeFont)
            .foregroundStyle(kind == .added ? palette.color(palette.colors.addedText) : palette.color(palette.colors.removedText))
            .frame(width: 18)
    }

    private func code(_ line: GitDiffLine) -> some View {
        Text(line.kind == .note ? AttributedString(line.text) : line.styled ?? AttributedString(line.text))
            .font(codeFont)
            .italic(line.kind == .note)
            .foregroundStyle(line.kind == .note ? palette.dim : palette.code)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 12)
            .padding(.vertical, (lineHeight - fontSize * 1.25) / 2)
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
    /// whole file.
    private func hunkHeader(_ hunk: GitHunk) -> some View {
        let canExpand = gitView.diffRows.contains { if case .wholeFile = $0.kind { true } else { false } }
        return HStack(spacing: 10) {
            Button { gitView.showWholeFile() } label: {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .opacity(canExpand ? 1 : 0)
                    .frame(width: 92, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canExpand)
            .help("Show the whole file")
            Text(hunk.header.replacingOccurrences(of: "-", with: "−"))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .fixedSize()
            Text(hunk.styledContext ?? AttributedString(hunk.context))
                .font(.system(size: fontSize - 0.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(height: 30)
        .background(palette.fill)
        .overlay(alignment: .top) { palette.softSeparator.frame(height: 1) }
        .overlay(alignment: .bottom) { palette.softSeparator.frame(height: 1) }
    }

    /// Above the unstaged and the staged part of a change with both.
    private func partBar(_ group: GitChange.Group) -> some View {
        HStack(spacing: 8) {
            Circle().fill(group == .staged ? palette.staged : palette.unstaged).frame(width: 7, height: 7)
            Text("\(group.title) changes").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.leading, 18)
        .frame(height: 30)
        .background(palette.header)
        .overlay(alignment: .bottom) { palette.separator.frame(height: 1) }
    }

    private func bar(symbol: String, text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 12)).frame(width: 92)
                Text(text).font(.system(size: 12))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .frame(height: 30)
            .background(palette.fill)
            .overlay(alignment: .top) { palette.softSeparator.frame(height: 1) }
            .overlay(alignment: .bottom) { palette.softSeparator.frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
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
                    Button(Self.name(next)) { gitView.select(next, in: gitView.panel) }.buttonStyle(.link)
                }
                if let previous = gitView.neighbor(forward: false) {
                    GitKeyCap(text: "[", palette: palette).padding(.leading, 10)
                    Text("previous:").foregroundStyle(.tertiary)
                    Button(Self.name(previous)) { gitView.select(previous, in: gitView.panel) }.buttonStyle(.link)
                }
            }
        }
        .font(.system(size: 12))
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
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                GitIconButton(symbol: "arrow.up", help: "Previous hunk (⌥↑)") { gitView.jumpToHunk(forward: false) }
                GitIconButton(symbol: "arrow.down", help: "Next hunk (⌥↓)") { gitView.jumpToHunk(forward: true) }
            }
        }
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
    }
}

private struct GitPathBar<Tags: View, Trailing: View>: View {
    let path: String
    let additions: Int
    let deletions: Int
    let palette: Palette
    let height: CGFloat
    @ViewBuilder let tags: Tags
    @ViewBuilder let trailing: Trailing

    var body: some View {
        let folder = (path as NSString).deletingLastPathComponent
        HStack(spacing: 10) {
            GitFileTile(path: path, size: 14)
            HStack(spacing: 0) {
                if !folder.isEmpty { Text(folder + "/").foregroundStyle(.secondary) }
                Text((path as NSString).lastPathComponent).fontWeight(.semibold)
            }
            .font(.system(size: 13))
            .lineLimit(1)
            .truncationMode(.head)
            stat("+\(additions)", additions > 0 ? (palette.colors.addedText, palette.colors.addedLine) : nil)
            stat("−\(deletions)", deletions > 0 ? (palette.colors.removedText, palette.colors.removedLine) : nil)
            tags
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 14)
        .frame(height: height)
        .background(palette.header)
        .overlay(alignment: .bottom) { palette.separator.frame(height: 1) }
    }

    /// Gray for a zero count.
    private func stat(_ text: String, _ colors: (text: NSColor, background: NSColor)?) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(colors.map { AnyShapeStyle(palette.color($0.text)) } ?? AnyShapeStyle(.tertiary))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(colors.map { palette.color($0.background) } ?? palette.fill2))
            .fixedSize()
    }
}

/// Above a commit's, branch's, stash's or folder's files: what it is, who
/// made it, and how much it changes.
private struct GitCard: View {
    let gitView: GitView
    let content: GitView.Content
    let palette: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch content.header {
            case .commit(let commit, let detail):
                commitCard(commit, detail)
            case .branch(let branch, let base, let commits):
                branchCard(branch, base: base, commits: commits)
            case .stash(let stash):
                stashCard(stash)
            case .folder(let path, let changes):
                folderCard(path, changes)
            case .change:
                EmptyView()
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.header)
        .overlay(alignment: .bottom) { palette.separator.frame(height: 1) }
    }

    private func commitCard(_ commit: GitCommit, _ detail: GitCommitDetail?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(detail?.title ?? commit.subject)
                .font(.system(size: 17, weight: .semibold))
                .textSelection(.enabled)
            if let body = detail?.body, !body.isEmpty {
                Text(body)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(8)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                avatar(commit.initials, name: commit.author)
                Text(commit.author).font(.system(size: 13, weight: .semibold))
                Text("committed \(GitNavigatorText.relative(commit.date))").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                hashChip(commit.sha)
                if let parents = detail?.parents, !parents.isEmpty {
                    Text(parents.count == 1 ? "parent" : "parents").font(.system(size: 12)).foregroundStyle(.tertiary)
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

    private func branchCard(_ branch: GitBranch, base: String?, commits: [GitCommit]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: branch.isHead ? "checkmark" : "arrow.triangle.branch")
                    .font(.system(size: 15, weight: branch.isHead ? .bold : .regular))
                    .foregroundStyle(branch.isHead ? Color.accentColor : Color.secondary)
                Text(branch.name).font(.system(size: 17, weight: .semibold)).textSelection(.enabled)
                if let upstream = branch.upstream {
                    GitTag(text: upstream, symbol: "cloud", style: branch.isInSync ? .tint(palette.colors.green) : .gray, palette: palette)
                }
            }
            Text(subtitle(branch, base: base, count: commits.count))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            if !commits.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(commits.prefix(12)) { commit in
                        HStack(spacing: 8) {
                            avatar(commit.initials, name: commit.author, size: 16)
                            Text(String(commit.sha.prefix(7))).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                            Text(commit.subject).font(.system(size: 13)).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(GitRepository.age(of: commit.date)).font(.system(size: 11)).foregroundStyle(.tertiary)
                        }
                        .frame(height: 22)
                    }
                    if commits.count > 12 {
                        Text(verbatim: "and \(commits.count - 12) more").font(.system(size: 12)).foregroundStyle(.tertiary).frame(height: 20)
                    }
                }
            }
            if base != nil { summary }
        }
    }

    private func subtitle(_ branch: GitBranch, base: String?, count: Int) -> String {
        guard let base else { return "The branch you're on. Its latest commits:" }
        let commits = count == 0 ? "No commits" : count == 1 ? "1 commit" : "\(count >= 50 ? "50+" : String(count)) commits"
        return "\(commits) on \(branch.name) that \(base) doesn't have. Below, what \(branch.name) changes since it left \(base)."
    }

    private func stashCard(_ stash: GitStash) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(GitNavigatorText.stashTitle(stash.message))
                .font(.system(size: 17, weight: .semibold))
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Image(systemName: "archivebox").foregroundStyle(.secondary)
                Text(stash.message.components(separatedBy: ": ").first ?? "").font(.system(size: 13, weight: .semibold))
                Text("stashed \(GitNavigatorText.relative(stash.date))").font(.system(size: 13)).foregroundStyle(.secondary)
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
                Image(systemName: "folder.fill").font(.system(size: 15)).foregroundStyle(.secondary)
                Text(path + "/").font(.system(size: 17, weight: .semibold)).textSelection(.enabled)
            }
            Text(verbatim: "\(changes.count) changed file\(changes.count == 1 ? "" : "s") in this folder"
                 + (staged > 0 ? ", \(staged) of them staged" : ""))
                .font(.system(size: 13))
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
            Text(verbatim: "\(count) file\(count == 1 ? "" : "s") changed").font(.system(size: 13)).foregroundStyle(.secondary)
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
        .font(.system(size: 12, weight: .semibold, design: .monospaced))
    }

    private func avatar(_ initials: String, name: String, size: CGFloat = 22) -> some View {
        Circle()
            .fill(palette.color(palette.colors.author(name)).gradient)
            .frame(width: size, height: size)
            .overlay(Text(initials).font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(.white))
    }

    /// Copies the full hash.
    private func hashChip(_ sha: String) -> some View {
        Button { gitView.copy(sha, title: "Copied Hash", shown: String(sha.prefix(8))) } label: {
            HStack(spacing: 5) {
                Text(String(sha.prefix(8))).font(.system(size: 11.5, design: .monospaced))
                Image(systemName: "doc.on.doc").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(palette.fill2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Copy \(sha)")
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
    var height: CGFloat = 19
    var fontSize: CGFloat = 11
    var onAccent = false

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: fontSize - 1, weight: .semibold)) }
            Text(text).lineLimit(1)
        }
        .font(.system(size: fontSize, weight: .semibold))
        .foregroundStyle(foreground)
        .padding(.horizontal, height > 18 ? 8 : 6)
        .frame(height: height)
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

/// A small app-icon-like tile for a file's type.
private struct GitFileTile: View {
    let path: String
    let size: CGFloat
    @Environment(\.gitOnAccent) private var onAccent

    var body: some View {
        let (symbol, colors) = Self.look((path as NSString).pathExtension.lowercased())
        if let colors {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
                .frame(width: size, height: size)
                .overlay(Image(systemName: symbol).font(.system(size: size * 0.6, weight: .semibold)).foregroundStyle(.white))
        } else {
            Image(systemName: symbol)
                .font(.system(size: size * 0.85))
                .foregroundStyle(onAccent ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                .frame(width: size, height: size)
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

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
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

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(minWidth: 18, minHeight: 17)
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
