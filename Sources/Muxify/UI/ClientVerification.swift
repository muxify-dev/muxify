import SwiftUI

struct ClientVerification: ViewModifier {
    let store: WorkspaceStore

    func body(content: Content) -> some View {
        #if DEBUG
        content.overlay(alignment: .bottomTrailing) {
            Color.clear.frame(width: 1, height: 1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Client input")
                .accessibilityIdentifier("client-input")
                .accessibilityActions {
                    Button("Client input") {
                        store.surface?.insertText(" ", replacementRange: NSRange(location: NSNotFound, length: 0))
                    }
                    Button("Reattach Client") { store.reattach() }
                    Button("New Window") { store.ghosttyNewTab() }
                    Button("Paste Fixture Image") { pasteFixture(image: true) }
                    Button("Drop Fixture File") { pasteFixture(image: false) }
                }
        }
        #else
        content
        #endif
    }

    #if DEBUG
    /// Private pasteboards leave the user's clipboard intact. These actions
    /// reach the same attachment input as Paste and a system drop, without focus.
    private func pasteFixture(image: Bool) {
        guard TestDriver.isRunning, let path = ProcessInfo.processInfo.environment["MUXIFY_TEST_DRIVER"] else { return }
        let root = URL(fileURLWithPath: path).deletingLastPathComponent()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        if image {
            guard let data = try? Data(contentsOf: root.appendingPathComponent("paste.png")) else { return }
            pasteboard.setData(data, forType: .png)
        } else {
            guard let path = try? String(contentsOf: root.appendingPathComponent("paste-file"), encoding: .utf8) else { return }
            pasteboard.writeObjects([URL(fileURLWithPath: path) as NSURL])
        }
        _ = store.surface?.pasteAttachments(from: pasteboard)
    }
    #endif
}
