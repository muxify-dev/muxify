import CoreGraphics
import MuxifyCore

// What both versions of a card read (ADR 0074): its sizes, its header that sticks, its motion and its corner, the rows
// of one Session in an open card, and what a click and a drag on its Window row do. The SwiftUI glide of a card that
// opens is `Animation.cardOpens`, in SidebarCard.swift.

/// The rows of one Session in an open card.
struct CardBlock: Identifiable {
    /// The Session ID.
    let id: String
    let items: [TopicsModel.SessionChildren.Item]
}

/// The room between the rows of an open card, and between its Session blocks, where their divider is.
enum CardSpacing {
    static let row: CGFloat = 1
    static let block: CGFloat = 9
}

/// A card's outline. The SwiftUI card and the AppKit card both read it, so the two cannot drift (ADR 0074).
enum CardOutline {
    /// The radius of the card's continuous corners.
    static let cornerRadius: CGFloat = 9
    static let borderWidth: CGFloat = 1
    /// The plain border is the text colour at this opacity.
    static let borderOpacity = 0.08
    /// An open card is raised: the text colour at this opacity fills it, over a shadow.
    static let openFillOpacity = 0.08
    /// The shadow is black at this opacity, before the fill's own opacity thins it.
    static let shadowOpacity = 0.28
    static let shadowRadius: CGFloat = 5
    /// How far the shadow falls below the card.
    static let shadowDrop: CGFloat = 2
}

/// The border of the card that holds the Location's Window, for both versions of the card (ADR 0074): the colours of a
/// Balatro card's edge around the card, which turn once when the Location comes to it.
enum CardSelectionBorder {
    /// The colours around the card, from 3 o'clock clockwise. The last is the first, so the ring closes.
    static let colors: [(red: Double, green: Double, blue: Double)] =
        ([0xfe5f55, 0xfda200, 0xffe066, 0x4bc292, 0x009dff, 0x8e5cff, 0xfe5f55] as [UInt32]).map { hex in
            (Double(hex >> 16 & 0xff) / 255, Double(hex >> 8 & 0xff) / 255, Double(hex & 0xff) / 255)
        }
    static let width: CGFloat = 2
    static let saturation = 1.15
    /// The turn starts this many degrees back, and ends at 0.
    static let turnStart: Double = -150
    static let turnDuration = 0.9
    /// The control points of the turn's timing curve.
    static let turnCurve: (x1: Double, y1: Double, x2: Double, y2: Double) = (0.18, 0.85, 0.25, 1)
}

/// The spine: the bar along a card's left edge that shows its mark, for both versions of the card (ADR 0074).
enum CardSpine {
    static let width: CGFloat = 3
    /// The room above and below the bar.
    static let verticalInset: CGFloat = 8
    static let leading: CGFloat = 4
    static let cornerRadius: CGFloat = 2
}

/// The room around the lines of a card's header, for both versions of the card (ADR 0074).
enum CardHeaderPadding {
    static let leading: CGFloat = 13
    static let trailing: CGFloat = 10
    static let top: CGFloat = 7

    /// An open card's header ends close to its rows.
    static func bottom(isOpen: Bool) -> CGFloat { isOpen ? 3 : 7 }
}

/// The room between the parts of a card's header, for both versions of the card (ADR 0074).
enum CardHeaderSpacing {
    /// Between two lines: the title, the details and the Summary.
    static let lines: CGFloat = 2
    /// Between two parts on the title's first line: the title, the Hint and the marks.
    static let titleLine: CGFloat = 5
    /// More room above the Summary.
    static let summaryTop: CGFloat = 1
}

/// The sizes of the small text and symbols of a card's header, for both versions of the card (ADR 0074). They are the
/// sizes at 12, and grow with the Interface font size.
enum CardHeaderFont {
    static let summary: CGFloat = 11
    /// The lock, the pin, the bell and the Guest mark.
    static let mark: CGFloat = 9
}

/// The marks of a Session card's header, for both versions of the card (ADR 0074): the word of a Guest, and the
/// system symbols of a Locked Session and of a bell.
enum CardHeaderMark {
    static let guest = "Guest"
    static let lock = "lock.fill"
    static let bell = "bell.fill"
}

/// The room around the rows of an open card, for both versions of the card (ADR 0074).
enum CardRowsPadding {
    static let horizontal: CGFloat = 4
    static let top: CGFloat = 3
    static let bottom: CGFloat = 5
}

/// The header of an open card that sticks to the top of its list while the card's rows scroll under it, for both
/// versions of the card (ADR 0074).
enum StuckHeader {
    /// The room that the header leaves under it at the card's end: it stops this far above the card's bottom edge.
    static let gap: CGFloat = 8
    /// The faint fill over the chrome's background while the header sticks.
    static let fillOpacity = 0.08
    /// The divider under the header while it sticks, as high as SwiftUI's `Divider`.
    static let dividerWidth: CGFloat = 1

    /// How far the header moves down from the card's top. `cardTop` is the card's top edge in the list's viewport,
    /// and `inset` is where the header sticks in that viewport: 0 for its top, or the bottom of a block that sticks
    /// there. Zero while the card's top is in view; after that, the distance scrolled past the card's top; and never
    /// further than the card's height less the header's height and the gap under it.
    static func offset(cardTop: CGFloat, cardHeight: CGFloat, headerHeight: CGFloat, inset: CGFloat = 0) -> CGFloat {
        min(max(0, inset - cardTop), max(0, cardHeight - headerHeight - gap))
    }
}

/// How a card opens and closes, for both versions of the card (ADR 0074): ease-out over this many seconds.
enum CardMotion {
    static let openDuration = 0.15
}

/// What a click and a drag on a card's Window row do: a click selects the Window, and a drag moves it,
/// with its Pane rows, before or after another Window of its Session.
struct WindowRowDrag {
    var isEnabled = true
    let select: (TmuxWindow) -> Void
    let move: (TmuxWindow, DropPlacement<String>) -> Void
}

/// The one place a card shows its own action, such as Settle: pinned to the bottom-right corner at the same
/// offsets whether the card is open or closed, so it never moves when the card opens. Its lengths hold the action's
/// text, so they grow with the Interface font size from their design sizes at 12.
enum CardCorner {
    /// The room the action takes at the end of the summary line or the footer line, at 12.
    static let designWidth: CGFloat = 44
    /// The room of Reopen on a card in the Settled group, at 12.
    static let designGroupWidth: CGFloat = 60
    /// The line under the title that a closed card with a corner label and no other line adds for its action, at 12.
    static let designActionLineHeight: CGFloat = 12

    static func width(_ size: InterfaceFontSize) -> CGFloat { size(designWidth) }
    static func groupWidth(_ size: InterfaceFontSize) -> CGFloat { size(designGroupWidth) }
    static func actionLineHeight(_ size: InterfaceFontSize) -> CGFloat { size(designActionLineHeight) }
}
