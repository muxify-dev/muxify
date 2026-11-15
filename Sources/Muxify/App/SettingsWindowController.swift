import AppKit
import SwiftUI

/// The Settings window (ADR 0074): one for the app's life, so a second Settings… brings it forward, and its model
/// keeps the draft while it is closed.
final class SettingsWindowController: NSWindowController {
    init(model: SettingsModel) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.contentMinSize = NSSize(width: 820, height: 540)
        window.isReleasedWhenClosed = false
        // Settings closes; it neither minimizes nor zooms.
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        let content = NSHostingView(rootView: SettingsView(model: model))
        content.sizingOptions = []
        // SettingsView's navigationTitle names the section shown.
        content.sceneBridgingOptions = [.title]
        window.contentView = content
        window.center()
        window.setFrameAutosaveName("Settings")
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
