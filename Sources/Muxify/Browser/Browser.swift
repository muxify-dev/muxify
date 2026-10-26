import Foundation
import Observation
import MuxifyCore

/// A Window's Browser: its Tabs, and what the Window shows of its Terminal
/// and Browser. Every change is reported through `onChange` so it can be
/// written back onto the tmux Window (ADR 0003).
@Observable
final class Browser {
    /// Where the panel puts Focus once it shows the active Tab.
    enum FocusRequest { case addressBar, page }

    let windowID: String
    /// The local scanner must never use a remote Window ID against local tmux.
    let discoversLocalServers: Bool
    private(set) var tabs: [BrowserTab] = []
    private(set) var activeTabID: UUID?
    /// Shows the Browser only while it has a Tab.
    private(set) var layout: PanelLayout
    var focusRequest: FocusRequest? {
        didSet { if focusRequest != nil { onFocusRequest?(self) } }
    }
    /// Newest last. Kept only while the app runs: tmux stores open Tabs, not closed ones.
    private var closedTabs: [ClosedTab] = []
    private static let closedTabLimit = 20

    /// Enough of a closed Tab to bring it back where it was, with its history.
    private struct ClosedTab {
        let url: URL
        let index: Int
        let interactionState: Any?
    }

    @ObservationIgnored var onChange: ((Browser) -> Void)?
    /// Called when the Terminal or the Browser appears or disappears.
    @ObservationIgnored var onShownChange: ((Browser) -> Void)?
    @ObservationIgnored var onCopyURL: ((String) -> Void)?
    /// Called when something asks for Focus in this Browser, before the page or the address field takes it.
    @ObservationIgnored var onFocusRequest: ((Browser) -> Void)?

    init(windowID: String, stored: StoredBrowser, discoversLocalServers: Bool = true) {
        self.windowID = windowID
        self.discoversLocalServers = discoversLocalServers
        layout = stored.layout
        tabs = stored.tabURLs.map { url in
            makeTab(url == "about:blank" ? nil : URL(string: url))
        }
        if tabs.isEmpty {
            layout.closeBrowser()
        } else {
            activeTabID = tabs[min(max(stored.activeTab, 0), tabs.count - 1)].id
        }
    }

    var activeTab: BrowserTab? {
        tabs.first { $0.id == activeTabID }
    }

    var stored: StoredBrowser {
        StoredBrowser(
            tabURLs: tabs.map { $0.hasPage ? $0.urlString : "about:blank" },
            activeTab: tabs.firstIndex { $0.id == activeTabID } ?? 0,
            layout: layout
        )
    }

    func toggle(_ side: PanelLayout.Side) {
        changeLayout { $0.toggle(side) }
        changed()
    }

    func toggleMaximize(_ side: PanelLayout.Side, sidebarShown: Bool) {
        changeLayout { $0.toggleMaximize(side, sidebarShown: sidebarShown) }
        changed()
    }

    func commitMaximize() {
        changeLayout { $0.commitMaximize() }
        changed()
    }

    func reveal(_ side: PanelLayout.Side) {
        changeLayout { $0.reveal(side) }
        changed()
    }

    /// Asks the panel for Focus: the page, or the address field of a blank Tab.
    func requestFocus() {
        focusRequest = activeTab?.hasPage == true ? .page : .addressBar
    }

    /// A shown Browser always has a Tab: an empty one gets a blank Tab to type
    /// into. A hidden blank Tab is nothing worth keeping (or badging in the sidebar).
    private func changeLayout(_ change: (inout PanelLayout) -> Void) {
        let before = layout
        change(&layout)
        guard layout != before else { return }
        if layout.shows(.browser), !before.shows(.browser) {
            if tabs.isEmpty { appendTab(nil) }
            if activeTab?.hasPage == false { focusRequest = .addressBar }
        } else if !layout.shows(.browser), before.shows(.browser) {
            dropBlankTabs()
        }
        if layout.shows(.terminal) != before.shows(.terminal) || layout.shows(.browser) != before.shows(.browser) {
            onShownChange?(self)
        }
    }

    private func dropBlankTabs() {
        let blank = tabs.filter { !$0.hasPage }
        guard !blank.isEmpty else { return }
        blank.forEach { $0.close() }
        tabs.removeAll { !$0.hasPage }
        if activeTab == nil { activeTabID = tabs.last?.id }
    }

    /// Shows `url` in a Tab and shows the Browser. Switches to a Tab that
    /// already has the URL, reuses the active Tab if it is still blank, and
    /// otherwise adds a new Tab.
    func open(_ url: URL) {
        let key = BrowserTab.matchKey(url.absoluteString)
        if let existing = tabs.first(where: { $0.hasPage && BrowserTab.matchKey($0.urlString) == key }) {
            activeTabID = existing.id
        } else if let blank = activeTab, !blank.hasPage {
            blank.load(url)
        } else {
            appendTab(url)
        }
        changeLayout { $0.show(.browser) }
        changed()
    }

    func newTab() {
        appendTab(nil)
        focusRequest = .addressBar
        changeLayout { $0.show(.browser) }
        changed()
    }

    /// Closing the last Tab closes the Browser. A Tab with a page can be reopened.
    func close(_ tab: BrowserTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        if tab.hasPage, let url = URL(string: tab.urlString) {
            closedTabs.append(ClosedTab(url: url, index: index, interactionState: tab.interactionState))
            if closedTabs.count > Self.closedTabLimit { closedTabs.removeFirst() }
        }
        tab.close()
        tabs.remove(at: index)
        if tabs.isEmpty {
            activeTabID = nil
            changeLayout { $0.closeBrowser() }
        } else if activeTabID == tab.id {
            activeTabID = tabs[min(index, tabs.count - 1)].id
        }
        changed()
    }

    func closeActiveTab() {
        if let activeTab { close(activeTab) }
    }

    var canReopenClosedTab: Bool { !closedTabs.isEmpty }

    /// Brings back the newest closed Tab at its old position, with its back
    /// and forward history, and gives it Focus.
    func reopenClosedTab() {
        guard let closed = closedTabs.popLast() else { return }
        let tab = makeTab(closed.url, interactionState: closed.interactionState)
        tabs.insert(tab, at: min(closed.index, tabs.count))
        activeTabID = tab.id
        changeLayout { $0.reveal(.browser) }
        requestFocus()
        changed()
    }

    func moveTab(_ tab: BrowserTab, to destination: Browser) {
        guard destination !== self,
              let index = tabs.firstIndex(where: { $0 === tab }),
              !destination.tabs.contains(where: { $0 === tab }) else { return }
        tabs.remove(at: index)
        if tabs.isEmpty {
            activeTabID = nil
            changeLayout { $0.closeBrowser() }
        } else if activeTabID == tab.id {
            activeTabID = tabs[min(index, tabs.count - 1)].id
        }
        destination.bind(tab)
        destination.tabs.append(tab)
        destination.activeTabID = tab.id
        destination.changeLayout { $0.show(.browser) }
        changed()
        destination.changed()
    }

    func select(_ tab: BrowserTab) {
        guard activeTabID != tab.id else { return }
        activeTabID = tab.id
        changed()
    }

    func jumpTo(_ tab: BrowserTab) {
        guard tabs.contains(where: { $0.id == tab.id }) else { return }
        select(tab)
        changeLayout { $0.show(.browser) }
        requestFocus()
        changed()
    }

    func selectTab(offset: Int) {
        guard let index = tabs.firstIndex(where: { $0.id == activeTabID }), tabs.count > 1 else { return }
        select(tabs[(index + offset + tabs.count) % tabs.count])
    }

    /// Releases every Tab's web content (the Window is gone).
    func tearDown() {
        tabs.forEach { $0.close() }
    }

    private func appendTab(_ url: URL?) {
        let tab = makeTab(url)
        tabs.append(tab)
        activeTabID = tab.id
    }

    private func makeTab(_ url: URL?, interactionState: Any? = nil) -> BrowserTab {
        let tab = BrowserTab(url: url, interactionState: interactionState)
        bind(tab)
        return tab
    }

    private func bind(_ tab: BrowserTab) {
        // A click on a link is a request to read the page, so the new Tab takes Focus.
        tab.onOpenInNewTab = { [weak self] in
            self?.open($0)
            self?.requestFocus()
        }
        tab.onURLChange = { [weak self] in self?.changed() }
        tab.onCopyURL = { [weak self] in self?.onCopyURL?($0) }
    }

    private func changed() {
        onChange?(self)
    }
}
