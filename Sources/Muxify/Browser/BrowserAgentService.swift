import AppKit
import MuxifyCore

/// Serves the Browser commands of the Local Environment's tmux server (ADR 0057). It answers each request with
/// the Browsers of the local App Windows, and remembers each Pane's Agent Tab.
@MainActor
final class BrowserAgentService {
    /// The local App Windows' stores. The first one consumes `@muxify_open`, so `open` and `tabs` use its
    /// Browsers; a Tab id is found in any of them, because that store changes when another App Window takes focus.
    private let stores: () -> [WorkspaceStore]
    private var listener: BrowserAgentListener?
    private var serverID: String?
    /// Pane id to the Tab that the Pane opened last.
    private var agentTabs: [String: UUID] = [:]

    init(stores: @escaping () -> [WorkspaceStore]) {
        self.stores = stores
    }

    /// Listens for the server whose socket is `tmuxSocket`, and returns the path for `BrowserAgentChannel.option`.
    /// Nil when it cannot listen. Pane ids of a new server name other Panes, so their Agent Tabs are forgotten.
    func serve(tmuxSocket: String, serverID: String?) -> String? {
        if serverID != self.serverID {
            self.serverID = serverID
            agentTabs = [:]
        }
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
            return .tabs(browser.tabs.map { describe($0, in: browser, pane: request.pane) })
        case .open(let input):
            guard let url = Omnibox.url(for: input) else { return .failure("'\(input)' is not a URL") }
            let browser = store.browser(for: request.window)
            let tab = browser.open(url)
            if let pane = request.pane { agentTabs[pane] = tab.id }
            await tab.agentWaitForLoad()
            return .opened(describe(tab, in: browser, pane: request.pane))
        case .eval(let script):
            return await withTab(request, in: stores) { await $0.agentEval(script) }
        case .screenshot:
            return await withTab(request, in: stores) { await $0.agentScreenshot() }
        case .snapshot:
            return await withTab(request, in: stores) { await $0.agentSnapshot() }
        case .click(let ref):
            return await withTab(request, in: stores) { await $0.agentAct("click(ref)", ["ref": ref]) }
        case .fill(let ref, let text):
            return await withTab(request, in: stores) { await $0.agentAct("fill(ref, text)", ["ref": ref, "text": text]) }
        case .press(let key, let ref):
            return await withTab(request, in: stores) { await $0.agentAct("press(key, ref)", ["key": key, "ref": ref ?? NSNull()]) }
        case .wait(let condition, let timeout):
            return await withTab(request, in: stores) { await $0.agentWait(for: condition, timeout: timeout) }
        }
    }

    private func withTab(_ request: BrowserAgentRequest, in stores: [WorkspaceStore],
                         _ command: (BrowserTab) async -> BrowserAgentReply) async -> BrowserAgentReply {
        let remembered = request.pane.flatMap { agentTabs[$0] }
        guard let id = request.tab ?? remembered else {
            return .failure("this Pane has no Agent Tab. Run muxify browser open --json <url>, or pass --tab <id> from muxify browser tabs.")
        }
        guard let tab = stores.lazy.compactMap({ $0.loadedBrowser(for: request.window)?.tabs.first { $0.id == id } }).first else {
            if request.tab != nil { return .failure("tmux Window \(request.window) has no Tab \(id). muxify browser tabs lists them.") }
            return .failure("the Agent Tab of this Pane is closed. Run muxify browser open --json <url>, or pass --tab <id> from muxify browser tabs.")
        }
        return await command(tab)
    }

    private func describe(_ tab: BrowserTab, in browser: Browser, pane: String?) -> BrowserAgentTab {
        BrowserAgentTab(id: tab.id, url: tab.urlString, title: tab.title, active: browser.activeTabID == tab.id,
                        agent: pane.flatMap { agentTabs[$0] } == tab.id)
    }
}
