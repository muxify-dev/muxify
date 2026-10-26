import AppKit
import XCTest
import WebKit
@testable import MuxifyCore

final class BrowserTests: XCTestCase {
    @MainActor
    func testMovingTabPreservesWebViewAndBackForwardHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.html")
        let second = directory.appendingPathComponent("second.html")
        try "<html><title>First</title><body>First page</body></html>".write(to: first, atomically: true, encoding: .utf8)
        try "<html><title>Second</title><body>Second page</body></html>".write(to: second, atomically: true, encoding: .utf8)
        let source = Browser(windowID: "@1", stored: StoredBrowser())
        let destination = Browser(windowID: "@2", stored: StoredBrowser())
        defer { source.tearDown(); destination.tearDown() }
        source.open(first)
        let tab = try XCTUnwrap(source.activeTab)
        let page = tab.pageView
        let webView = tab.webView
        try await waitForPage(webView, title: "First")
        tab.load(second)
        try await waitForPage(webView, title: "Second")
        tab.goBack()
        try await waitForPage(webView, title: "First")
        XCTAssertTrue(webView.canGoForward)

        source.moveTab(tab, to: destination)

        XCTAssertTrue(destination.activeTab === tab)
        XCTAssertTrue(destination.activeTab?.webView === webView)
        XCTAssertTrue(destination.activeTab?.pageView === page)
        XCTAssertTrue(source.tabs.isEmpty)
        XCTAssertFalse(source.layout.shows(.browser))
        XCTAssertTrue(destination.layout.shows(.browser))
        destination.activeTab?.goForward()
        try await waitForPage(webView, title: "Second")
        destination.activeTab?.goBack()
        try await waitForPage(webView, title: "First")
        XCTAssertEqual(destination.stored.tabURLs, [first.absoluteString])
    }

    @MainActor
    func testMovingTabRepairsSelectionAndRebindsCallbacks() throws {
        let source = Browser(windowID: "@1", stored: StoredBrowser(
            tabURLs: ["https://one.test", "https://two.test", "https://three.test"],
            activeTab: 1, layout: PanelLayout(shown: .both)))
        let destination = Browser(windowID: "@2", stored: StoredBrowser(
            tabURLs: ["https://four.test"], layout: PanelLayout(shown: .terminal)))
        let tab = try XCTUnwrap(source.activeTab)
        let next = source.tabs[2]
        var sourceChanges = 0
        var destinationChanges = 0
        var copied: [String] = []
        source.onChange = { _ in sourceChanges += 1 }
        destination.onChange = { _ in destinationChanges += 1 }
        source.onCopyURL = { _ in XCTFail("The old Browser received the copied URL") }
        destination.onCopyURL = { copied.append($0) }

        source.moveTab(tab, to: destination)

        XCTAssertTrue(source.activeTab === next)
        XCTAssertTrue(destination.activeTab === tab)
        XCTAssertEqual(sourceChanges, 1)
        XCTAssertEqual(destinationChanges, 1)
        tab.load(URL(string: "https://changed.test")!)
        XCTAssertEqual(sourceChanges, 1)
        XCTAssertEqual(destinationChanges, 2)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        tab.copyURL(to: pasteboard)
        XCTAssertEqual(copied, ["https://changed.test"])
        tab.onOpenInNewTab?(URL(string: "https://new.test")!)
        XCTAssertEqual(destination.tabs.count, 3)
        XCTAssertEqual(source.tabs.count, 2)
        XCTAssertEqual(destination.activeTab?.urlString, "https://new.test")
    }

    @MainActor
    func testMovingTabRejectsSameBrowserAndForeignTab() throws {
        let source = Browser(windowID: "@1", stored: StoredBrowser(tabURLs: ["about:blank"]))
        let destination = Browser(windowID: "@2", stored: StoredBrowser())
        let tab = try XCTUnwrap(source.activeTab)
        source.onChange = { _ in XCTFail("Rejected transfer changed the source") }
        destination.onChange = { _ in XCTFail("Rejected transfer changed the destination") }
        source.moveTab(tab, to: source)
        destination.moveTab(tab, to: source)
        XCTAssertTrue(source.activeTab === tab)
        XCTAssertTrue(destination.tabs.isEmpty)
    }

    @MainActor
    func testMovingLastBlankTabShowsSourceTerminalAndDestinationBrowser() throws {
        let source = Browser(windowID: "@1", stored: StoredBrowser(
            tabURLs: ["about:blank"], layout: PanelLayout(shown: .browser)))
        let destination = Browser(windowID: "@2", stored: StoredBrowser())
        let tab = try XCTUnwrap(source.activeTab)
        var shownChanges: [String] = []
        source.onShownChange = { shownChanges.append($0.windowID) }
        destination.onShownChange = { shownChanges.append($0.windowID) }

        source.moveTab(tab, to: destination)

        XCTAssertNil(source.activeTab)
        XCTAssertTrue(source.layout.shows(.terminal))
        XCTAssertFalse(source.layout.shows(.browser))
        XCTAssertTrue(destination.activeTab === tab)
        XCTAssertEqual(destination.tabs.count, 1)
        XCTAssertTrue(destination.layout.shows(.browser))
        XCTAssertEqual(destination.focusRequest, .addressBar)
        XCTAssertEqual(shownChanges, ["@1", "@2"])
    }

    @MainActor
    func testReloadLoadsTheTabsURLWhenItsFirstLoadFailed() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = directory.appendingPathComponent("page.html")
        let tab = BrowserTab(url: page)
        defer { tab.close() }
        let webView = tab.webView
        let deadline = Date().addingTimeInterval(15)
        while webView.isLoading || tab.progress == 0, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertNil(webView.backForwardList.currentItem, "the missing page was committed")
        XCTAssertEqual(tab.urlString, page.absoluteString)
        try "<html><title>Back</title><body>Back</body></html>".write(to: page, atomically: true, encoding: .utf8)

        tab.reloadOrStop()

        try await waitForPage(webView, title: "Back")
    }

    @MainActor
    private func waitForPage(_ webView: WKWebView, title: String) async throws {
        let deadline = Date().addingTimeInterval(15)
        while webView.isLoading || webView.title != title {
            guard Date() < deadline else {
                XCTFail("Expected page \(title), got \(webView.title ?? "nil") at \(webView.url?.absoluteString ?? "nil")")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @MainActor
    func testCopyURLReportsTheCurrentURLAfterNavigation() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let tab = BrowserTab(url: URL(string: "https://example.com"))
        var copied: [String] = []
        tab.onCopyURL = { copied.append($0) }
        let url = "https://example.org/path?query=value#section"
        tab.load(URL(string: url)!)

        tab.copyURL(to: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), url)
        XCTAssertEqual(copied, [url])
    }

    @MainActor
    func testCopyingABlankTabPreservesTheClipboardAndDoesNotConfirm() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("keep this", forType: .string)
        let tab = BrowserTab(url: nil)
        tab.onCopyURL = { _ in XCTFail("A blank Tab must not show a copy confirmation") }

        tab.copyURL(to: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "keep this")
    }

    @MainActor
    func testHidingBrowserPreservesLoadedTabsAndSelection() {
        let browser = Browser(windowID: "@1", stored: StoredBrowser(
            tabURLs: ["https://example.com", "https://example.org"], activeTab: 1, layout: PanelLayout(shown: .both)))
        let tabs = browser.tabs
        let selected = browser.activeTabID
        browser.toggle(.browser)
        XCTAssertEqual(browser.tabs.map(\.id), tabs.map(\.id))
        XCTAssertEqual(browser.activeTabID, selected)
        XCTAssertEqual(browser.stored.tabURLs, ["https://example.com", "https://example.org"])
        browser.toggle(.browser)
        XCTAssertTrue(browser.layout.shows(.browser))
        XCTAssertEqual(browser.tabs.map(\.id), tabs.map(\.id))
        XCTAssertEqual(browser.activeTabID, selected)
    }

    @MainActor
    func testOrdinaryBrowserHideStillDiscardsEmptyTabs() {
        let browser = Browser(windowID: "@1", stored: StoredBrowser(
            tabURLs: ["https://example.com", "about:blank"], activeTab: 1, layout: PanelLayout(shown: .both)))
        browser.toggle(.browser)
        XCTAssertEqual(browser.stored.tabURLs, ["https://example.com"])
        XCTAssertEqual(browser.activeTabID, browser.tabs.first?.id)
    }

    @MainActor
    func testExplicitOpenRevealsHiddenBrowserAndSelectsExistingTab() {
        let browser = Browser(windowID: "@1", stored: StoredBrowser(
            tabURLs: ["https://example.com", "about:blank"], activeTab: 1, layout: PanelLayout(shown: .both)))
        let existingID = browser.tabs.first?.id
        browser.toggle(.browser)
        browser.open(URL(string: "https://example.com")!)
        XCTAssertTrue(browser.layout.shows(.browser))
        XCTAssertEqual(browser.activeTabID, existingID)
        XCTAssertEqual(browser.tabs.count, 1)
    }

    @MainActor
    func testMaximizeOfAnEmptyBrowserGivesItABlankTabThatGoesOnRestore() {
        let browser = Browser(windowID: "@1", stored: StoredBrowser())
        browser.toggleMaximize(.browser, sidebarShown: true)
        XCTAssertTrue(browser.layout.shows(.browser))
        XCTAssertFalse(browser.layout.shows(.terminal))
        XCTAssertEqual(browser.stored.tabURLs, ["about:blank"])
        XCTAssertEqual(browser.focusRequest, .addressBar)
        browser.toggleMaximize(.browser, sidebarShown: false)
        XCTAssertFalse(browser.layout.shows(.browser))
        XCTAssertEqual(browser.stored.tabURLs, [])
    }

    @MainActor
    func testRevealingTheBrowserFromAMaximizedTerminalRestoresAndAsksForFocus() {
        let browser = Browser(windowID: "@1", stored: StoredBrowser(layout: PanelLayout(shown: .terminal, maximized: .terminal)))
        browser.reveal(.browser)
        XCTAssertNil(browser.layout.maximized, "the Maximized Terminal was not restored")
        XCTAssertTrue(browser.layout.shows(.terminal))
        XCTAssertTrue(browser.layout.shows(.browser))
        XCTAssertEqual(browser.stored.tabURLs, ["about:blank"])
        XCTAssertEqual(browser.focusRequest, .addressBar, "the blank Tab's address field did not ask for Focus")
    }

    @MainActor
    func testClosingTheLastTabOfABrowserAloneShowsTheTerminal() {
        let browser = Browser(windowID: "@1", stored: StoredBrowser(
            tabURLs: ["https://example.com"], layout: PanelLayout(shown: .browser)))
        browser.closeActiveTab()
        XCTAssertTrue(browser.layout.shows(.terminal))
        XCTAssertFalse(browser.layout.shows(.browser))
    }

    @MainActor
    func testReopenedTabReturnsToItsIndexWithItsBackHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.html")
        let second = directory.appendingPathComponent("second.html")
        try "<html><title>First</title><body>First page</body></html>".write(to: first, atomically: true, encoding: .utf8)
        try "<html><title>Second</title><body>Second page</body></html>".write(to: second, atomically: true, encoding: .utf8)
        let browser = Browser(windowID: "@1", stored: StoredBrowser(
            tabURLs: ["https://one.test", first.absoluteString, "https://three.test"],
            activeTab: 1, layout: PanelLayout(shown: .both)))
        defer { browser.tearDown() }
        let closing = try XCTUnwrap(browser.activeTab)
        try await waitForPage(closing.webView, title: "First")
        closing.load(second)
        try await waitForPage(closing.webView, title: "Second")
        XCTAssertFalse(browser.canReopenClosedTab)

        browser.closeActiveTab()
        XCTAssertTrue(browser.canReopenClosedTab)
        browser.reopenClosedTab()

        XCTAssertFalse(browser.canReopenClosedTab)
        XCTAssertEqual(browser.stored.tabURLs, ["https://one.test", second.absoluteString, "https://three.test"])
        XCTAssertEqual(browser.stored.activeTab, 1)
        XCTAssertEqual(browser.focusRequest, .page)
        let reopened = try XCTUnwrap(browser.activeTab)
        XCTAssertFalse(reopened === closing)
        try await waitForPage(reopened.webView, title: "Second")
        XCTAssertTrue(reopened.webView.canGoBack)
        reopened.goBack()
        try await waitForPage(reopened.webView, title: "First")
    }

    @MainActor
    func testReopenOpensTheNewestClosedTabFirstAndShowsTheBrowser() {
        let browser = Browser(windowID: "@1", stored: StoredBrowser(
            tabURLs: ["https://one.test", "https://two.test"], layout: PanelLayout(shown: .both)))
        browser.closeActiveTab()
        browser.closeActiveTab()
        XCTAssertFalse(browser.layout.shows(.browser))

        browser.reopenClosedTab()
        XCTAssertTrue(browser.layout.shows(.browser))
        XCTAssertEqual(browser.stored.tabURLs, ["https://two.test"])
        browser.reopenClosedTab()
        XCTAssertEqual(browser.stored.tabURLs, ["https://one.test", "https://two.test"])
        XCTAssertEqual(browser.activeTab?.urlString, "https://one.test")
        XCTAssertFalse(browser.canReopenClosedTab)
    }

    @MainActor
    func testOnlyClosingATabWithAPageMakesItReopenable() throws {
        let source = Browser(windowID: "@1", stored: StoredBrowser(
            tabURLs: ["https://one.test", "about:blank"], activeTab: 1, layout: PanelLayout(shown: .both)))
        let destination = Browser(windowID: "@2", stored: StoredBrowser())
        source.closeActiveTab()
        XCTAssertFalse(source.canReopenClosedTab, "a blank Tab was reopenable")
        source.newTab()
        source.toggle(.browser)
        XCTAssertFalse(source.canReopenClosedTab, "a blank Tab dropped by hiding the Browser was reopenable")
        source.moveTab(try XCTUnwrap(source.activeTab), to: destination)
        XCTAssertFalse(source.canReopenClosedTab, "a Tab moved to another Window was reopenable")
        XCTAssertFalse(destination.canReopenClosedTab)
    }
}
