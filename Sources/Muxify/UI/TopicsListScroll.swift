import CoreGraphics
import Foundation
import MuxifyCore
import Observation
import QuartzCore

/// What the Topics list learns from each frame it scrolls: how far, and where each card stands against its edges. An
/// observable object, not state of the list's view, so only the views that read a value draw again when it changes:
/// the block that sticks, the edge pills and the drag. The Benched cards read none of it, so a scroll of the Bench
/// does not draw them again.
///
/// Its static functions are the arithmetic of the "N more above" and "N more below" pills and of the scroll to a hidden
/// card, which both versions of the list call (docs/adr/0075-muxify-leaves-swiftui-entirely-one-area-at-a-time.md).
@MainActor @Observable final class TopicsListScroll {
    /// How far the content has scrolled up in the viewport.
    var offset: CGFloat = 0
    /// Where each card stands against the visible part of the Topics list: the "N more above" and "N more below" pills
    /// count from it, and a Jump To scrolls to a Benched card that is out of view.
    var places: [TopicGroupID: EdgePlace] = [:]
    /// Each card's top below the top of the list's first item, where a reveal scrolls to. It changes with the layout,
    /// not with a scroll.
    var tops: [TopicGroupID: CGFloat] = [:]
    /// How far the end of the Topics list is below its bottom edge, up to the height of the "N more below" pill. With
    /// a Bench line, the end is the last Benched card's bottom, not the empty space after it.
    var listEnd: CGFloat = 0
    var benchEnd: CGFloat = 0

    /// The glide to a card that a pill or a Jump To reveals takes this many seconds, along `revealTiming`.
    nonisolated static let revealDuration: TimeInterval = 0.2
    nonisolated static let revealTiming = CAMediaTimingFunctionName.easeOut

    /// The cards that the "N more below" pill counts, in list order: none unless a card ends below the bottom edge, and
    /// then also each card whose bottom is in the pill's band, which the pill covers. So the pill cannot show and go in
    /// turns for a card in its band alone. A press on it reveals the first. `cards` are the list's cards in its order.
    nonisolated static func moreBelow(_ cards: [TopicGroupID], places: [TopicGroupID: EdgePlace]) -> [TopicGroupID] {
        guard cards.contains(where: { places[$0]?.isBelow == true }) else { return [] }
        return cards.filter { places[$0]?.isOverBottomIndicator == true }
    }

    /// The Benched cards that the "N more above" pill counts, in list order: none unless a Benched card's top is above
    /// the top edge of the Bench area, and then also each Benched card whose top is in the pill's band. A press on it
    /// reveals the last. `bench` are the Benched cards in list order.
    nonisolated static func moreAbove(_ bench: [TopicGroupID], places: [TopicGroupID: EdgePlace]) -> [TopicGroupID] {
        guard bench.contains(where: { places[$0]?.isAbove == true }) else { return [] }
        return bench.filter { places[$0]?.isUnderIndicator == true }
    }

    /// The scroll offset that reveals the card whose top is `top` below the top of the list's first item: a Benched
    /// card stands directly under the line, or under the "more above" pill when it `hasCardsAbove`, which are then above
    /// the area (`BenchGeometry.revealOffset`); any other card stands at the top of the list.
    nonisolated static func revealOffset(cardTop top: CGFloat, isBenched: Bool, hasCardsAbove: Bool,
                                         geometry: BenchGeometry) -> CGFloat {
        isBenched ? geometry.revealOffset(cardTop: top, hasCardsAbove: hasCardsAbove) : top + geometry.inset
    }

    /// Whether the list scrolls to the card when the Location moves to it: a Benched card that was out of view.
    nonisolated static func revealsLocation(_ card: TopicGroupID, isBenched: Bool, places: [TopicGroupID: EdgePlace]) -> Bool {
        isBenched && places[card]?.isOutOfView == true
    }
}
