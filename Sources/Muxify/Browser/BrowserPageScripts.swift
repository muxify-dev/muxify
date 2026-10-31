import WebKit

/// The scripts Muxify puts into every frame of every Tab's page: Find in Page,
/// Escape to leave a text field, and Vim Keys. They run in a content world of their own, so the page cannot
/// see or replace them, and they cannot see the page's globals.
enum BrowserPageScripts {
    static let world = WKContentWorld.world(name: "muxify")

    /// Every Tab shares it through the shared WKWebViewConfiguration, so a
    /// change of its scripts acts on the next load of every Tab.
    static let userContentController: WKUserContentController = {
        let controller = WKUserContentController()
        controller.add(messages, contentWorld: world, name: Message.findFrame.rawValue)
        controller.add(messages, contentWorld: world, name: Message.scrollKey.rawValue)
        install(in: controller)
        return controller
    }()

    private static var vimKeysEnabled = true
    private static let finders = NSMapTable<WKWebView, PageFinder>.weakToStrongObjects()
    private static let messages = Messages()

    static func register(_ webView: WKWebView, finder: PageFinder) {
        finders.setObject(finder, forKey: webView)
    }

    /// Applies `browser.vim_keys` of the Local Config to later loads and to
    /// the main frame of each page that is open now.
    static func setVimKeys(_ enabled: Bool) {
        guard enabled != vimKeysEnabled else { return }
        vimKeysEnabled = enabled
        install(in: userContentController)
        for webView in finders.keyEnumerator().allObjects.compactMap({ $0 as? WKWebView }) {
            webView.evaluateJavaScript(vimKeysSource + "globalThis.muxifyVimKeys.enabled = \(enabled);",
                                       in: nil, in: world) { _ in }
        }
    }

    /// Called when Focus moves to the page. WebKit sends keys to the frame that
    /// has focus, so on a page that shows its document in an iframe, as a
    /// Lavish review does, the arrow keys and Vim Keys did nothing until a click.
    static func focusMainPart(of webView: WKWebView) {
        webView.evaluateJavaScript(focusMainPartSource, in: nil, in: world) { _ in }
    }

    private static func install(in controller: WKUserContentController) {
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(source: findSource, injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: false, in: world))
        controller.addUserScript(WKUserScript(source: leaveFieldSource, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false, in: world))
        if vimKeysEnabled {
            controller.addUserScript(WKUserScript(source: vimKeysSource, injectionTime: .atDocumentStart,
                                                  forMainFrameOnly: false, in: world))
        }
    }

    private enum Message: String {
        /// A frame's Find in Page script loaded; the body is its document id.
        case findFrame = "muxifyFindFrame"
        /// A Vim Key went down or up; the body names the ScrollKey.
        case scrollKey = "muxifyScrollKey"
    }

    private final class Messages: NSObject, WKScriptMessageHandler {
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let webView = message.webView else { return }
            switch Message(rawValue: message.name) {
            case .findFrame:
                guard let document = message.body as? String else { return }
                finders.object(forKey: webView)?.register(message.frameInfo, document: document)
            case .scrollKey:
                guard let body = message.body as? [String: Any], let name = body["key"] as? String,
                      let key = ScrollKey(rawValue: name) else { return }
                key.send(to: webView, down: body["down"] as? Bool ?? false, isRepeat: body["repeat"] as? Bool ?? false)
            case nil:
                break
            }
        }
    }

    /// The key a Vim Key stands for. WebKit scrolls for it with its own target,
    /// step and animation, so a Vim Key scrolls exactly as that key does.
    private enum ScrollKey: String {
        case arrowDown = "ArrowDown", arrowUp = "ArrowUp", arrowLeft = "ArrowLeft", arrowRight = "ArrowRight"
        case pageDown = "PageDown", pageUp = "PageUp", home = "Home", end = "End"

        private var key: (code: UInt16, character: Int, flags: NSEvent.ModifierFlags) {
            switch self {
            case .arrowDown: (125, NSDownArrowFunctionKey, [.numericPad, .function])
            case .arrowUp: (126, NSUpArrowFunctionKey, [.numericPad, .function])
            case .arrowLeft: (123, NSLeftArrowFunctionKey, [.numericPad, .function])
            case .arrowRight: (124, NSRightArrowFunctionKey, [.numericPad, .function])
            case .pageDown: (121, NSPageDownFunctionKey, .function)
            case .pageUp: (116, NSPageUpFunctionKey, .function)
            case .home: (115, NSHomeFunctionKey, .function)
            case .end: (119, NSEndFunctionKey, .function)
            }
        }

        func send(to webView: WKWebView, down: Bool, isRepeat: Bool) {
            let (code, character, flags) = key
            guard let scalar = UnicodeScalar(character),
                  let event = NSEvent.keyEvent(with: down ? .keyDown : .keyUp, location: .zero, modifierFlags: flags,
                                               timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: webView.window?.windowNumber ?? 0, context: nil,
                                               characters: String(scalar), charactersIgnoringModifiers: String(scalar),
                                               isARepeat: isRepeat, keyCode: code) else { return }
            if down { webView.keyDown(with: event) } else { webView.keyUp(with: event) }
        }
    }

    /// Each frame finds and highlights its own matches; PageFinder keeps the
    /// frames in order and knows which match is current. Every call names the
    /// document it was registered with, so a frame that has since loaded
    /// another document answers `null` and PageFinder drops the old entry.
    static let findSource = #"""
    (() => {
      if (globalThis.muxifyFind) return;
      const ALL = 'muxify-find', CURRENT = 'muxify-find-current';
      const SKIP = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE']);
      const CSS_TEXT = `::highlight(${ALL}) { background-color: rgba(255, 221, 0, 0.45); }
        ::highlight(${CURRENT}) { background-color: rgb(255, 150, 0); color: black; }`;
      const id = Math.random().toString(36).slice(2) + Date.now().toString(36);
      // Long-lived and changed in place: WebKit repaints a range added to or
      // removed from a Highlight, but did not repaint the old ranges when a new
      // Highlight replaced one in the registry.
      const all = new Highlight(), current = new Highlight();
      current.priority = 1;
      let ranges = [], sheet = null, styleElement = null, activeAt = 0;

      for (const type of ['pointerdown', 'keydown', 'wheel']) {
        addEventListener(type, () => { activeAt = Date.now(); }, { capture: true, passive: true });
      }

      // One character out for each UTF-16 unit in, so offsets stay valid.
      const fold = (text) => {
        let out = '';
        for (let i = 0; i < text.length; i++) {
          const c = text[i], lower = c.toLowerCase();
          out += /\s/.test(c) ? ' ' : (lower.length === c.length ? lower : c);
        }
        return out;
      };

      function addStyle() {
        try {
          if (!sheet) { sheet = new CSSStyleSheet(); sheet.replaceSync(CSS_TEXT); }
          if (!document.adoptedStyleSheets.includes(sheet)) {
            document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
          }
        } catch {
          if (!styleElement || !styleElement.isConnected) {
            styleElement = document.createElement('style');
            styleElement.textContent = CSS_TEXT;
            (document.head || document.documentElement).appendChild(styleElement);
          }
        }
        if (CSS.highlights.get(ALL) !== all) CSS.highlights.set(ALL, all);
        if (CSS.highlights.get(CURRENT) !== current) CSS.highlights.set(CURRENT, current);
      }

      const fill = (highlight, list) => {
        highlight.clear();
        for (const range of list) highlight.add(range);
      };

      // A block boundary becomes a line break, so a match can cross inline
      // elements but not run from one paragraph into the next.
      function collect(folded) {
        const blocks = new Map(), visible = new Map(), styles = new Map();
        const blockOf = (element) => {
          let e = element;
          while (e && e !== document.body) {
            if (!blocks.has(e)) blocks.set(e, !getComputedStyle(e).display.startsWith('inline'));
            if (blocks.get(e)) return e;
            e = e.parentElement;
          }
          return document.body;
        };
        const isVisible = (element) => {
          if (!visible.has(element)) {
            // An element with display: contents has no box of its own.
            visible.set(element, styleOf(element).display === 'contents'
              ? !element.parentElement || isVisible(element.parentElement)
              : !element.checkVisibility || element.checkVisibility({ checkVisibilityCSS: true }));
          }
          return visible.get(element);
        };
        const styleOf = (element) => {
          if (!styles.has(element)) styles.set(element, getComputedStyle(element));
          return styles.get(element);
        };
        const outside = (r, box) => r.bottom <= box.top || r.top >= box.bottom || r.right <= box.left || r.left >= box.right;
        // A box that clips its content shows only what scrolls into it, and the
        // boxes around it then need to show that box. A fixed box leaves its
        // ancestors and the page's scroll behind, so a panel that a transform
        // keeps below the viewport, as the chat of a narrow Lavish review,
        // shows nothing until it opens.
        const canScrollTo = (node) => {
          const range = document.createRange();
          range.selectNodeContents(node);
          let r = range.getBoundingClientRect();
          if (!r.width && !r.height) return true;
          const root = document.scrollingElement || document.documentElement;
          let fixed = false;
          for (let e = node.parentElement; e; e = e.parentElement) {
            const style = styleOf(e);
            if (e === root) {
              return !outside(r, fixed ? { top: 0, left: 0, bottom: innerHeight, right: innerWidth }
                : { top: -scrollY, left: -scrollX, bottom: root.scrollHeight - scrollY, right: root.scrollWidth - scrollX });
            }
            if (!fixed && (style.overflowX !== 'visible' || style.overflowY !== 'visible')) {
              const b = e.getBoundingClientRect();
              const top = b.top + e.clientTop, left = b.left + e.clientLeft;
              const scrollsY = style.overflowY !== 'clip', scrollsX = style.overflowX !== 'clip';
              const boxTop = scrollsY ? top - e.scrollTop : top, boxLeft = scrollsX ? left - e.scrollLeft : left;
              if (outside(r, { top: boxTop, left: boxLeft,
                               bottom: boxTop + (scrollsY ? e.scrollHeight : e.clientHeight),
                               right: boxLeft + (scrollsX ? e.scrollWidth : e.clientWidth) })) return false;
              r = { top, left, bottom: top + e.clientHeight, right: left + e.clientWidth };
            }
            if (style.position === 'fixed') fixed = true;
          }
          return true;
        };
        const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
          acceptNode(node) {
            const parent = node.parentElement;
            if (!parent || SKIP.has(parent.tagName) || !isVisible(parent) || !canScrollTo(node)) return NodeFilter.FILTER_REJECT;
            return NodeFilter.FILTER_ACCEPT;
          }
        });
        let text = '', lastBlock = null;
        const nodes = [], offsets = [];
        for (let node = walker.nextNode(); node; node = walker.nextNode()) {
          const block = blockOf(node.parentElement);
          if (lastBlock && block !== lastBlock) { text += '\n'; nodes.push(null); offsets.push(0); }
          lastBlock = block;
          const data = fold(node.data);
          for (let i = 0; i < data.length; i++) {
            if (data[i] === ' ' && (text.endsWith(' ') || text.endsWith('\n') || text === '')) continue;
            text += data[i]; nodes.push(node); offsets.push(i);
          }
        }
        const found = [];
        for (let at = text.indexOf(folded); at >= 0; at = text.indexOf(folded, at + folded.length)) {
          const end = at + folded.length - 1;
          const range = document.createRange();
          range.setStart(nodes[at], offsets[at]);
          range.setEnd(nodes[end], offsets[end] + 1);
          found.push(range);
        }
        return found;
      }

      // Scrolls each box that clips the match, innermost first, so a match
      // under a panel's edge counts as hidden even when it is in the window.
      function reveal(range) {
        const root = document.scrollingElement || document.documentElement;
        for (let e = range.startContainer.parentElement; e; e = e.parentElement) {
          let box;
          if (e === root) {
            box = { top: 0, left: 0, bottom: innerHeight, right: innerWidth };
          } else {
            const style = getComputedStyle(e);
            if (style.overflowX === 'visible' && style.overflowY === 'visible') continue;
            const r = e.getBoundingClientRect();
            const top = r.top + e.clientTop, left = r.left + e.clientLeft;
            box = { top, left, bottom: top + e.clientHeight, right: left + e.clientWidth };
          }
          const r = range.getBoundingClientRect();
          if (r.top < box.top || r.bottom > box.bottom) e.scrollTop += (r.top + r.bottom - box.top - box.bottom) / 2;
          if (r.left < box.left) e.scrollLeft += r.left - box.left;
          else if (r.right > box.right) e.scrollLeft += Math.min(r.right - box.right, r.left - box.left);
        }
      }

      // The part of the viewport that this frame draws itself, not its iframes.
      function ownArea() {
        let area = innerWidth * innerHeight;
        for (const frame of document.querySelectorAll('iframe, frame')) {
          const r = frame.getBoundingClientRect();
          area -= Math.max(0, Math.min(r.right, innerWidth) - Math.max(r.left, 0))
            * Math.max(0, Math.min(r.bottom, innerHeight) - Math.max(r.top, 0));
        }
        return area;
      }

      const stale = () => ranges.some((r) => r.collapsed || !r.startContainer.isConnected || !r.endContainer.isConnected);

      // `start` is the first match at or below the top of the viewport.
      function search(document_, query) {
        if (document_ !== id) return null;
        const folded = fold(query).trim() ? fold(query).replace(/ +/g, ' ') : '';
        ranges = folded && document.body && innerWidth && innerHeight ? collect(folded) : [];
        addStyle();
        fill(all, ranges);
        current.clear();
        const start = ranges.findIndex((r) => r.getBoundingClientRect().top >= 0);
        return { count: ranges.length, start: Math.max(start, 0), activeAt, area: ownArea() };
      }

      function select(document_, index) {
        if (document_ !== id || index >= ranges.length || stale()) return false;
        addStyle();
        fill(current, [ranges[index]]);
        reveal(ranges[index]);
        return true;
      }

      function clear() {
        ranges = [];
        all.clear();
        current.clear();
      }

      globalThis.muxifyFind = { search, select, deselect: () => current.clear(), clear };
      const register = () => webkit.messageHandlers.muxifyFindFrame.postMessage(id);
      // A page back from the back-forward cache keeps this script, but its Tab
      // forgot the page's frames when the page went away.
      addEventListener('pageshow', (event) => { if (event.persisted) register(); });
      register();
    })();
    """#

    /// Gives focus to the iframe that shows more of the page than the main frame
    /// itself, when nothing has focus yet and the main frame cannot scroll.
    private static let focusMainPartSource = #"""
    (() => {
      const root = document.scrollingElement || document.documentElement;
      if (document.activeElement && document.activeElement !== document.body && document.activeElement !== root) return;
      const hidden = [document.documentElement, document.body].some((e) => e && getComputedStyle(e).overflowY === 'hidden');
      if (!hidden && root.scrollHeight > root.clientHeight) return;
      const visible = (e) => {
        const r = e.getBoundingClientRect();
        return Math.max(0, Math.min(r.right, innerWidth) - Math.max(r.left, 0))
          * Math.max(0, Math.min(r.bottom, innerHeight) - Math.max(r.top, 0));
      };
      let own = innerWidth * innerHeight, largest = null, largestArea = 0;
      for (const frame of document.querySelectorAll('iframe, frame')) {
        const area = visible(frame);
        own -= area;
        if (area > largestArea) { largest = frame; largestArea = area; }
      }
      if (largest && largestArea > own) largest.focus();
    })();
    """#

    /// Escape leaves a text field, which WebKit does not do, so the arrow keys,
    /// Space and Vim Keys scroll the page again. A page that uses Escape keeps it.
    static let leaveFieldSource = #"""
    (() => {
      if (globalThis.muxifyLeaveField) return;
      globalThis.muxifyLeaveField = true;
      addEventListener('keydown', (event) => {
        if (event.key !== 'Escape' || event.defaultPrevented || event.isComposing
            || event.metaKey || event.ctrlKey || event.altKey || event.shiftKey) return;
        const target = event.composedPath()[0] || event.target;
        if (!(target instanceof Element) || typeof target.blur !== 'function') return;
        if (target.isContentEditable || ['INPUT', 'TEXTAREA', 'SELECT'].includes(target.tagName)) target.blur();
      });
    })();
    """#

    /// h, j, k, l, d, u, gg and G press the arrow, Page Down, Page Up, Home or
    /// End key in their place, down and up with them. H and L go back and
    /// forward in the page's history, once for each press. They do not call
    /// WKWebView's goBack: since macOS 27.2 it drops the forward entry when a
    /// script made the entry it leaves, so L after H did nothing. A key
    /// the page handled, a key with a modifier, and typing in a text field pass
    /// through.
    static let vimKeysSource = #"""
    (() => {
      if (globalThis.muxifyVimKeys) return;
      const state = globalThis.muxifyVimKeys = { enabled: true };
      const KEYS = { j: 'ArrowDown', k: 'ArrowUp', h: 'ArrowLeft', l: 'ArrowRight', d: 'PageDown', u: 'PageUp', G: 'End' };
      const HISTORY = { H: () => history.back(), L: () => history.forward() };
      const held = new Map();
      let gPressedAt = 0;

      const send = (key, down, repeat) => webkit.messageHandlers.muxifyScrollKey.postMessage({ key, down, repeat });

      const editable = (target) => {
        if (document.designMode === 'on') return true;
        if (!(target instanceof Element)) return false;
        return target.isContentEditable || ['INPUT', 'TEXTAREA', 'SELECT'].includes(target.tagName);
      };

      addEventListener('keydown', (event) => {
        const waited = gPressedAt;
        gPressedAt = 0;
        if (!state.enabled || event.defaultPrevented || event.isComposing
            || event.metaKey || event.ctrlKey || event.altKey) return;
        if (editable(event.composedPath()[0] || event.target)) return;
        if (HISTORY[event.key]) {
          event.preventDefault();
          if (!event.repeat) HISTORY[event.key]();
          return;
        }
        let key = KEYS[event.key];
        if (event.key === 'g') {
          if (!waited || Date.now() - waited >= 1000) {
            gPressedAt = Date.now();
            event.preventDefault();
            return;
          }
          key = 'Home';
        }
        if (!key) return;
        event.preventDefault();
        held.set(event.code || event.key, key);
        send(key, true, event.repeat);
      });

      addEventListener('keyup', (event) => {
        const key = held.get(event.code || event.key);
        if (!key) return;
        held.delete(event.code || event.key);
        send(key, false, false);
      });
    })();
    """#
}
