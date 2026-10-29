import AppKit
import MuxifyCore

/// Serves the Browser commands of the Local Environment's tmux server (ADR 0057, ADR 0058). It answers each
/// request with the Browsers of the local App Windows.
@MainActor
final class BrowserAgentService {
    /// The local App Windows' stores. The first one consumes `@muxify_open`, so `open`, `tabs` and the active Tab
    /// come from its Browsers; a Tab id is found in any of them, because that store changes when another App Window
    /// takes focus.
    private let stores: () -> [WorkspaceStore]
    private var listener: BrowserAgentListener?

    init(stores: @escaping () -> [WorkspaceStore]) {
        self.stores = stores
    }

    /// Listens for the server whose socket is `tmuxSocket`, and returns the path for `BrowserAgentChannel.option`.
    /// Nil when it cannot listen.
    func serve(tmuxSocket: String) -> String? {
        let path = BrowserAgentChannel.socketPath(forTmuxSocket: tmuxSocket)
        if listener?.path == path { return path }
        listener?.stop()
        do {
            listener = try BrowserAgentListener(path: path) { [weak self] request, reply in
                Task { @MainActor in
                    guard let self else { return reply(.failure("Muxify is quitting")) }
                    reply(await self.handle(request))
                }
            }
            return path
        } catch {
            Diagnostics.report("cannot serve Browser commands: \(error)")
            listener = nil
            return nil
        }
    }

    func stop() {
        listener?.stop()
        listener = nil
    }

    /// A page that focuses an element, in `fill` or in its own click handler, makes AppKit focus its web view.
    /// A command never moves the user's focus, so each App Window gets back the responder it had.
    func handle(_ request: BrowserAgentRequest) async -> BrowserAgentReply {
        let responders = NSApp.windows.map { ($0, $0.firstResponder) }
        let reply = await reply(to: request)
        for (window, responder) in responders where window.firstResponder !== responder {
            window.makeFirstResponder(responder)
        }
        return reply
    }

    private func reply(to request: BrowserAgentRequest) async -> BrowserAgentReply {
        let stores = stores()
        guard let store = stores.first else { return .failure("Muxify shows no Local Environment") }
        switch request.command {
        case .tabs:
            let browser = store.browser(for: request.window)
            return .tabs(browser.tabs.map { describe($0, in: browser) })
        case .open(let input):
            guard let url = Omnibox.url(for: input) else { return .failure("'\(input)' is not a URL") }
            if request.tab != nil {
                return await withTab(request, in: stores) { tab, browser in
                    tab.load(url)
                    _ = await tab.agentWaitForLoad(timeout: 10)
                    return .opened(describe(tab, in: browser))
                }
            }
            let browser = store.browser(for: request.window)
            let tab = browser.open(url)
            return await running(on: tab) {
                _ = await tab.agentWaitForLoad(timeout: 10)
                return .opened(describe(tab, in: browser))
            }
        case .eval(let script):
            return await withTab(request, in: stores) { tab, _ in await tab.agentEval(script) }
        case .screenshot:
            return await withTab(request, in: stores) { tab, _ in await tab.agentScreenshot() }
        case .snapshot:
            return await withTab(request, in: stores) { tab, _ in await tab.agentSnapshot() }
        case .click(let ref):
            return await withTab(request, in: stores) { tab, _ in await tab.agentAct("click(ref)", ["ref": ref], waitForLoad: true) }
        case .fill(let ref, let text):
            return await withTab(request, in: stores) { tab, _ in
                await tab.agentAct("fill(ref, text)", ["ref": ref, "text": text], waitForLoad: false)
            }
        case .press(let key, let ref):
            return await withTab(request, in: stores) { tab, _ in
                await tab.agentAct("press(key, ref)", ["key": key, "ref": ref ?? NSNull()], waitForLoad: true)
            }
        case .wait(let condition, let timeout):
            return await withTab(request, in: stores) { tab, _ in await tab.agentWait(for: condition, timeout: timeout) }
        }
    }

    /// Runs `command` on the Tab of `--tab`, else on the Window's active Tab, the one that the user sees.
    private func withTab(_ request: BrowserAgentRequest, in stores: [WorkspaceStore],
                         _ command: (BrowserTab, Browser) async -> BrowserAgentReply) async -> BrowserAgentReply {
        guard let id = request.tab else {
            let browser = stores[0].browser(for: request.window)
            guard let tab = browser.activeTab else {
                return .failure("the Browser of tmux Window \(request.window) has no Tab. Run muxify browser open --json <url>.")
            }
            return await running(on: tab) { await command(tab, browser) }
        }
        let found = stores.lazy.compactMap { store in
            store.loadedBrowser(for: request.window).flatMap { browser in browser.tabs.first { $0.id == id }.map { ($0, browser) } }
        }.first
        guard let (tab, browser) = found else {
            return .failure("tmux Window \(request.window) has no Tab \(id). muxify browser tabs lists them.")
        }
        return await running(on: tab) { await command(tab, browser) }
    }

    private func running(on tab: BrowserTab, _ command: () async -> BrowserAgentReply) async -> BrowserAgentReply {
        tab.agentCommands += 1
        defer { tab.agentCommands -= 1 }
        return await command()
    }

    private func describe(_ tab: BrowserTab, in browser: Browser) -> BrowserAgentTab {
        BrowserAgentTab(id: tab.id, url: tab.urlString, title: tab.title, active: browser.activeTabID == tab.id)
    }
}
