import AppKit
import SwiftUI

/// One App Window (ADR 0083). The App Windows coordinator makes one for each App Window request, and it keeps that
/// request for its life. The window hides its title bar, as SwiftUI's `.hiddenTitleBar` did, so the traffic lights sit
/// over the header. Its content view is an AppKit container that holds one hosting view of `AppWindowView`.
final class AppWindowController: NSWindowController {
    /// Where the next App Window opens: each steps down from the last, as a WindowGroup's windows did.
    private static var cascadePoint = NSPoint.zero

    init(request: AppWindowRequest, store: WorkspaceStore, windows: AppWindows) {
        let frame = NSRect(x: 0, y: 0, width: 1500, height: 920)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentMinSize = NSSize(width: 820, height: 480)
        window.isReleasedWhenClosed = false
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
        windows.register(window, for: request.id)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
