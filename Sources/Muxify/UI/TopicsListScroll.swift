import CoreGraphics
import MuxifyCore
import Observation

/// What the Topics list learns from each frame it scrolls: how far, and where each card stands against its edges. An
/// observable object, not state of the list's view, so only the views that read a value draw again when it changes:
/// the block that sticks, the edge pills and the drag. The Benched cards read none of it, so a scroll of the Bench
/// does not draw them again.
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
}
