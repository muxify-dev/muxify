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
    @State private var ports: [Int] = []
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if tab.isFindShown {
                FindBar(tab: tab, onClose: closeFind)
                Divider()
            }
            ZStack {
                WebViewHost(tab: tab)
                if !tab.hasPage { emptyState }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            address = tab.urlString
            scanPorts()
            consumeFocusRequest()
        }
        .onChange(of: tab.urlString) { _, newValue in
            if !addressFocused { address = newValue }
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
                .accessibilityIdentifier("browser-address")
                .accessibilityAction(named: "Submit", submit)
                .onExitCommand {
                    address = tab.urlString
                    focusPage()
                }
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
        tab.open(address)
        focusPage()
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

/// Find in Page for the active Tab, between its toolbar and its page (ADR-0033).
private struct FindBar: View {
    @Bindable var tab: BrowserTab
    let onClose: () -> Void

    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            TextField("Find in Page", text: $tab.findQuery)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
                .focused($fieldFocused)
                .onSubmit {
                    if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { tab.findPrevious() } else { tab.findNext() }
                }
                .onExitCommand(perform: onClose)
                .accessibilityIdentifier("browser-find-field")
            Text(status)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .accessibilityIdentifier("browser-find-status")
            HStack(spacing: 2) {
                Button(action: tab.findPrevious) { Image(systemName: "chevron.left") }
                    .help("Find Previous (⌘⇧G)")
                    .accessibilityLabel("Find Previous")
                    .accessibilityIdentifier("browser-find-previous")
                Button(action: tab.findNext) { Image(systemName: "chevron.right") }
                    .help("Find Next (⌘G)")
                    .accessibilityLabel("Find Next")
                    .accessibilityIdentifier("browser-find-next")
            }
            .disabled(tab.findQuery.isEmpty)
            Spacer(minLength: 0)
            Button("Done", action: onClose)
                .accessibilityIdentifier("browser-find-done")
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Color.primary.opacity(0.035))
        .onAppear(perform: consumeFocusRequest)
        .onChange(of: tab.findFieldFocusRequested) { _, _ in consumeFocusRequest() }
    }

    private var status: String {
        switch tab.findStatus {
        case .idle: ""
        case .notFound: "Not found"
        case let .match(index, total): "\(index + 1) of \(total)"
        }
    }

    private func consumeFocusRequest() {
        guard tab.findFieldFocusRequested else { return }
        tab.findFieldFocusRequested = false
        DispatchQueue.main.async {
            fieldFocused = true
            DispatchQueue.main.async { (tab.webView.window?.firstResponder as? NSText)?.selectAll(nil) }
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
