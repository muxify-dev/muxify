import AppKit
import SwiftUI

struct AppWindowView: View {
    let request: AppWindowRequest
    let windows: AppWindows
    @State private var identity = AppWindowIdentity()
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let shown = identity.resolve(request, in: windows)
        ContentView(store: shown.store, configStore: windows.configStore)
            .frame(minWidth: 820, minHeight: 480)
            // Otherwise SwiftUI creates a new scene for each muxify:// URL
            // even though AppDelegate already routes it through AppWindows.
            .handlesExternalEvents(preferring: windows.focusedID == shown.request.id ? ["*"] : [], allowing: ["*"])
            .background(AppWindowRegistration { windows.register($0, for: shown.request.id) })
            .onAppear {
                let action = openWindow
                windows.openWindow = { action(id: "workspace", value: $0) }
                let settings = openSettings
                windows.openSettings = { settings() }
            }
            .onChange(of: shown.store.activeEnvironment) { _, _ in windows.updateEnvironment(for: shown.request.id) }
    }
}

/// At launch SwiftUI shows the window with the default value, then hands the
/// same window its restored value. The window keeps the request it first
/// showed, so its store, native window, focus and `@muxify_open` consumer
/// stay one App Window, and the restored value gets no store of its own.
@MainActor final class AppWindowIdentity {
    private var shown: (request: AppWindowRequest, store: WorkspaceStore)?

    func resolve(_ request: AppWindowRequest, in windows: AppWindows) -> (request: AppWindowRequest, store: WorkspaceStore) {
        if let shown { return shown }
        let first = (request: request, store: windows.store(for: request))
        shown = first
        return first
    }
}

struct AppWindowRegistration: NSViewRepresentable {
    let register: (NSWindow) -> Void
    func makeNSView(context: Context) -> RegistrationView { RegistrationView() }
    func updateNSView(_ view: RegistrationView, context: Context) { view.register = register; view.registerWindow() }

    final class RegistrationView: NSView {
        var register: ((NSWindow) -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); registerWindow() }
        func registerWindow() {
            guard let window else { return }
            // Register outside SwiftUI layout; focus can update menu state.
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window else { return }
                self.register?(window)
            }
        }
    }
}
