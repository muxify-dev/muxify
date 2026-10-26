import AppKit
import SwiftUI
import XCTest
@testable import MuxifyCore

final class AgentMarkViewTests: XCTestCase {
    private let gray = AgentColors()[.working].color

    func testWorkingPhaseAdvancesAndLoopsOnTheSharedClock() {
        let period = TerminalActivityIndicator.period
        for cycles in [0.0, 0.25, 0.92, 1.0, 1.25, 100.25, -0.75] {
            let phase = TerminalActivityIndicator.phase(at: Date(timeIntervalSinceReferenceDate: cycles * period))
            XCTAssertEqual(phase, cycles - floor(cycles), accuracy: 0.000001)
            XCTAssertGreaterThanOrEqual(phase, 0)
            XCTAssertLessThan(phase, 1)
        }
    }

    func testPixelCellsFormAThreeByThreeSquareInClockwiseOrder() {
        let cells = TerminalActivityGlyph.cells
        XCTAssertEqual(cells.count, 8)
        XCTAssertEqual(Set(cells.map(\.x)).count, 3)
        XCTAssertEqual(Set(cells.map(\.y)).count, 3)
        for (index, cell) in cells.enumerated() {
            XCTAssertTrue(cell.x == 0 || cell.x == 2 || cell.y == 0 || cell.y == 2)
            XCTAssertEqual(cells.filter { $0 == cell }.count, 1)
            let next = cells[(index + 1) % cells.count]
            XCTAssertEqual(abs(next.x - cell.x) + abs(next.y - cell.y), 1)
        }
        XCTAssertEqual(cells[1], CGPoint(x: 1, y: 0))
        XCTAssertEqual(cells[2], CGPoint(x: 2, y: 0))
        XCTAssertEqual(cells[3], CGPoint(x: 2, y: 1))
    }

    func testSharedClockDoesNotRepeatOrSkipPixelsAtTickBoundaries() {
        let period = TerminalActivityIndicator.period
        let count = TerminalActivityGlyph.cells.count
        for cycle in [0.0, 10000.0, 700000000.0, -1.0] {
            for step in 0..<(count * 2) {
                let time = cycle * period + Double(step) * period / Double(count)
                let phase = TerminalActivityIndicator.phase(at: Date(timeIntervalSinceReferenceDate: time))
                XCTAssertEqual(TerminalActivityGlyph.head(at: phase), step % count)
            }
        }
    }

    @MainActor func testThreePointPixelsFitInATenPointIndicatorFootprint() {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: TerminalActivityGlyph(phase: 0, color: gray))
        XCTAssertEqual(host.fittingSize.width, 10)
        XCTAssertEqual(host.fittingSize.height, 10)
        XCTAssertEqual(TerminalActivityGlyph.blockSize, 3)
    }

    @MainActor func testWorkingGlyphIsAGraySquareWithAnEmptyCenterInBothSchemes() throws {
        for scheme in [ColorScheme.light, .dark] {
            for phase in [0.0, 0.25, 0.92] {
                let image = try render(TerminalActivityGlyph(phase: phase, color: gray), scheme: scheme)
                let background = try color(image, x: 0, y: 0)
                var xs: [Int] = []
                var ys: [Int] = []
                for y in 0..<image.pixelsHigh {
                    for x in 0..<image.pixelsWide {
                        let pixel = try color(image, x: x, y: y)
                        guard abs(pixel.redComponent - background.redComponent) > 0.04 else { continue }
                        XCTAssertEqual(pixel.redComponent, pixel.greenComponent, accuracy: 0.025)
                        XCTAssertEqual(pixel.greenComponent, pixel.blueComponent, accuracy: 0.025)
                        xs.append(x)
                        ys.append(y)
                    }
                }
                let width = try XCTUnwrap(xs.max()) - XCTUnwrap(xs.min())
                let height = try XCTUnwrap(ys.max()) - XCTUnwrap(ys.min())
                XCTAssertEqual(width, height, "The pixel perimeter must be square")
                let center = try color(image, x: image.pixelsWide / 2, y: image.pixelsHigh / 2)
                XCTAssertEqual(center.redComponent, background.redComponent, accuracy: 0.01)
            }
        }
    }

    @MainActor func testPixelsStepAlongThePerimeterRatherThanMovingContinuously() throws {
        let count = Double(TerminalActivityGlyph.cells.count)
        for scheme in [ColorScheme.light, .dark] {
            let first = try render(TerminalActivityGlyph(phase: 0.1 / count, color: gray), scheme: scheme)
            let sameStep = try render(TerminalActivityGlyph(phase: 0.9 / count, color: gray), scheme: scheme)
            let later = try render(TerminalActivityGlyph(phase: 1.1 / count, color: gray), scheme: scheme)
            let looped = try render(TerminalActivityGlyph(phase: 1 + 0.1 / count, color: gray), scheme: scheme)
            XCTAssertEqual(try pixels(first), try pixels(sameStep))
            XCTAssertNotEqual(try pixels(first), try pixels(later))
            XCTAssertEqual(try pixels(first), try pixels(looped))
        }
    }

    @MainActor func testWorkingGlyphDrawsEightSeparateSquareBlocksNotAnOutline() throws {
        for scheme in [ColorScheme.light, .dark] {
            let native = try render(TerminalActivityGlyph(phase: 0, color: gray), scheme: scheme)
            let nativeScale = CGFloat(native.pixelsWide) / 32
            try assertSeparateBlocks(native, expectedSize: nativeScale == 1 ? 2 : 3)
            for scale in [CGFloat(1), 2] {
                for phase in [0.0, 0.25, 0.92] {
                    let image = try render(TerminalActivityGlyph(phase: phase, color: gray), scheme: scheme, scale: scale)
                    XCTAssertEqual(image.pixelsWide, Int(32 * scale))
                    XCTAssertEqual(image.pixelsHigh, Int(24 * scale))
                    try assertSeparateBlocks(image, expectedSize: scale == 1 ? 2 : 3)
                }
            }
        }
    }

    private func assertSeparateBlocks(_ image: NSBitmapImageRep, expectedSize: CGFloat,
                                      file: StaticString = #filePath, line: UInt = #line) throws {
        let background = try color(image, x: 0, y: 0).redComponent
        var remaining = Set(try pixels(image).enumerated().compactMap { index, red in
            abs(red - background) > 0.04 ? index : nil
        })
        var blocks = 0
        while let first = remaining.first {
            remaining.remove(first)
            var pending = [first]
            var xs: [Int] = []
            var ys: [Int] = []
            while let pixel = pending.popLast() {
                let x = pixel % image.pixelsWide
                let y = pixel / image.pixelsWide
                xs.append(x)
                ys.append(y)
                for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                    let nextX = x + dx
                    let nextY = y + dy
                    guard (0..<image.pixelsWide).contains(nextX), (0..<image.pixelsHigh).contains(nextY) else { continue }
                    let next = nextY * image.pixelsWide + nextX
                    if remaining.remove(next) != nil { pending.append(next) }
                }
            }
            XCTAssertEqual(xs.max()! - xs.min()!, ys.max()! - ys.min()!, "Each disconnected block must be square",
                           file: file, line: line)
            let scale = CGFloat(image.pixelsWide) / 32
            XCTAssertEqual(CGFloat(xs.max()! - xs.min()! + 1) / scale, expectedSize,
                           "The rendered blocks must retain their gaps at each display scale",
                           file: file, line: line)
            blocks += 1
        }
        XCTAssertEqual(blocks, 8, "The pixels must have visible gaps, not form a continuous outline",
                       file: file, line: line)
    }

    @MainActor func testPulseOffOrReduceMotionKeepsTheWorkingMarkStill() throws {
        for scheme in [ColorScheme.light, .dark] {
            let still = try pixels(render(TerminalActivityIndicator(moves: false, color: gray), scheme: scheme))
            let pulseOff = try pixels(render(AgentMarkView(mark: .working).environment(\.pulses, false), scheme: scheme))
            XCTAssertEqual(still, try pixels(render(TerminalActivityGlyph(phase: 0, color: gray), scheme: scheme)))
            XCTAssertEqual(pulseOff, still)
        }
    }

    @MainActor func testNotificationsAreBlueForDoneRedForFailedAndOrangeForBlocked() throws {
        for scheme in [ColorScheme.light, .dark] {
            for spine in [false, true] {
                func center(_ mark: AgentMark) throws -> NSColor {
                    let image = spine ? try render(AgentMarkSpine(mark: mark).frame(width: 3, height: 20), scheme: scheme)
                        : try render(AgentMarkView(mark: mark), scheme: scheme)
                    return try color(image, x: image.pixelsWide / 2, y: image.pixelsHigh / 2)
                }
                let done = try center(.done)
                let failed = try center(.failed)
                let blocked = try center(.blocked)
                XCTAssertGreaterThan(done.blueComponent, done.redComponent + 0.3, "done is blue")
                XCTAssertGreaterThan(failed.redComponent, failed.greenComponent + 0.4, "failed is red")
                XCTAssertGreaterThan(failed.redComponent, failed.blueComponent + 0.4, "failed is red")
                XCTAssertGreaterThan(blocked.redComponent, blocked.blueComponent + 0.3, "blocked is orange")
                XCTAssertGreaterThan(blocked.greenComponent, blocked.blueComponent + 0.2, "blocked is orange")
                XCTAssertGreaterThan(blocked.greenComponent, failed.greenComponent + 0.15, "blocked is not the red of failed")
            }
        }
    }

    @MainActor func testAgentColorsChangeTheMarkOnEverySurface() throws {
        var colors = AgentColors()
        colors[.done] = .single(.rgb(red: 0, green: 255, blue: 0))
        let views: [AnyView] = [AnyView(AgentMarkView(mark: .done)), AnyView(AgentMarkSpine(mark: .done).frame(width: 3, height: 20))]
        for view in views {
            let image = try render(view.environment(\.agentColors, colors), scheme: .light)
            let center = try color(image, x: image.pixelsWide / 2, y: image.pixelsHigh / 2)
            XCTAssertGreaterThan(center.greenComponent, center.redComponent + 0.3, "done is the green of the Config")
            XCTAssertGreaterThan(center.greenComponent, center.blueComponent + 0.3, "done is the green of the Config")
        }
    }

    @MainActor func testAColorPairFollowsTheAppearanceOfTheView() throws {
        var colors = AgentColors()
        colors[.done] = .pair(light: .rgb(red: 0, green: 255, blue: 0), dark: .rgb(red: 255, green: 0, blue: 0))
        let view = AgentMarkSpine(mark: .done).frame(width: 3, height: 20).environment(\.agentColors, colors)
        let light = try render(view, scheme: .light)
        let lightCenter = try color(light, x: light.pixelsWide / 2, y: light.pixelsHigh / 2)
        XCTAssertGreaterThan(lightCenter.greenComponent, lightCenter.redComponent + 0.3, "light appearance draws the light color")
        let dark = try render(view, scheme: .dark)
        let darkCenter = try color(dark, x: dark.pixelsWide / 2, y: dark.pixelsHigh / 2)
        XCTAssertGreaterThan(darkCenter.redComponent, darkCenter.greenComponent + 0.3, "dark appearance draws the dark color")
    }

    @MainActor func testThePaletteAgentBadgeTakesTheMarkColorAndAReadDoneAgentHasNone() throws {
        let cases: [(AgentMark?, String?)] = [(.working, nil), (.done, "blue"), (.failed, "red"), (.blocked, "orange"), (nil, nil)]
        for scheme in [ColorScheme.light, .dark] {
            for (mark, expected) in cases {
                let agent = Agent(paneID: "%1", kind: .pi, status: .done, unread: false,
                                  windowID: "@1", sessionID: "$1", sessionName: "test", windowIndex: 1,
                                  windowTitle: "Agent", label: "Agent")
                let item = PaletteItem(ref: .agent(agent), path: "/test", target: "%1", logo: "pi",
                                       status: agent.status, mark: mark.map(RowMark.agent))
                let image = try render(PaletteIcon(source: .item(item, .agent), theme: PaletteTheme(nil)), scheme: scheme, width: 48, height: 48)
                var colored = 0
                for y in 0..<image.pixelsHigh {
                    for x in 0..<image.pixelsWide {
                        let pixel = try color(image, x: x, y: y)
                        let components = [pixel.redComponent, pixel.greenComponent, pixel.blueComponent]
                        guard components.max()! - components.min()! > 0.1 else { continue }
                        colored += 1
                        switch expected {
                        case "blue": XCTAssertGreaterThan(pixel.blueComponent, pixel.redComponent)
                        case "red":
                            XCTAssertGreaterThan(pixel.redComponent, pixel.greenComponent)
                            XCTAssertEqual(pixel.greenComponent, pixel.blueComponent, accuracy: 0.1)
                        case "orange":
                            XCTAssertGreaterThan(pixel.redComponent, pixel.greenComponent)
                            XCTAssertGreaterThan(pixel.greenComponent, pixel.blueComponent)
                        default: break
                        }
                    }
                }
                if expected == nil { XCTAssertEqual(colored, 0, String(describing: mark)) }
                else { XCTAssertGreaterThan(colored, 0, String(describing: mark)) }
            }
        }
    }

    @MainActor func testZoomChangesOnlyThePaneCountAppearance() throws {
        var window = TmuxWindow(id: "@1", sessionID: "$1", sessionName: "app", index: 0, name: "editor",
                                paneTitle: "editor", path: "/app", command: "zsh", isActive: true, paneCount: 3,
                                hasBell: false, sessionActivity: 0, agent: "", storedBrowser: StoredBrowser(), openRequests: [])
        for scheme in [ColorScheme.light, .dark] {
            window.isZoomed = false
            let before = try render(WindowRow(window: window, isSelected: false, tabCount: 12), scheme: scheme, width: 240, height: 30, scale: 2)
            window.isZoomed = true
            let after = try render(WindowRow(window: window, isSelected: false, tabCount: 12), scheme: scheme, width: 240, height: 30, scale: 2)
            var moved = 0
            var changed = 0
            for y in 0..<before.pixelsHigh {
                for x in 0..<before.pixelsWide {
                    if try color(before, x: x, y: y) != color(after, x: x, y: y) {
                        changed += 1
                        // The last 40 points contain the Pane count capsule; the image uses scale 2.
                        if x < before.pixelsWide - 80 { moved += 1 }
                    }
                }
            }
            XCTAssertGreaterThan(changed, 0, "Zoom must change the Pane count appearance")
            XCTAssertEqual(moved, 0, "Zoom moved the Window title or Browser Tab count")
        }
    }

    /// Native production rendering without Ghostty, tmux or a visible window.
    /// An explicit scale renders independently of the machine's attached display.
    @MainActor private func render<V: View>(_ view: V, scheme: ColorScheme,
                                           width: CGFloat = 32, height: CGFloat = 24,
                                           scale: CGFloat? = nil) throws -> NSBitmapImageRep {
        _ = NSApplication.shared
        let content = view.frame(width: width, height: height)
            .background(scheme == .dark ? Color(white: 0.12) : Color.white)
            .environment(\.colorScheme, scheme)
        if let scale {
            let renderer = ImageRenderer(content: content.environment(\.displayScale, scale))
            renderer.scale = scale
            return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
        }
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        defer { window.contentView = nil }
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        withExtendedLifetime(window) {}
        return image
    }

    private func color(_ image: NSBitmapImageRep, x: Int, y: Int) throws -> NSColor {
        try XCTUnwrap(image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
    }

    private func pixels(_ image: NSBitmapImageRep) throws -> [CGFloat] {
        try (0..<image.pixelsHigh).flatMap { y in
            try (0..<image.pixelsWide).map { x in try color(image, x: x, y: y).redComponent }
        }
    }
}
