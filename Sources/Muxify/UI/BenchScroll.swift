import CoreGraphics
import Foundation
import MuxifyCore

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
    /// The Interface font size, which the "more above" pill and the least Bench area grow with.
    var fontSize = InterfaceFontSize()

    /// The band at the top of the Bench area that the "more above" pill lies in while cards are above the area.
    var indicatorHeight: CGFloat { EdgePill.height(fontSize) }

    /// The least Bench area at 12. It holds Benched cards, so it grows with the Interface font size.
    static let designLeastAreaHeight: CGFloat = 96
    /// The Bench area is never shorter than this while the block sticks.
    var leastAreaHeight: CGFloat { fontSize(Self.designLeastAreaHeight) }

    /// How far the block scrolls with the content before it sticks: zero unless the block is tall.
    var slack: CGFloat { max(0, inset + topHeight - (viewportHeight - leastAreaHeight)) }
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

    /// The scroll offset that reveals a Benched card whose top is `top` below the top of the list's first item: the
    /// card stands directly under the line, or under the "more above" pill for a card with Benched cards before it,
    /// because the pill shows while those cards are above the area.
    func revealOffset(cardTop top: CGFloat, hasCardsAbove: Bool) -> CGFloat {
        top + inset - areaTop - spacing - (hasCardsAbove ? indicatorHeight : 0)
    }

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
    /// Benched cards come before it in the list, so a shown Bench has cards above the area, under the "more above"
    /// pill.
    var hasCardsAbove: Bool

    /// How far to scroll so that the card is back where it stood at the layout before, `before`: the distance the
    /// cards that just showed above it pushed it down, less the pill's band when those cards put the pill over the
    /// card's top. Nil unless the Bench showed between the two layouts, so a scroll of a shown Bench or a hide does not
    /// scroll again.
    func openingScroll(after before: BenchedLocationPlace?, indicatorHeight: CGFloat) -> CGFloat? {
        guard let before, !before.isBenchShown, isBenchShown else { return nil }
        return max(0, top - before.top - (hasCardsAbove ? indicatorHeight : 0))
    }
}

/// Where a card stands against the part of a scroll view the user sees: from `visibleTop`, which is the bottom of a
/// block that sticks over it, down to the viewport's bottom. The "more above" and "more below" pills count from it, and a
/// Jump To scrolls only to a card that is out of view.
struct EdgePlace: Equatable {
    /// The card's top is above the visible top, also when the rest of it shows.
    var isAbove: Bool
    /// The card ends below the visible bottom, also when the rest of it shows.
    var isBelow: Bool
    /// No point of the card shows.
    var isOutOfView: Bool
    /// The card's top is in or above the band of the "more above" pill, so the pill covers it when it shows. The pill
    /// shows because a card `isAbove`; it then counts the cards `isUnderIndicator`, which include that card.
    var isUnderIndicator: Bool
    /// The card's bottom is in or below the band of the "more below" pill, so the pill covers it when it shows. The
    /// pill shows because a card `isBelow`; it then counts the cards `isOverBottomIndicator`, which include that card.
    var isOverBottomIndicator: Bool

    /// The place of a card from `top` to `bottom`, in the viewport's points. One point of slack at each edge, so a
    /// card that ends on an edge is in view.
    init(top: CGFloat, bottom: CGFloat, visibleTop: CGFloat, visibleBottom: CGFloat, indicatorHeight: CGFloat) {
        isAbove = top < visibleTop - 1
        isBelow = bottom > visibleBottom + 1
        isOutOfView = bottom <= visibleTop + 1 || top >= visibleBottom - 1
        isUnderIndicator = top < visibleTop + indicatorHeight - 1
        isOverBottomIndicator = bottom > visibleBottom - indicatorHeight + 1
    }

    init(isAbove: Bool = false, isBelow: Bool = false, isOutOfView: Bool = false, isUnderIndicator: Bool = false,
         isOverBottomIndicator: Bool = false) {
        self.isAbove = isAbove
        self.isBelow = isBelow
        self.isOutOfView = isOutOfView
        self.isUnderIndicator = isUnderIndicator
        self.isOverBottomIndicator = isOverBottomIndicator
    }
}
