import MuxifyCore
import SwiftUI

/// The Working mark of a row: square pixels light up one step at a time, like a terminal activity glyph.
/// Every moving glyph shares a clock; a still one has no animation timer. `WorkingGlyph` holds its arithmetic.
struct TerminalActivityIndicator: View {
    let moves: Bool
    let color: Color

    var body: some View {
        if !moves {
            TerminalActivityGlyph(phase: 0, color: color)
        } else {
            TimelineView(.periodic(from: Date(timeIntervalSinceReferenceDate: 0),
                                   by: WorkingGlyph.period / Double(WorkingGlyph.steps))) { context in
                TerminalActivityGlyph(phase: WorkingGlyph.phase(at: context.date), color: color)
            }
        }
    }
}

/// Eight separate square pixels on a three-column, three-row perimeter. No outline
/// connects them: a bright head and two dimmer trailing pixels step clockwise.
struct TerminalActivityGlyph: View {
    let phase: Double
    let color: Color

    @Environment(\.displayScale) private var displayScale
    /// The glyph sits beside a row's text, so its footprint and blocks grow with the Interface font size.
    @Environment(\.interfaceFontSize) private var fontSize

    var body: some View {
        Canvas { context, size in
            for pixel in WorkingGlyph.pixels(in: size, phase: phase, fontSize: fontSize, displayScale: displayScale) {
                context.fill(Path(pixel.frame), with: .color(color.opacity(pixel.opacity)))
            }
        }
        .frame(width: fontSize(WorkingGlyph.footprint), height: fontSize(WorkingGlyph.footprint))
    }
}
