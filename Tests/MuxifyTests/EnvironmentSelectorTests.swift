import AppKit
import SwiftUI
import XCTest
@testable import MuxifyCore
import MuxifyTestSupport

final class EnvironmentSelectorTests: XCTestCase {
    /// Render the real Menu through AppKit, not just its isolated SwiftUI label:
    /// the borderless-menu regression discards that label's background/colors.
    /// The regression does not depend on the connection state, so each scheme renders one: the two states that draw
    /// an indicator. EnvironmentBadgeTests maps each state to its indicator.
    @MainActor func testNativeRemoteMenuKeepsBlueBadgeInBothSchemesWhileItsIndicatorShows() throws {
        let remote = RemoteEnvironment(name: "Macbook Home", host: "home", username: "user")
        let renders: [(String, ColorScheme, Bool)] = [("connecting, light", .light, false), ("disconnected, dark", .dark, true)]
        for (name, scheme, hasError) in renders {
            let image = try render(EnvironmentSelector(environments: [remote], activeEnvironment: remote,
                                                       isConnected: false, hasConnectionError: hasError,
                                                       status: "Remote", onSelect: { _ in }), scheme: scheme)
            XCTAssertGreaterThan(bluePixels(in: image), 300, "Native Menu lost the blue badge: \(name)")
        }
    }

    @MainActor func testNativeLocalMenuStaysNeutral() throws {
        for scheme in [ColorScheme.light, .dark] {
            let image = try render(EnvironmentSelector(environments: [], activeEnvironment: nil,
                                                       isConnected: true, hasConnectionError: false,
                                                       status: "Local", onSelect: { _ in }), scheme: scheme)
            XCTAssertEqual(bluePixels(in: image), 0)
        }
    }

    @MainActor private func render(_ selector: EnvironmentSelector, scheme: ColorScheme) throws -> NSBitmapImageRep {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: selector.padding(4)
            .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.95))
            .environment(\.colorScheme, scheme))
        // A hidden, disposable window; never launch Muxify or attach to tmux.
        let frame = NSRect(x: 0, y: 0, width: 240, height: 30)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil }
        host.frame = frame
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        waitForTheMainQueue()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        withExtendedLifetime(window) {}
        return bitmap
    }

    private func bluePixels(in image: NSBitmapImageRep) -> Int {
        var count = 0
        for y in 0..<image.pixelsHigh {
            for x in 0..<image.pixelsWide {
                guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.redComponent < 0.3, color.greenComponent > 0.2, color.greenComponent < 0.5, color.blueComponent > 0.6 {
                    count += 1
                }
            }
        }
        return count
    }
}
