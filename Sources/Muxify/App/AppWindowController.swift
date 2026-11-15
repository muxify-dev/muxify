import AppKit
import SwiftUI

/// One App Window (ADR 0083). The App Windows coordinator makes one for each App Window request, and it keeps that
/// request for its life. The window hides its title bar, as SwiftUI's `.hiddenTitleBar` did, so the traffic lights sit
/// over the header. Its content view is an AppKit container that holds one hosting view of `AppWindowView`.
final class AppWindowController: NSWindowController, NSWindowDelegate {
    /// Where the next App Window opens: each steps down from the last, as a WindowGroup's windows did.
    private static var cascadePoint = NSPoint.zero
    private let request: AppWindowRequest
    private let store: WorkspaceStore

    init(request: AppWindowRequest, store: WorkspaceStore, windows: AppWindows) {
        self.request = request
        self.store = store
        let frame = NSRect(x: 0, y: 0, width: 1500, height: 920)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentMinSize = NSSize(width: 820, height: 480)
        window.isReleasedWhenClosed = false
        window.restorationClass = AppWindowRestoration.self
        window.identifier = AppWindowRestoration.identifier
        let content = NSHostingView(rootView: AppWindowView(id: request.id, store: store, windows: windows))
        // The window sets the size. ContentView ignores the title bar's safe area, so the header is drawn under it.
        content.sizingOptions = []
        // ContentView's navigationTitle names the window for the Window menu and Mission Control.
        content.sceneBridgingOptions = [.title]
        content.frame = frame
        content.autoresizingMask = [.width, .height]
        let container = NSView(frame: frame)
        container.addSubview(content)
        window.contentView = container
        window.center()
        Self.cascadePoint = window.cascadeTopLeft(from: Self.cascadePoint)
        super.init(window: window)
        window.delegate = self
        windows.register(window, for: request.id)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The request that brings this App Window back, on the Environment it shows now.
    func window(_ window: NSWindow, willEncodeRestorableState state: NSCoder) {
        AppWindowRestoration.encode(AppWindowRequest(id: request.id, environmentName: store.activeEnvironment?.name), in: state)
    }
}

/// Brings App Windows back at launch when macOS keeps windows on quit, or Sparkle relaunches after an update. Each App
/// Window's window encodes its request; this asks the App Windows coordinator for the App Window of each one.
final class AppWindowRestoration: NSObject, NSWindowRestoration {
    static let identifier = NSUserInterfaceItemIdentifier("AppWindow")
    private static let key = "request"

    static func encode(_ request: AppWindowRequest, in state: NSCoder) {
        state.encode(try? JSONEncoder().encode(request), forKey: key)
    }

    static func restoreWindow(withIdentifier identifier: NSUserInterfaceItemIdentifier, state: NSCoder,
                              completionHandler: @escaping (NSWindow?, Error?) -> Void) {
        guard identifier == Self.identifier, let data = state.decodeObject(of: NSData.self, forKey: key) as Data?,
              let request = try? JSONDecoder().decode(AppWindowRequest.self, from: data),
              let windows = (NSApp.delegate as? AppDelegate)?.windows else {
            completionHandler(nil, CocoaError(.coderReadCorrupt))
            return
        }
        completionHandler(windows.restoreWindow(for: request), nil)
    }
}
