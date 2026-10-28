#if DEBUG
import AppKit
import MuxifyCore

/// Lets scripts/verify drive a Debug build through its accessibility tree.
/// The script writes `command.json` (with a fresh nonce) into the folder
/// named by MUXIFY_TEST_DRIVER; a timer on the main run loop answers each new
/// nonce in `result.json`. Commands: dump, press, set, focus, action, drag, hover, snapshot, responder, scroll, stall,
/// each with the option `reveal` that scrolls the target into view first. None of
/// them activates the app, opens a menu or moves the pointer, so a run never takes focus.
enum TestDriver {
    private static var activity: NSObjectProtocol?
    private static var timer: Timer?
    private static var lastNonce: String?
    /// True when a verify run drives this process.
    private(set) static var isRunning = false

    /// Call before anything else at launch: it must see TMUX before
    /// AppEnvironment clears it, and must refuse before the first tmux call.
    static func startIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard let folderPath = environment["MUXIFY_TEST_DRIVER"] else { return }
        let folder = URL(fileURLWithPath: folderPath)
        if let reason = sandboxViolation(folder: folder, environment: environment) {
            FileHandle.standardError.write(Data("muxify test driver: refusing to start: \(reason)\n".utf8))
            exit(1)
        }
        isRunning = true

        // A verify run keeps the app in the background; without this, App Nap
        // throttles the timer and every command waits seconds.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical], reason: "Muxify test driver")

        let timer = Timer(timeInterval: 0.02, repeats: true) { _ in poll(folder) }
        // Context menus and sheets run the main loop in their own modes.
        for mode in [RunLoop.Mode.common, .eventTracking, .modalPanel] {
            RunLoop.main.add(timer, forMode: mode)
        }
        self.timer = timer
        watchStalls(folder)
        try? "ready \(getpid())".write(to: folder.appendingPathComponent("ready"), atomically: true, encoding: .utf8)
    }

    /// The driver only runs against a throwaway tmux server: TMUX_TMPDIR must
    /// sit inside the sandbox root (the driver folder's parent) and TMUX, which
    /// tmux prefers over TMUX_TMPDIR, must be unset.
    private static func sandboxViolation(folder: URL, environment: [String: String]) -> String? {
        if environment["TMUX"] != nil { return "TMUX is set, so tmux would use that server" }
        guard let tmpdir = environment["TMUX_TMPDIR"], !tmpdir.isEmpty else {
            return "TMUX_TMPDIR is not set, so tmux would use the default server"
        }
        let root = folder.deletingLastPathComponent().resolvingSymlinksInPath().path
        let tmux = URL(fileURLWithPath: tmpdir).resolvingSymlinksInPath().path
        if root == "/" || !tmux.hasPrefix(root + "/") {
            return "TMUX_TMPDIR \(tmux) is not inside the sandbox root \(root)"
        }
        return nil
    }

    private static var lastTick = Date()

    /// Writes a sample of the process to `stall-<n>.txt` in the driver folder when the main run loop has
    /// not reached the poll timer for two seconds, so a driver timeout leaves the main thread's stack behind.
    private static func watchStalls(_ folder: URL) {
        DispatchQueue.global(qos: .utility).async {
            var count = 0
            while true {
                Thread.sleep(forTimeInterval: 0.5)
                let late = Date().timeIntervalSince(lastTick)
                guard late > 2 else { continue }
                count += 1
                let path = folder.appendingPathComponent("stall-\(count).txt").path
                NSLog("muxify test driver: main thread late by %.1f s, sampling to %@", late, path)
                let sample = Process()
                sample.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
                sample.arguments = [String(getpid()), "2", "-mayDie", "-file", path]
                try? sample.start().wait()
            }
        }
    }

    private static func poll(_ folder: URL) {
        lastTick = Date()
        if let pending {
            if let result = pending.step() { answer(result, nonce: pending.nonce, in: folder); self.pending = nil }
            return
        }
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("command.json")),
              let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (command["pid"] as? Int).map(Int32.init) == getpid(),
              let nonce = command["nonce"] as? String, nonce != lastNonce
        else { return }
        lastNonce = nonce
        if command["reveal"] as? Bool == true, let target = command["target"] as? String, !target.isEmpty {
            pending = Reveal(nonce: nonce, target: target, command: command)
            return
        }
        if ["drag", "click", "hover"].contains(command["command"] as? String), SidebarPagerMotion.isMoving {
            pending = Settle(nonce: nonce, command: command)
            return
        }
        if ["drag", "click"].contains(command["command"] as? String) {
            pending = Drag(nonce: nonce, command: command)
            return
        }
        let started = Date()
        answer(run(command), nonce: nonce, in: folder)
        let took = Date().timeIntervalSince(started)
        if took > 1 {
            NSLog("muxify test driver: %@ %@ took %.1f s", command["command"] as? String ?? "", command["target"] as? String ?? "", took)
        }
    }

    private static func answer(_ result: [String: Any], nonce: String, in folder: URL) {
        var result = result
        result["nonce"] = nonce
        if let json = try? JSONSerialization.data(withJSONObject: result) {
            try? json.write(to: folder.appendingPathComponent("result.json"), options: .atomic)
        }
    }

    /// A command that takes more than one tick: it answers once `step` returns its result.
    private protocol Steps: AnyObject {
        var nonce: String { get }
        func step() -> [String: Any]?
    }

    private static var pending: Steps?

    /// A `click`, `drag` or `hover` that comes while the Sidebar slides between Topics and Sessions waits until the
    /// page is at rest: these aim at the centre of the target's frame, and a dump mid-slide gives a frame that the
    /// row has left by the time the event comes. After two seconds the command runs anyway.
    private final class Settle: Steps {
        let nonce: String
        private let command: [String: Any]
        private let started = Date()
        private var drag: Drag?

        init(nonce: String, command: [String: Any]) {
            self.nonce = nonce
            self.command = command
        }

        func step() -> [String: Any]? {
            if let drag { return drag.step() }
            if SidebarPagerMotion.isMoving, Date().timeIntervalSince(started) < 2 { return nil }
            guard ["drag", "click"].contains(command["command"] as? String) else { return TestDriver.run(command) }
            drag = Drag(nonce: nonce, command: command)
            return nil
        }
    }

    /// `click` presses the target at its centre and lets go there, without moving: a plain click of the mouse.
    /// The option `command_key` holds ⌘ through the click, as a ⌘-click does.
    /// `drag` presses the target, moves to the element named by `text` and lets go there: in its upper quarter,
    /// or its lower quarter with the option `edge: "bottom"`. Each tick hands one mouse event to the window, never through
    /// the window server, so the pointer does not move. The app stays in the background, so the window is not key:
    /// only a gesture that takes the first click (`takesFirstClick` in SidebarView) follows, and a system drag
    /// session would follow the real pointer instead.
    private final class Drag: Steps {
        let nonce: String
        private weak var window: NSWindow?
        private var moves: [(type: NSEvent.EventType, point: NSPoint)] = []
        private let modifierFlags: NSEvent.ModifierFlags
        private var pressed = false

        init(nonce: String, command: [String: Any]) {
            self.nonce = nonce
            modifierFlags = command["command_key"] as? Bool == true ? .command : []
            let elements = TestDriver.dump()
            func frame(_ identifier: String?) -> NSRect? {
                guard let identifier else { return nil }
                return ((elements.first { $0.row["accessibilityIdentifier"] == identifier }?.object)?
                    .value(forKey: "accessibilityFrame") as? NSValue)?.rectValue
            }
            guard let source = frame(command["target"] as? String),
                  let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.contains(NSPoint(x: source.midX, y: source.midY)) })
            else { return }
            let start = NSPoint(x: source.midX, y: source.midY)
            if command["command"] as? String == "click" {
                self.window = window
                moves = [(.leftMouseDown, start), (.leftMouseUp, start)]
                pressed = true
                return
            }
            guard let destination = frame(command["text"] as? String) else { return }
            self.window = window
            // Screen points grow upward, so the upper quarter is near maxY.
            let endY = command["edge"] as? String == "bottom" ? destination.minY + destination.height / 4 : destination.maxY - destination.height / 4
            let points = [start] + (1...8).map { NSPoint(x: start.x, y: start.y + (endY - start.y) * CGFloat($0) / 8) }
            let types = [NSEvent.EventType.leftMouseDown] + Array(repeating: .leftMouseDragged, count: 8) + [.leftMouseUp]
            moves = Array(zip(types, points + [points.last!]))
            pressed = true
        }

        func step() -> [String: Any]? {
            guard let window, !moves.isEmpty else { return ["rows": TestDriver.dump().map(\.row), "pressed": pressed] }
            let (type, point) = moves.removeFirst()
            NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: point), modifierFlags: modifierFlags,
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
                .map(window.sendEvent)
            return nil
        }
    }

    /// A command with `reveal: true` first brings its target into view. A lazy
    /// list builds only the rows it shows, so a row far down is absent from the
    /// accessibility tree until the list scrolls to it. Each tick scrolls one
    /// scroll view of the visible windows half a page further, from the top,
    /// until the target shows; then the target is moved to the top of its scroll
    /// view, so the rows that follow it show too, and the command runs.
    private final class Reveal: Steps {
        let nonce: String
        let target: String
        let command: [String: Any]
        private let scrollViews: [NSScrollView]
        private var index = 0
        private var offset: CGFloat = -1
        private var aligned = false
        private var ticks = 0

        init(nonce: String, target: String, command: [String: Any]) {
            self.nonce = nonce
            self.target = target
            self.command = command
            scrollViews = NSApp.windows.filter(\.isVisible).flatMap { Self.scrollViews(in: $0.contentView) }
                .filter { $0.documentView.map { $0.bounds.height > $0.visibleRect.height } == true }
        }

        /// The result once the command has run, nil while the target is still out of view.
        func step() -> [String: Any]? {
            ticks += 1
            if let element = TestDriver.dump().first(where: { $0.row["accessibilityIdentifier"] == target })?.object {
                // A row of a tall lazy item, such as an open card, is in the tree while it is still out of view,
                // so the scroll view that holds it is the one in the same column when none shows it yet.
                guard !aligned, let frame = (element.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue,
                      let scrollView = scrollViews.first(where: { screenFrame(of: $0)?.intersects(frame) == true })
                          ?? scrollViews.first(where: { screenFrame(of: $0).map { $0.minX...$0.maxX ~= frame.midX } == true }),
                      let clip = screenFrame(of: scrollView) else { return TestDriver.run(command) }
                aligned = true
                scroll(scrollView, by: clip.maxY - frame.maxY)
                return nil
            }
            guard ticks < 500, index < scrollViews.count else { return TestDriver.run(command) }
            let scrollView = scrollViews[index]
            let visible = scrollView.contentView.bounds.height
            let end = (scrollView.documentView?.bounds.height ?? 0) - visible
            if offset >= end {
                index += 1
                offset = -1
                return nil
            }
            offset = offset < 0 ? 0 : min(offset + visible / 2, end)
            scroll(scrollView, to: offset)
            return nil
        }

        private func screenFrame(of scrollView: NSScrollView) -> NSRect? {
            let clip = scrollView.contentView
            return scrollView.window?.convertToScreen(clip.convert(clip.bounds, to: nil))
        }

        private func scroll(_ scrollView: NSScrollView, by delta: CGFloat) {
            let flipped = scrollView.documentView?.isFlipped ?? true
            scroll(scrollView, to: scrollView.contentView.bounds.origin.y + (flipped ? delta : -delta))
        }

        private func scroll(_ scrollView: NSScrollView, to y: CGFloat) {
            let end = max(0, (scrollView.documentView?.bounds.height ?? 0) - scrollView.contentView.bounds.height)
            scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.origin.x, y: min(max(0, y), end)))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        private static func scrollViews(in view: NSView?) -> [NSScrollView] {
            guard let view, !view.isHidden else { return [] }
            return ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
        }
    }

    private static func run(_ command: [String: Any]) -> [String: Any] {
        let name = command["command"] as? String ?? ""
        let target = command["target"] as? String ?? ""
        let text = command["text"] as? String ?? ""
        var pressed = false
        if name == "snapshot" { return ["rows": [], "pressed": snapshot(of: target, to: text)] }
        if name == "hover" { return ["rows": [], "pressed": hover(target)] }
        if name == "scroll" { return ["rows": [], "pressed": scroll(target, fromEnd: command["from_end"] as? Double ?? 0)] }
        // Blocks the main thread for `seconds`, a freeze for Diagnostics to catch.
        if name == "stall" {
            Thread.sleep(forTimeInterval: command["seconds"] as? Double ?? 1)
            return ["rows": [], "pressed": true]
        }
        if name == "responder" {
            let classes = NSApp.windows.filter(\.isVisible).compactMap { $0.firstResponder.map { String(describing: type(of: $0)) } }
            return ["rows": [], "pressed": true, "responders": classes]
        }
        let elements = dump()
        for element in elements {
            let object = element.object
            let identifier = element.row["accessibilityIdentifier"]
            if identifier == target {
                switch name {
                case "action":
                    pressed = performCustomAction(named: text, on: object) || pressed
                case "set" where object.responds(to: Selectors.setValue):
                    // A field with keyboard focus shows its field editor; a value set behind it never
                    // reaches the SwiftUI binding, so the editor takes the text and reports the change.
                    // The element is the field's cell; the field is its control view.
                    let field = object as? NSTextField ?? (object as? NSCell)?.controlView as? NSTextField
                    if let editor = field?.currentEditor() as? NSTextView {
                        editor.string = text
                        editor.didChangeText()
                    } else {
                        _ = object.perform(Selectors.setValue, with: text)
                        // A hidden field's binding hears only its delegate, as when the user types.
                        if let field = field as? NSSecureTextField {
                            field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
                        }
                    }
                    pressed = true
                case "focus" where object.responds(to: Selectors.setFocused):
                    typealias SetFocused = @convention(c) (NSObject, Selector, Bool) -> Void
                    unsafeBitCast(object.method(for: Selectors.setFocused), to: SetFocused.self)(object, Selectors.setFocused, true)
                    pressed = true
                default: break
                }
            }
            let matches = [identifier, element.row["accessibilityTitle"], element.row["accessibilityLabel"]].contains(target)
            if name == "press", matches {
                pressed = press(object) || pressed
            }
        }
        if name == "press", let item = updatedMenuItem(titled: target) {
            pressed = press(item) || pressed
        }
        return ["rows": elements.map(\.row), "pressed": pressed]
    }

    private enum Selectors {
        static let children = NSSelectorFromString("accessibilityChildren")
        static let customActions = NSSelectorFromString("accessibilityCustomActions")
        static let setValue = NSSelectorFromString("setAccessibilityValue:")
        static let setFocused = NSSelectorFromString("setAccessibilityFocused:")
        static let press = NSSelectorFromString("accessibilityPerformPress")
        static let rowKeys = ["accessibilityRole", "accessibilityIdentifier", "accessibilityLabel",
                              "accessibilityTitle", "accessibilityValue", "accessibilityHelp"]
    }

    private static func press(_ object: NSObject) -> Bool {
        if let item = object as? NSMenuItem {
            // SwiftUI rebuilds a menu when state it reads changes, and the dump can hold an item the
            // rebuild has detached or disabled; the live item with the same title takes the press.
            let live = menuItem(titled: item.title, in: NSApp.mainMenu) ?? item
            guard live.isEnabled, let menu = live.menu, menu.index(of: live) >= 0 else {
                NSLog("muxify test driver: menu item %@ refused: enabled=%d menu=%@ stale=%d", item.title, live.isEnabled ? 1 : 0,
                      String(describing: live.menu?.title), live === item ? 0 : 1)
                return false
            }
            menu.cancelTracking()
            menu.performActionForItem(at: menu.index(of: live))
            return true
        }
        if let button = object as? NSButton ?? (object as? NSButtonCell)?.controlView as? NSButton, button.isEnabled {
            button.performClick(nil)
            return true
        }
        if object.responds(to: Selectors.press) {
            typealias Press = @convention(c) (NSObject, Selector) -> Bool
            if unsafeBitCast(object.method(for: Selectors.press), to: Press.self)(object, Selectors.press) { return true }
        }
        let legacyPress = NSSelectorFromString("accessibilityPerformAction:")
        guard object.responds(to: legacyPress) else { return false }
        _ = object.perform(legacyPress, with: NSAccessibility.Action.press.rawValue)
        return true
    }

    /// Draws the App Window's layers, and those of its child windows and sheet, into a PNG at `path`, cut to the element with the identifier `target` when
    /// one is named. It goes through no window server capture, so it needs no screen recording permission and
    /// works while the window is behind other apps.
    private static func snapshot(of target: String, to path: String) -> Bool {
        guard !path.isEmpty, let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }),
              let view = window.contentView?.superview ?? window.contentView, let layer = view.layer else { return false }
        let scale = window.backingScaleFactor
        let size = view.bounds.size
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap)?.cgContext else { return false }
        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        // Child windows, such as a hover label, and a sheet draw over the App Window where they sit on screen.
        for child in (window.childWindows ?? []) + [window.attachedSheet].compactMap({ $0 }) where child.isVisible {
            guard let childLayer = (child.contentView?.superview ?? child.contentView)?.layer else { continue }
            context.saveGState()
            context.translateBy(x: child.frame.minX - window.frame.minX, y: child.frame.minY - window.frame.minY)
            childLayer.render(in: context)
            context.restoreGState()
        }
        guard var image = bitmap.cgImage else { return false }
        if !target.isEmpty {
            guard let screen = (dump().first { $0.row["accessibilityIdentifier"] == target }?.object
                                    .value(forKey: "accessibilityFrame") as? NSValue)?.rectValue else { return false }
            let frame = window.convertFromScreen(screen)
            let crop = CGRect(x: frame.minX * scale, y: (size.height - frame.maxY) * scale, width: frame.width * scale, height: frame.height * scale)
            guard let cropped = image.cropping(to: crop) else { return false }
            image = cropped
        }
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }

    /// Scrolls the scroll view under the element so that the end of its content is `fromEnd` points below its bottom
    /// edge, as a scroll by the user leaves it.
    private static func scroll(_ target: String, fromEnd: CGFloat) -> Bool {
        func scrollViews(in view: NSView?) -> [NSScrollView] {
            guard let view, !view.isHidden else { return [] }
            return ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
        }
        guard let screen = (dump().first { $0.row["accessibilityIdentifier"] == target }?.object
                                .value(forKey: "accessibilityFrame") as? NSValue)?.rectValue,
              let scrollView = NSApp.windows.filter(\.isVisible).flatMap({ scrollViews(in: $0.contentView) }).first(where: { scrollView in
                  let clip = scrollView.contentView
                  return scrollView.window.map { $0.convertToScreen(clip.convert(clip.bounds, to: nil)) }?
                      .contains(NSPoint(x: screen.midX, y: screen.midY)) == true
              }),
              let document = scrollView.documentView else { return false }
        let clip = scrollView.contentView
        let end = max(0, document.bounds.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: min(max(0, end - fromEnd), end)))
        scrollView.reflectScrolledClipView(clip)
        return true
    }

    /// The tracking areas that the last `hover` entered, with their owners and window, so the next one can exit them.
    private static var hovered: [(owner: NSResponder, area: NSTrackingArea, window: NSWindow)] = []

    /// Puts the pointer on the element for the views under it, without moving the real pointer: each tracking area
    /// that the last `hover` entered gets a synthesized exited event, and each tracking area under the new point an
    /// entered and a moved event. A SwiftUI window has one tracking area for all its views, and a moved event alone
    /// does not end the hover of the view the pointer left, so the pointer leaves and comes back, and `onHover`
    /// follows.
    private static func hover(_ target: String) -> Bool {
        guard let screen = (dump().first { $0.row["accessibilityIdentifier"] == target }?.object
                                .value(forKey: "accessibilityFrame") as? NSValue)?.rectValue,
              let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.contains(NSPoint(x: screen.midX, y: screen.midY)) })
        else { return false }
        let point = window.convertPoint(fromScreen: NSPoint(x: screen.midX, y: screen.midY))
        guard let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) else { return false }
        func crossing(_ type: NSEvent.EventType, _ area: NSTrackingArea, in window: NSWindow) -> NSEvent? {
            NSEvent.enterExitEvent(with: type, location: window.convertPoint(fromScreen: NSPoint(x: screen.midX, y: screen.midY)),
                                   modifierFlags: [], timestamp: event.timestamp, windowNumber: window.windowNumber, context: nil,
                                   eventNumber: 0, trackingNumber: unsafeBitCast(area, to: Int.self), userData: nil)
        }
        var entered: [(owner: NSResponder, area: NSTrackingArea, window: NSWindow)] = []
        var view = window.contentView?.hitTest(window.contentView?.convert(point, from: nil) ?? point)
        while let current = view {
            let local = current.convert(point, from: nil)
            for area in current.trackingAreas where area.rect.contains(local) || area.options.contains(.inVisibleRect) {
                if let owner = area.owner as? NSResponder { entered.append((owner, area, window)) }
            }
            view = current.superview
        }
        for left in hovered {
            if let exit = crossing(.mouseExited, left.area, in: left.window) { left.owner.mouseExited(with: exit) }
        }
        for (owner, area, _) in entered {
            guard let enter = crossing(.mouseEntered, area, in: window) else { continue }
            owner.mouseEntered(with: enter)
            if area.options.contains(.mouseMoved) { owner.mouseMoved(with: event) }
        }
        hovered = entered
        return true
    }

    /// The main menu item with the title, after each menu has updated its items as it does before it opens.
    /// SwiftUI builds and enables its menu items only then, so an item that nobody opened can be out of date.
    private static func updatedMenuItem(titled title: String) -> NSMenuItem? {
        func update(_ menu: NSMenu) {
            menu.delegate?.menuNeedsUpdate?(menu)
            menu.update()
            menu.items.compactMap(\.submenu).forEach(update)
        }
        guard let mainMenu = NSApp.mainMenu else { return nil }
        update(mainMenu)
        return menuItem(titled: title, in: mainMenu)
    }

    private static func menuItem(titled title: String, in menu: NSMenu?) -> NSMenuItem? {
        for item in menu?.items ?? [] {
            if item.title == title { return item }
            if let found = menuItem(titled: title, in: item.submenu) { return found }
        }
        return nil
    }

    /// Runs the named custom action (SwiftUI `.accessibilityActions`) the way
    /// VoiceOver does: its handler, or else its target and selector.
    private static func performCustomAction(named name: String, on object: NSObject) -> Bool {
        guard let action = (value(object, Selectors.customActions) as? [NSAccessibilityCustomAction])?
            .first(where: { $0.name == name }) else { return false }
        if let handler = action.handler { return handler() }
        guard let target = action.target as? NSObject, let selector = action.selector else { return false }
        typealias Perform = @convention(c) (NSObject, Selector, NSAccessibilityCustomAction) -> Bool
        return unsafeBitCast(target.method(for: selector), to: Perform.self)(target, selector, action)
    }

    /// Every element of the visible windows, depth first, as the script sees
    /// them. The main menu is not in it: its accessibility children make SwiftUI
    /// update every menu, which takes seconds under load. `press` finds a menu
    /// item by its title.
    private static func dump() -> [(object: NSObject, row: [String: String])] {
        var objects: [NSObject] = []
        var seen = Set<ObjectIdentifier>()
        func collect(_ element: Any?) {
            guard let object = element as? NSObject, objects.count <= 2000,
                  seen.insert(ObjectIdentifier(object)).inserted else { return }
            objects.append(object)
            for child in (value(object, Selectors.children) as? [Any]) ?? [] { collect(child) }
        }
        for window in NSApp.windows where window.isVisible { collect(window) }
        return objects.map { object in
            var row: [String: String] = [:]
            for key in Selectors.rowKeys {
                if let value = value(object, NSSelectorFromString(key)) { row[key] = String(describing: value) }
            }
            // A struct, which `value` cannot return; key-value coding boxes it. Screen points, origin at the bottom left.
            if object.responds(to: NSSelectorFromString("accessibilityFrame")),
               let frame = (object.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue {
                row["accessibilityFrame"] = NSStringFromRect(frame)
            }
            if object.responds(to: NSSelectorFromString("accessibilityActivationPoint")),
               let point = (object.value(forKey: "accessibilityActivationPoint") as? NSValue)?.pointValue {
                row["accessibilityActivationPoint"] = NSStringFromPoint(point)
            }
            return (object, row)
        }
    }

    private static func value(_ object: NSObject, _ selector: Selector) -> Any? {
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue()
    }
}
#endif
