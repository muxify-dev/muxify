import SwiftUI
import WebKit
import MuxifyCore

/// A Window's Browser: a tab strip over the active Tab's toolbar and page.
struct BrowserPanel: View {
    let browser: Browser

    var body: some View {
        VStack(spacing: 0) {
            TabStrip(browser: browser)
            Divider()
            if let tab = browser.activeTab {
                TabContent(browser: browser, tab: tab)
                    .id(tab.id)
            } else {
                Color(nsColor: .windowBackgroundColor)
            }
        }
    }
}

// MARK: - Tab strip

private struct TabStrip: View {
    let browser: Browser

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(browser.tabs) { tab in
                        TabItem(
                            tab: tab,
                            isActive: tab.id == browser.activeTabID,
                            width: tabWidth(available: proxy.size.width),
                            onSelect: {
                                browser.select(tab)
                                browser.requestFocus()
                            },
                            onClose: { browser.close(tab) }
                        )
                    }
                    ToolbarIconButton(systemName: "plus", help: "New Tab (⌘T)", action: browser.newTab)
                }
                .padding(.horizontal, 8)
                .frame(height: proxy.size.height)
            }
        }
        .frame(height: 36)
        .background(WindowDragArea())
        .background(Color.primary.opacity(0.035))
    }

    /// Tabs share the strip like Chrome's, between a readable minimum and a
    /// maximum; past the minimum the strip scrolls.
    private func tabWidth(available: CGFloat) -> CGFloat {
        let count = CGFloat(max(browser.tabs.count, 1))
        let room = available - 16 - 30 - 4 * count
        return min(220, max(110, room / count))
    }
}

private struct TabItem: View {
    let tab: BrowserTab
    let isActive: Bool
    let width: CGFloat
    let onSelect: () -> Void
    let onClose: () -> Void

    @Environment(\.quickSwitchHints) private var hints
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if tab.isLoading {
                    ProgressView().controlSize(.mini)
                } else if hints[.tab(tab.id)].isEmpty, let key = hints.restKey(for: .tab(tab.id)) {
                    HintKey(target: .tab(tab.id), key: key)
                } else {
                    Image(systemName: "globe")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 14)
            Text(tab.displayTitle)
                    .accessibilityIdentifier("browser-tab-title-" + tab.id.uuidString)
                .font(.system(size: 12))
                .foregroundStyle(isActive ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(isActive || hovering ? 1 : 0)
            .help("Close Tab (⌘W)")
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(width: width, height: 26)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(background)
                .shadow(color: .black.opacity(isActive ? 0.08 : 0), radius: 1, y: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onTapGesture(perform: onSelect)
        .takesFirstClick()
        .onHover { hovering = $0 }
        .help(tab.hasPage ? tab.urlString : "New Tab")
        .opacity(hints[.tab(tab.id)].isEmpty ? 1 : 0.5)
        .overlay(alignment: .leading) {
            if !hints[.tab(tab.id)].isEmpty {
                HintBadge(target: .tab(tab.id), triggers: hints[.tab(tab.id)]).padding(.leading, 4)
            }
        }
    }

    private var background: Color {
        if isActive { return Color(nsColor: .controlBackgroundColor) }
        return hovering ? Color.primary.opacity(0.06) : .clear
    }
}

// MARK: - Active Tab

/// The active Tab's navigation row, omnibox and page.
private struct TabContent: View {
    let browser: Browser
    let tab: BrowserTab

    @State private var address = ""
    /// While the address field has Focus: the typed text and its Suggestions.
    @State private var edit: AddressEdit?
    @State private var ports: [Int] = []
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if tab.isFindShown {
                // Find in Page, between the toolbar and the page (ADR-0033).
                FindBar(finder: tab, placeholder: "Find in Page", identifier: "browser-find",
                        window: { tab.webView.window }, onClose: closeFind)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(Color.primary.opacity(0.035))
                Divider()
            }
            ZStack {
                WebViewHost(tab: tab)
                if !tab.hasPage { emptyState }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlayPreferenceValue(AddressFieldBounds.self) { anchor in
            if let anchor, addressFocused, let edit, edit.showsList {
                GeometryReader { proxy in
                    let field = proxy[anchor]
                    SuggestionList(suggestions: edit.suggestions, selection: edit.selection, open: open)
                        .frame(width: field.width)
                        .offset(x: field.minX, y: field.maxY + 4)
                }
            }
        }
        .onAppear {
            address = tab.urlString
            scanPorts()
            consumeFocusRequest()
        }
        .onChange(of: tab.urlString) { _, newValue in
            if !addressFocused { address = newValue }
        }
        .onChange(of: addressFocused) { _, focused in
            edit = focused ? AddressEdit(url: tab.urlString) : nil
        }
        .onChange(of: address) { _, newValue in
            guard addressFocused else { return }
            var next = edit ?? AddressEdit(url: tab.urlString)
            next.textChanged(to: newValue, suggest: suggestions)
            edit = next
            if next.text != newValue { showEdit() }
        }
        .onChange(of: browser.focusRequest) { _, _ in consumeFocusRequest() }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 4) {
            ToolbarIconButton(systemName: "chevron.left", help: "Back", action: tab.goBack)
                .disabled(!tab.canGoBack)
                .accessibilityIdentifier("browser-back")
            ToolbarIconButton(systemName: "chevron.right", help: "Forward", action: tab.goForward)
                .disabled(!tab.canGoForward)
                .accessibilityIdentifier("browser-forward")
            ToolbarIconButton(
                systemName: tab.isLoading ? "xmark" : "arrow.clockwise",
                help: tab.isLoading ? "Stop" : "Reload",
                action: tab.reloadOrStop
            )
            .disabled(!tab.hasPage)

            addressField
                .padding(.horizontal, 4)

            Menu {
                Button("Open in Default Browser", action: tab.openInDefaultBrowser).disabled(!tab.hasPage)
                Button("Copy URL", action: tab.copyURL).disabled(!tab.hasPage)
                Button("Show Developer Tools", action: tab.showDeveloperTools).disabled(!tab.hasPage)
                Divider()
                Button("Close Tab") { browser.close(tab) }
                Button("Hide Browser") { browser.toggle(.browser) }
                    .disabled(!browser.layout.canToggle(.browser))
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .overlay(alignment: .bottom) { progressBar }
    }

    private var addressField: some View {
        HStack(spacing: 6) {
            Image(systemName: addressIcon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search or enter URL", text: $address)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($addressFocused)
                .onSubmit(submit)
                .onKeyPress(phases: [.down, .repeat], action: listKey)
                .accessibilityIdentifier("browser-address")
                .accessibilityAction(named: "Submit", submit)
                .onExitCommand(perform: escape)
                .anchorPreference(key: AddressFieldBounds.self, value: .bounds) { $0 }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.8))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(
                    addressFocused ? Color.accentColor : Color.primary.opacity(0.14),
                    lineWidth: addressFocused ? 2 : 1
                )
        )
        .contentShape(Rectangle())
        .onTapGesture { addressFocused = true }
    }

    private var addressIcon: String {
        if addressFocused || !tab.hasPage { return "magnifyingglass" }
        return tab.urlString.hasPrefix("https://") ? "lock.fill" : "globe"
    }

    @ViewBuilder
    private var progressBar: some View {
        if tab.isLoading {
            GeometryReader { proxy in
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: max(8, proxy.size.width * tab.progress), height: 2)
                    .animation(.easeOut(duration: 0.2), value: tab.progress)
            }
            .frame(height: 2)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "globe")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Search or enter a URL")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
            if !ports.isEmpty {
                VStack(spacing: 8) {
                    Text("Listening in this tmux window")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    HStack(spacing: 8) {
                        ForEach(ports.prefix(6), id: \.self) { port in
                            // Concatenate, so the port isn't locale-formatted ("61.890").
                            Button("localhost:" + String(port)) {
                                tab.open("http://localhost:\(port)")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                .padding(.top, 6)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Actions

    private func submit() {
        switch edit?.target ?? .text(address) {
        case .suggestion(let suggestion): open(suggestion)
        case .text(let text):
            edit = nil
            tab.open(text)
            focusPage()
        }
    }

    /// An open Tab is shown, not loaded again. Every other Suggestion loads in this Tab as a typed visit.
    private func open(_ suggestion: Suggestion) {
        edit = nil
        if case .tab(let id, _, _) = suggestion, let other = browser.tabs.first(where: { $0.id == id }) {
            address = tab.urlString
            browser.jumpTo(other)
            return
        }
        guard let url = URL(string: suggestion.url) else { return }
        tab.load(url, typed: true)
        focusPage()
    }

    /// ↓ and ↑, or ⌃N and ⌃P, select a Suggestion while the list shows.
    private func listKey(_ press: KeyPress) -> KeyPress.Result {
        let step: Int
        if press.modifiers.isDisjoint(with: [.command, .option, .control, .shift]), press.key == .downArrow || press.key == .upArrow {
            step = press.key == .downArrow ? 1 : -1
        } else if press.modifiers.intersection([.command, .option, .control, .shift]) == .control,
                  ["n", "p", "\u{0e}", "\u{10}"].contains(press.key.character) {
            step = press.key.character == "n" || press.key.character == "\u{0e}" ? 1 : -1
        } else {
            return .ignored
        }
        guard var next = edit, next.move(step) else { return .ignored }
        edit = next
        showEdit()
        return .handled
    }

    /// ⎋ closes the list first, then gives back the Tab's URL.
    private func escape() {
        if var next = edit, next.escape() {
            edit = next
            return
        }
        address = tab.urlString
        focusPage()
    }

    /// Shows the edit's text in the field, with the Inline completion selected, so that typing goes on over it.
    private func showEdit() {
        guard let edit else { return }
        address = edit.text
        let selection = edit.completion ?? NSRange(location: edit.text.utf16.count, length: 0)
        DispatchQueue.main.async {
            guard addressFocused, let editor = tab.webView.window?.firstResponder as? NSTextView else { return }
            if editor.string != edit.text { editor.string = edit.text }
            editor.setSelectedRange(selection)
        }
    }

    private func suggestions(for query: String) -> [Suggestion] {
        let tabs = browser.tabs.filter { $0.id != tab.id && $0.hasPage }
            .map { LiveRows.OpenTab(id: $0.id, url: $0.urlString, title: $0.title) }
        return browser.history.suggestions(for: query, live: LiveRows(tabs: tabs, ports: ports), activeTopic: browser.topicID())
    }

    /// Only explicit requests (opening the panel, ⌘L, Maximize, Focus Browser)
    /// take Focus; merely switching tmux windows keeps it in the Terminal.
    private func consumeFocusRequest() {
        guard let request = browser.focusRequest else { return }
        browser.focusRequest = nil
        switch request {
        case .addressBar: DispatchQueue.main.async { addressFocused = true }
        case .page: focusPage()
        }
    }

    private func closeFind() {
        tab.closeFind()
        focusPage()
    }

    private func focusPage() {
        addressFocused = false
        DispatchQueue.main.async {
            guard tab.webView.window?.makeFirstResponder(tab.webView) == true else { return }
            BrowserPageScripts.focusMainPart(of: tab.webView)
        }
    }

    private func scanPorts() {
        guard browser.discoversLocalServers else { return }
        DevServerScanner.scan(windowID: browser.windowID) { ports = $0 }
    }
}

private struct AddressFieldBounds: PreferenceKey {
    static var defaultValue: Anchor<CGRect>?
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
}

/// The Suggestions under the address field. A click opens one; the list never takes Focus from the field.
private struct SuggestionList: View {
    let suggestions: [Suggestion]
    let selection: Int?
    let open: (Suggestion) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.offset) { index, suggestion in
                Button { open(suggestion) } label: {
                    SuggestionRow(suggestion: suggestion, isSelected: index == selection)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .accessibilityIdentifier("browser-suggestion-\(index)")
                .accessibilityLabel(suggestion.display)
                .accessibilityValue(suggestion.url)
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("browser-suggestions")
    }
}

private struct SuggestionRow: View {
    let suggestion: Suggestion
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isSelected ? .white : .secondary)
                .frame(width: 16)
            Text(suggestion.title.isEmpty ? suggestion.display : suggestion.title)
                .font(.system(size: 13))
                .foregroundStyle(isSelected ? .white : .primary)
                .lineLimit(1)
            if !suggestion.title.isEmpty, !isSearch {
                Text(suggestion.display)
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor : .clear)
        )
        .contentShape(Rectangle())
    }

    private var isSearch: Bool {
        if case .search = suggestion { return true }
        return false
    }

    private var icon: String {
        switch suggestion {
        case .page: "clock"
        case .prefix: "globe"
        case .tab: "square.on.square"
        case .devServer: "server.rack"
        case .search: "magnifyingglass"
        }
    }
}

/// Hosts a Tab's long-lived page and any docked inspector. Their shared parent
/// is re-parented rather than recreated, so both survive switching Tabs and Windows.
private struct WebViewHost: NSViewRepresentable {
    let tab: BrowserTab

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        attach(to: container)
    }

    private func attach(to container: NSView) {
        let pageView = tab.pageView
        guard pageView.superview !== container else { return }
        pageView.removeFromSuperview()
        pageView.frame = container.bounds
        pageView.autoresizingMask = [.width, .height]
        container.addSubview(pageView)
    }
}
