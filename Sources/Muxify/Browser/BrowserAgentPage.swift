import AppKit
import MuxifyCore
import WebKit

/// The Browser commands on one Tab's page (ADR 0057, ADR 0058). `eval` runs in the page's own world, so it sees the page's
/// variables. The other commands run `agentLibrary` in a world of their own, so the page cannot see or change it,
/// and its map from Ref to element lasts as long as the document.
@MainActor
extension BrowserTab {
    static let agentWorld = WKContentWorld.world(name: "muxify-agent")

    /// The Tab's web view, made now when the Tab was never shown. Without a panel nothing sizes the page, and a
    /// page of zero size lays out nothing, so it gets the size of a laptop screen until a panel shows it.
    var agentWebView: WKWebView {
        let webView = webView
        if webView.superview == nil, webView.frame.isEmpty { webView.frame = CGRect(x: 0, y: 0, width: 1280, height: 800) }
        return webView
    }

    /// Waits until the page has loaded: no load runs, the document is complete, and no navigation has started,
    /// committed or finished for 400 ms, counted from the call at the earliest. The quiet time catches a page that
    /// goes on to another page with JavaScript after its load, and a click whose navigation starts a moment later.
    /// False when `timeout` ends first.
    func agentWaitForLoad(timeout: TimeInterval) async -> Bool {
        let webView = agentWebView
        let start = Date()
        let deadline = start.addingTimeInterval(timeout)
        while Date() < deadline {
            let quiet = Date().timeIntervalSince(max(start, navigationActivity)) >= 0.4
            if quiet, !webView.isLoading, (try? await callAgent("loaded()")) as? Bool == true { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    func agentEval(_ script: String) async -> BrowserAgentReply {
        let webView = agentWebView
        // An expression is the usual case, as in `document.title`. Parsing it without running it first means a
        // script of statements runs once, in the form that parses.
        let expression = "return (\n\(script)\n);"
        let parses = (try? await webView.callAsyncJavaScript("return 0; async () => { \(expression) };",
                                                              contentWorld: .page)) != nil
        let body = """
        const muxifyValue = await (async () => {
        \(parses ? expression : script)
        })();
        const muxifyJSON = JSON.stringify(muxifyValue);
        return muxifyJSON === undefined ? 'undefined' : muxifyJSON;
        """
        do {
            return .value(try await webView.callAsyncJavaScript(body, contentWorld: .page) as? String ?? "undefined")
        } catch {
            return .failure(error.javaScriptMessage)
        }
    }

    func agentScreenshot() async -> BrowserAgentReply {
        let webView = agentWebView
        do {
            let image = try await webView.takeSnapshot(configuration: nil)
            guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                return .failure("could not make a PNG of the page")
            }
            return .png(png)
        } catch {
            return .failure("could not take a screenshot of the page: \(error.localizedDescription)")
        }
    }

    /// An empty tree is a failure, because it is almost always a page that is not there yet, and an Agent that
    /// reads nothing has no next step.
    func agentSnapshot() async -> BrowserAgentReply {
        let tree: String
        do { tree = try await callAgent("snapshot()") as? String ?? "" }
        catch { return .failure(error.agentMessage) }
        guard tree.isEmpty else { return .snapshot(tree) }
        let page = urlString.isEmpty ? "about:blank" : urlString
        return .failure("the page \(page) shows nothing yet. Run muxify browser wait --load, then snapshot again.")
    }

    /// `click`, `fill` and `press`: a call of the library that returns nothing. With `waitForLoad`, it replies when
    /// the page that the call starts has loaded, or after 10 s, as a click on a link needs.
    func agentAct(_ call: String, _ arguments: [String: Any], waitForLoad: Bool) async -> BrowserAgentReply {
        do {
            _ = try await callAgent(call, arguments)
        } catch {
            return .failure(error.agentMessage)
        }
        if waitForLoad { _ = await agentWaitForLoad(timeout: 10) }
        return .done
    }

    /// Asks the page ten times a second, from here, because a click that navigates ends the document that a wait
    /// inside the page would run in.
    func agentWait(for condition: BrowserAgentWait, timeout: TimeInterval) async -> BrowserAgentReply {
        let deadline = Date().addingTimeInterval(timeout)
        let (call, arguments, goal): (String, [String: Any], String)
        switch condition {
        case .load:
            return await agentWaitForLoad(timeout: timeout) ? .done : .failure("waited \(Int(timeout)) s for the page to load")
        case .text(let text): (call, arguments, goal) = ("hasText(text)", ["text": text], "the text \"\(text)\"")
        case .selector(let selector): (call, arguments, goal) = ("hasElement(selector)", ["selector": selector], "an element that matches \(selector)")
        }
        while true {
            do {
                if try await callAgent(call, arguments) as? Bool == true { return .done }
            } catch where error.agentMessage.contains("SyntaxError") {
                return .failure(message: "'\(arguments["selector"] ?? "")' is not a CSS selector", exitCode: 2)
            } catch {
                // A document that navigates away answers with an error; the next one answers the next time.
            }
            guard Date() < deadline else { return .failure("waited \(Int(timeout)) s for \(goal)") }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func callAgent(_ call: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
        try await agentWebView.callAsyncJavaScript(Self.agentLibrary + "\nreturn await globalThis.muxifyAgent.\(call);",
                                                   arguments: arguments, contentWorld: Self.agentWorld)
    }
}

extension Error {
    /// The page's own message for an exception, such as "TypeError: x is undefined".
    var javaScriptMessage: String {
        let error = self as NSError
        guard let message = error.userInfo["WKJavaScriptExceptionMessage"] as? String else { return error.localizedDescription }
        return "JavaScript error: \(message)"
    }

    /// The library's own message, such as "no element e9 on this page", without JavaScript's "Error: ".
    var agentMessage: String {
        let error = self as NSError
        guard let message = error.userInfo["WKJavaScriptExceptionMessage"] as? String else { return error.localizedDescription }
        return message.hasPrefix("Error: ") ? String(message.dropFirst(7)) : message
    }
}

extension BrowserTab {
    /// Each call sends the whole library, and `??=` keeps the first copy, with its Refs, for the document's life.
    static let agentLibrary = #"""
    globalThis.muxifyAgent ??= (() => {
      const refs = new Map();
      const refOf = new WeakMap();
      let lastRef = 0;
      const ref = (node) => {
        if (!refOf.has(node)) {
          refOf.set(node, 'e' + ++lastRef);
          refs.set(refOf.get(node), node);
        }
        return refOf.get(node);
      };
      const element = (name) => {
        const node = refs.get(name);
        if (!node) throw new Error(`no element ${name} on this page; run muxify browser snapshot again`);
        if (!node.isConnected) throw new Error(`${name} is no longer on the page; run muxify browser snapshot again`);
        return node;
      };

      const clean = (text) => (text || '').replace(/\s+/g, ' ').trim();
      const short = (text) => text.length > 100 ? text.slice(0, 99) + '…' : text;
      const textOf = (node) => clean(node.innerText ?? node.textContent);
      const skipped = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'HEAD', 'META', 'LINK']);
      const nonText = new Set(['button', 'submit', 'reset', 'image', 'checkbox', 'radio', 'range', 'color', 'file', 'hidden']);
      const hidden = (node) => {
        if (node.hidden || node.getAttribute('aria-hidden') === 'true') return true;
        const style = getComputedStyle(node);
        // An element with display: contents has no box of its own, and checkVisibility calls it hidden.
        if (style.display === 'contents') return false;
        if (node.checkVisibility) return !node.checkVisibility({ visibilityProperty: true, checkVisibilityCSS: true });
        return style.display === 'none' || style.visibility === 'hidden';
      };

      const inputRoles = { button: 'button', submit: 'button', reset: 'button', image: 'button', file: 'button',
        checkbox: 'checkbox', radio: 'radio', range: 'slider', number: 'spinbutton', search: 'searchbox' };
      const tagRoles = { BUTTON: 'button', TEXTAREA: 'textbox', UL: 'list', OL: 'list', LI: 'listitem',
        NAV: 'navigation', MAIN: 'main', HEADER: 'banner', FOOTER: 'contentinfo', ASIDE: 'complementary',
        TABLE: 'table', TR: 'row', TD: 'cell', TH: 'columnheader', P: 'paragraph', DIALOG: 'dialog',
        SUMMARY: 'button', HR: 'separator', OPTION: 'option', FIELDSET: 'group', ARTICLE: 'article',
        IFRAME: 'iframe', FORM: 'form', H1: 'heading', H2: 'heading', H3: 'heading', H4: 'heading', H5: 'heading',
        H6: 'heading', A: (node) => node.hasAttribute('href') ? 'link' : null,
        IMG: (node) => node.getAttribute('alt') === '' ? null : 'img',
        SELECT: (node) => node.multiple || node.size > 1 ? 'listbox' : 'combobox' };
      const roleOf = (node) => {
        const explicit = (node.getAttribute('role') || '').split(' ')[0];
        if (explicit) return ['presentation', 'none', 'generic'].includes(explicit) ? null : explicit;
        if (node.tagName === 'INPUT') return node.type === 'hidden' ? null : inputRoles[node.type] || 'textbox';
        if (node.isContentEditable && !node.parentElement?.isContentEditable) return 'textbox';
        const role = tagRoles[node.tagName];
        return typeof role === 'function' ? role(node) : role || null;
      };
      // These show their name or value, and their content adds nothing a Ref can use.
      const leaves = new Set(['button', 'link', 'heading', 'textbox', 'searchbox', 'combobox', 'listbox', 'img',
        'checkbox', 'radio', 'switch', 'slider', 'spinbutton', 'separator', 'option', 'menuitem', 'tab', 'iframe']);
      const namedByContent = new Set(['button', 'link', 'heading', 'option', 'menuitem', 'tab', 'switch']);
      const nameOf = (node, role) => {
        const label = node.getAttribute('aria-label');
        if (label) return clean(label);
        const labelledBy = (node.getAttribute('aria-labelledby') || '').split(/\s+/)
          .map((id) => document.getElementById(id)).filter(Boolean).map(textOf).join(' ');
        if (labelledBy) return clean(labelledBy);
        if (node.labels?.length) return clean([...node.labels].map(textOf).join(' '));
        if (node.tagName === 'IMG') return clean(node.getAttribute('alt'));
        if (node.tagName === 'INPUT' && ['button', 'submit', 'reset'].includes(node.type)) return clean(node.value);
        if (namedByContent.has(role)) return textOf(node);
        return clean(node.getAttribute('title') || node.getAttribute('placeholder'));
      };
      const valueOf = (node, role) => {
        if (node.tagName === 'SELECT') return [...node.selectedOptions].map((option) => clean(option.label)).join(', ');
        if (!['textbox', 'searchbox', 'spinbutton', 'slider'].includes(role)) return undefined;
        if (node.isContentEditable) return textOf(node);
        return node.type === 'password' && node.value ? '••••' : node.value;
      };
      const statesOf = (node, role) => {
        const states = [];
        if (role === 'heading') states.push('level=' + (node.getAttribute('aria-level') || node.tagName.slice(1)));
        if (node.checked || node.getAttribute('aria-checked') === 'true') states.push('checked');
        if (node.selected && node.closest('select[multiple]') || node.getAttribute('aria-selected') === 'true') states.push('selected');
        if (node.disabled || node.getAttribute('aria-disabled') === 'true') states.push('disabled');
        if (node.getAttribute('aria-expanded') === 'true') states.push('expanded');
        return states;
      };

      const tree = (parent) => {
        const nodes = [];
        for (const child of (parent.shadowRoot || parent).childNodes) {
          if (child.nodeType === Node.TEXT_NODE) {
            const text = clean(child.textContent);
            if (text) nodes.push({ text });
            continue;
          }
          if (child.nodeType !== Node.ELEMENT_NODE || skipped.has(child.tagName) || hidden(child)) continue;
          const role = roleOf(child);
          if (!role) {
            if (child.tagName.toLowerCase() !== 'svg') nodes.push(...tree(child));
            continue;
          }
          nodes.push({ role, name: short(nameOf(child, role)), ref: ref(child), states: statesOf(child, role),
            value: valueOf(child, role), url: role === 'link' ? child.href : undefined,
            children: leaves.has(role) ? [] : tree(child) });
        }
        // Text split by inline elements, such as <b>, reads as one line.
        return nodes.reduce((merged, node) => {
          const last = merged[merged.length - 1];
          if (node.text !== undefined && last?.text !== undefined) last.text += ' ' + node.text;
          else merged.push(node);
          return merged;
        }, []);
      };
      const render = (nodes, indent, lines) => {
        for (const node of nodes) {
          if (node.text !== undefined) {
            lines.push(`${indent}- text: ${short(node.text)}`);
            continue;
          }
          let line = `${indent}- ${node.role}` + (node.name ? ` ${JSON.stringify(node.name)}` : '')
            + node.states.map((state) => ` [${state}]`).join('') + ` [ref=${node.ref}]`;
          const onlyText = node.children.length === 1 && node.children[0].text !== undefined;
          if (node.value !== undefined && node.value !== '') line += `: ${short(node.value)}`;
          else if (onlyText && !node.url) line += `: ${short(node.children[0].text)}`;
          else if (node.children.length || node.url) line += ':';
          lines.push(line);
          if (node.url) lines.push(`${indent}  - /url: ${node.url}`);
          if (!onlyText || node.url) render(node.children, indent + '  ', lines);
        }
        return lines;
      };

      const keyCode = (key) => /^[a-z]$/i.test(key) ? 'Key' + key.toUpperCase() : /^[0-9]$/.test(key) ? 'Digit' + key
        : key === ' ' ? 'Space' : key;
      const editable = (node) => node.isContentEditable || node.tagName === 'TEXTAREA'
        || node.tagName === 'INPUT' && !nonText.has(node.type);
      const mouse = (node, type) => {
        const box = node.getBoundingClientRect();
        const init = { bubbles: true, cancelable: true, composed: true, button: 0, view: window,
          clientX: box.left + box.width / 2, clientY: box.top + box.height / 2 };
        node.dispatchEvent(type.startsWith('pointer')
          ? new PointerEvent(type, { ...init, pointerType: 'mouse', isPrimary: true }) : new MouseEvent(type, init));
      };

      return {
        snapshot: () => render(tree(document.body || document.documentElement), '', []).join('\n'),
        click: (name) => {
          const node = element(name);
          if (node.disabled) throw new Error(`${name} is disabled`);
          node.scrollIntoView({ block: 'center', inline: 'center' });
          mouse(node, 'pointerdown');
          mouse(node, 'mousedown');
          node.focus({ preventScroll: true });
          mouse(node, 'pointerup');
          mouse(node, 'mouseup');
          // click() also does what the element does on a click: follows a link, checks a box, submits a form.
          node.click();
          return true;
        },
        fill: (name, text) => {
          const node = element(name);
          if (node.disabled || node.readOnly) throw new Error(`${name} does not take text: it is disabled or read-only`);
          node.scrollIntoView({ block: 'center', inline: 'center' });
          node.focus({ preventScroll: true });
          if (node.isContentEditable) {
            getSelection().selectAllChildren(node);
            document.execCommand('insertText', false, text);
            return true;
          }
          if (node.tagName === 'SELECT') {
            const option = [...node.options].find((option) => option.value === text || clean(option.label) === text);
            if (!option) throw new Error(`${name} has no option ${JSON.stringify(text)}`);
            node.value = option.value;
          } else if (node.tagName === 'TEXTAREA' || node.tagName === 'INPUT' && !nonText.has(node.type)) {
            // The prototype's setter, not the element's: React replaces the element's value property to track it,
            // and finds a change only when the value moved past its tracker.
            const prototype = node.tagName === 'INPUT' ? HTMLInputElement.prototype : HTMLTextAreaElement.prototype;
            Object.getOwnPropertyDescriptor(prototype, 'value').set.call(node, text);
          } else {
            throw new Error(`${name} is not a field that takes text; click it`);
          }
          node.dispatchEvent(new InputEvent('input', { bubbles: true, composed: true, inputType: 'insertText', data: text }));
          node.dispatchEvent(new Event('change', { bubbles: true }));
          return true;
        },
        press: (key, name) => {
          const node = name ? element(name) : document.activeElement || document.body;
          if (name) node.focus({ preventScroll: true });
          const init = { key, code: keyCode(key), bubbles: true, cancelable: true, composed: true };
          if (node.dispatchEvent(new KeyboardEvent('keydown', init))) {
            if ([...key].length === 1) {
              node.dispatchEvent(new KeyboardEvent('keypress', init));
              if (editable(node)) document.execCommand('insertText', false, key);
            } else if (key === 'Backspace' && editable(node)) {
              document.execCommand('delete');
            } else if (key === 'Enter') {
              if (node.tagName === 'INPUT' && node.form) node.form.requestSubmit();
              else if (editable(node)) document.execCommand('insertLineBreak');
              else if (node.matches('button, a[href], summary, [role=button], [role=link]')) node.click();
            }
          }
          node.dispatchEvent(new KeyboardEvent('keyup', init));
          return true;
        },
        loaded: () => document.readyState === 'complete',
        hasText: (text) => (document.body?.innerText || '').includes(text),
        hasElement: (selector) => {
          const node = document.querySelector(selector);
          return Boolean(node) && !hidden(node);
        },
      };
    })();
    """#
}
