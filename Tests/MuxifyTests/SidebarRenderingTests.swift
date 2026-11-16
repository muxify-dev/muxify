import AppKit
import SwiftUI
import XCTest
@testable import MuxifyCore
import MuxifyTestSupport

final class SidebarRenderingTests: XCTestCase {
    /// Use real row presentation without starting Ghostty or a tmux connection.
    @MainActor func testNativeRowsGrowForLargerFontsAtNarrowWidth() throws {
        for family in ["system", try installedFamily()] {
            let small = try render(rows(), typography: SidebarTypography(fontFamily: family))
            let large = try render(rows(), typography: SidebarTypography(fontSize: InterfaceFontSize(24), fontFamily: family))
            XCTAssertGreaterThan(large.height, small.height, "Rows must grow rather than vertically clip large text: \(family)")
            XCTAssertGreaterThan(small.ink, 0, family)
            XCTAssertGreaterThan(large.ink, 0, family)
            XCTAssertEqual(small.width, 180, family)
            XCTAssertEqual(large.width, 180, family)
        }
    }

    @MainActor func testCardHeaderKeepsALongTitleOnOneLineWhenTitlesDoNotWrap() throws {
        let long = CardHeader(title: "A Session name long enough to need several lines in a narrow Sidebar card",
                              isOpen: true, mark: nil, summary: "") { EmptyView() }
        let short = CardHeader(title: "AgM Session", isOpen: true, mark: nil, summary: "") { EmptyView() }
        let oneLine = try render(short, typography: SidebarTypography())
        let wrapped = try render(long, typography: SidebarTypography())
        let cut = try render(long.environment(\.wrapsCardTitles, false), typography: SidebarTypography())
        XCTAssertGreaterThan(wrapped.height, oneLine.height, "A long title wraps by default")
        XCTAssertEqual(cut.height, oneLine.height, "titles.wrap: false keeps a long title on one line")
        XCTAssertGreaterThan(cut.ink, 0)
    }

    @MainActor func testHostedProductionSidebarObservesConfigEditsAndRecovery() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("muxify-sidebar-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("config.yaml").path
        let config = ConfigStore(path: path)
        let store = WorkspaceStore(configStore: config, defaults: isolatedDefaults(), visitStore: isolatedVisits())
        store.sessionsVisible = true
        store.agentsVisible = false
        let host = NSHostingView(rootView: ConfiguredSidebar(store: store, config: config)
            .background(Color.white).environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 180, height: 180),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil }
        let before = try snapshot(host).ink
        try "ui:\n  font_size: 24\n  sidebar:\n    font_family: system".write(toFile: path, atomically: true, encoding: .utf8)
        config.reload()
        let larger = try snapshot(host).ink
        XCTAssertGreaterThan(larger, before)
        let family = try installedFamily()
        let quotedFamily = family.replacingOccurrences(of: "'", with: "''")
        try "ui:\n  font_size: 24\n  sidebar:\n    font_family: '\(quotedFamily)'"
            .write(toFile: path, atomically: true, encoding: .utf8)
        config.reload()
        let custom = try snapshot(host).ink
        XCTAssertEqual(config.config.sidebarFontFamily, family)
        XCTAssertNotEqual(custom, larger, "A family-only edit must update the rendered text")
        try "ui: [".write(toFile: path, atomically: true, encoding: .utf8)
        config.reload()
        XCTAssertEqual(try snapshot(host).ink, custom, "A syntax error must retain the rendered last-good font")
        try "ui:\n  font_size: 24\n  sidebar:\n    font_family: MuxifyMissingFont-\(UUID().uuidString)"
            .write(toFile: path, atomically: true, encoding: .utf8)
        config.reload()
        XCTAssertEqual(config.problems.count, 1)
        XCTAssertEqual(try snapshot(host).ink, larger, "An unavailable family falls back independently of size")
        try FileManager.default.removeItem(atPath: path)
        config.reload()
        XCTAssertEqual(try snapshot(host).ink, before)
        XCTAssertTrue(store.sessionsVisible)
        XCTAssertFalse(store.agentsVisible)
        withExtendedLifetime(window) {}
    }

    /// The Sidebar as the App Window's root wires it: the Interface font size in the environment, from the App
    /// Window's own Config.
    private struct ConfiguredSidebar: View {
        let store: WorkspaceStore
        let config: ConfigStore
        var body: some View {
            SidebarView(store: store, fontFamily: store.config.sidebarFontFamily)
                .environment(\.interfaceFontSize, store.config.interfaceFontSize)
        }
    }

    @MainActor private func installedFamily() throws -> String {
        try XCTUnwrap(SidebarTypography.fontFamilies.first { family in
            SidebarTypography.lookup(family: family, weight: 5, size: 12) != nil
        })
    }

    @MainActor private func rows() -> some View {
        let window = TmuxWindow.fixture(sessionName: "A very long Session name with AgM descenders", index: 1,
                                        paneTitle: "A very long Window title with AgM descenders", path: "/test", command: "fish",
                                        paneCount: 3, hasBell: true)
        let agent = Agent(paneID: "%1", kind: .codex, status: .failed, unread: true, windowID: "@1", sessionID: "$1",
                          sessionName: window.sessionName, windowIndex: 1, windowTitle: window.displayTitle,
                          label: window.displayTitle)
        return VStack(spacing: 0) {
            CardHeader(title: window.sessionName, isOpen: false, mark: nil, summary: "1 Window") { EmptyView() }
            WindowRow(window: window, isSelected: false, tabCount: 12)
            WindowRow(window: window, isSelected: true, tabCount: 12)
            AgentRow(agent: agent, text: .init(title: agent.label, summary: window.sessionName), mark: .failed)
        }
    }

    @MainActor private func render<V: View>(_ view: V, typography: SidebarTypography) throws -> (width: CGFloat, height: CGFloat, ink: Int) {
        _ = NSApplication.shared
        // The App Window puts the Interface font size into the environment, and the Sidebar's typography takes its base
        // from that same value.
        let host = NSHostingView(rootView: view.environment(\.sidebarTypography, typography)
            .environment(\.interfaceFontSize, typography.fontSize)
            .frame(width: 180).background(Color.white)
            .environment(\.colorScheme, .light))
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil }
        let image = try snapshot(host)
        withExtendedLifetime(window) {}
        return image
    }

    @MainActor private func snapshot<V: View>(_ host: NSHostingView<V>) throws -> (width: CGFloat, height: CGFloat, ink: Int) {
        host.window?.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        var ink = 0
        for y in 0..<image.pixelsHigh {
            for x in 0..<image.pixelsWide {
                guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if min(color.redComponent, color.greenComponent, color.blueComponent) < 0.9 { ink += 1 }
            }
        }
        return (host.bounds.width, host.bounds.height, ink)
    }
}
