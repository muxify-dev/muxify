import CoreGraphics
import Foundation

/// The Topics list's one scroll offset, split into what the block at its top does and what the Bench under it does.
/// The block (the Pinned and In Play cards, the Bench line and the opened No Topic Session) sticks to the top of the
/// viewport, and the Benched cards scroll under it. A block taller than the viewport leaves room for first scrolls with
/// the content until `leastAreaHeight` of the Bench shows under it, and sticks there.
struct BenchGeometry: Equatable {
    /// The height of the block.
    var topHeight: CGFloat
    var viewportHeight: CGFloat
    /// The room between two items of the list's stack.
    var spacing: CGFloat = 6
    /// The content's padding above the block and below the Bench.
    var inset: CGFloat = 4

    /// The Bench area is never shorter than this while the block sticks.
    static let leastAreaHeight: CGFloat = 96

    /// How far the block scrolls with the content before it sticks: zero unless the block is tall.
    var slack: CGFloat { max(0, inset + topHeight - (viewportHeight - Self.leastAreaHeight)) }
    /// Where the Bench area starts in the viewport once the block sticks: the block's bottom edge.
    var areaTop: CGFloat { inset + topHeight - slack }
    var areaHeight: CGFloat { max(0, viewportHeight - areaTop) }

    /// How far the block moves down at the scroll offset `offset` to stay in place, which is also how far the Bench
    /// has scrolled under the line.
    func stick(at offset: CGFloat) -> CGFloat { max(0, offset - slack) }

    /// The empty space after the last Benched card, so that at the end of the scroll the last card stands right under
    /// the line. The content's height then does not change when the block or the last card grows: the tail gives
    /// back what they take, and a hidden Bench with one card does not scroll at all.
    func tail(afterCardOfHeight last: CGFloat) -> CGFloat { max(0, areaHeight - spacing - last - spacing - inset) }

    /// The part of the viewport whose edges scroll the list while a lifted card's pointer rests there: from the
    /// block's bottom to the viewport's bottom, or from the viewport's top while the block still scrolls.
    func autoScrollRange(at offset: CGFloat) -> ClosedRange<CGFloat> {
        (offset >= slack ? min(areaTop, viewportHeight) : 0)...viewportHeight
    }
}

/// How fast a lifted card's pointer at an edge of the scroll area scrolls it. A pointer in the band at the bottom
/// scrolls down, in the band at the top up, faster deeper into the band.
enum EdgeAutoScroll {
    static let band: CGFloat = 28
    /// Points a tick at the edge itself, or past it.
    static let speed: CGFloat = 12

    /// The points to scroll each tick, up (negative) or down: zero with no pointer, outside the bands, at offset zero
    /// going up and at `end`, the last offset, going down. `area` is in the viewport's points, as `pointer` is.
    static func step(pointer: CGFloat?, in area: ClosedRange<CGFloat>, offset: CGFloat, end: CGFloat) -> CGFloat {
        guard let pointer else { return 0 }
        let isOverBlock = area.lowerBound > 0 && pointer < area.lowerBound
        if pointer > area.upperBound - band {
            return offset < end ? wholePoints(speed * min(1, (pointer - (area.upperBound - band)) / band)) : 0
        }
        if pointer < area.lowerBound + band, !isOverBlock {
            return offset > 0 ? -wholePoints(speed * min(1, (area.lowerBound + band - pointer) / band)) : 0
        }
        return 0
    }

    /// A step of whole points keeps the block, which moves by the scroll offset, on whole pixels.
    private static func wholePoints(_ step: CGFloat) -> CGFloat { max(1, step.rounded()) }

    /// Holds a step back until the pointer has rested in a band for `delay`, so a card that only passes an edge on
    /// its way does not scroll the list.
    struct Dwell {
        static let delay: TimeInterval = 0.2
        private var since: TimeInterval?

        /// `step` once it has been other than zero for `delay` up to `now`, zero before.
        mutating func pass(_ step: CGFloat, at now: TimeInterval) -> CGFloat {
            guard step != 0 else {
                since = nil
                return 0
            }
            let since = self.since ?? now
            self.since = since
            return now - since >= Self.delay ? step : 0
        }
    }
}

/// Where the Location's Benched card stands in the Topics list's viewport, at one layout.
struct BenchedLocationPlace: Equatable {
    /// The card's top, in the viewport's points.
    var top: CGFloat
    var isBenchShown: Bool

    /// How far to scroll so that the card is back where it stood at the layout before, `before`: the distance the
    /// cards that just showed above it pushed it down. Nil unless the Bench showed between the two layouts, so a scroll
    /// of a shown Bench or a hide does not scroll again.
    func openingScroll(after before: BenchedLocationPlace?) -> CGFloat? {
        guard let before, !before.isBenchShown, isBenchShown else { return nil }
        return top - before.top
    }
}
