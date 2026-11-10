import CoreGraphics
import Foundation
import MuxifyCore

/// The sizes of a row's Agent mark, for both versions of the Sessions list (ADR 0074). A length is its size at 12, and
/// grows with the Interface font size, as the mark sits beside a row's text.
enum AgentMarkMetrics {
    /// The side of a Notification's dot.
    static let dotSize: CGFloat = 7
}

/// The Working mark of a row, for both versions of the Sessions list (ADR 0074): eight separate square pixels around a
/// three-by-three grid, with no outline between them. A bright head and dimmer pixels behind it step clockwise, eight
/// steps in a period, on the clock that every Working mark shares: the time since the reference date.
enum WorkingGlyph {
    static let period: TimeInterval = 1.2
    /// A pixel at 12.
    static let blockSize: CGFloat = 3
    /// The glyph's footprint at 12.
    static let footprint: CGFloat = 10

    /// The pixels around the grid, clockwise from its top left corner.
    static let cells: [CGPoint] = [
        CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 2, y: 0), CGPoint(x: 2, y: 1),
        CGPoint(x: 2, y: 2), CGPoint(x: 1, y: 2), CGPoint(x: 0, y: 2), CGPoint(x: 0, y: 1),
    ]

    /// The steps in a period: one for each pixel.
    static var steps: Int { cells.count }

    /// The share of the period that has run at `date`, from 0 up to 1.
    static func phase(at date: Date) -> Double {
        let cycles = date.timeIntervalSinceReferenceDate / period
        return cycles - floor(cycles)
    }

    /// The pixel that is the head at `phase`.
    static func head(at phase: Double) -> Int {
        // Wall-clock dates lose a little precision at exact tick boundaries.
        // This tolerance prevents a repeated pixel followed by a skipped one.
        let position = (phase - floor(phase)) * Double(cells.count)
        return Int(floor(position + 0.00001)) % cells.count
    }

    /// The opacity of a pixel that is `behind` steps after the head.
    static func opacity(behind: Int) -> Double {
        switch behind {
        case 0: 0.85
        case 1: 0.55
        case 2: 0.32
        default: 0.16
        }
    }

    /// The eight pixels of a glyph in a footprint of `size`, from its top left corner, each with its opacity at
    /// `phase`, on a display with `displayScale` pixels in a point. The footprint's corner must stand on a device pixel.
    static func pixels(in size: CGSize, phase: Double, fontSize: InterfaceFontSize,
                       displayScale: CGFloat) -> [(frame: CGRect, opacity: Double)] {
        let head = head(at: phase)
        // Reserve a physical pixel for each gap. At 12 and 1×, use 2 pt
        // blocks so all eight stay separate within the same 10 pt
        // footprint; at 2×, retain the 3 pt blocks and half-point gaps.
        // At other sizes the footprint and the 3 pt cap scale by the factor.
        let gap = 1 / displayScale
        let availablePixels = min(size.width, size.height) * displayScale - 2
        let block = min(fontSize(blockSize), floor(availablePixels / 3) / displayScale)
        let pitch = block + gap
        let extent = 2 * pitch + block
        // Align the entire grid to physical pixels to avoid antialiasing
        // that would blur adjacent blocks together.
        let origin = CGPoint(x: ((size.width - extent) / 2 * displayScale).rounded() / displayScale,
                             y: ((size.height - extent) / 2 * displayScale).rounded() / displayScale)
        return cells.enumerated().map { index, cell in
            (CGRect(x: origin.x + cell.x * pitch, y: origin.y + cell.y * pitch, width: block, height: block),
             opacity(behind: (head - index + cells.count) % cells.count))
        }
    }
}
