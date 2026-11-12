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

/// The divider over each Session block of an open card after the first, for both versions of the card: a line as high
/// as SwiftUI's `Divider`, inset from the sides of the rows, in the room between two blocks.
enum CardBlockDivider {
    /// The room between the divider's ends and the sides of the rows.
    static let inset: CGFloat = 6
    /// How far above the block's top the divider's top stands.
    static let rise: CGFloat = 5
    /// The dividers hide while a drag moves a block, and show again after it, with ease-out over this.
    static let fadeDuration = 0.15
}

/// A Session block of an open Topic card, which a drag on its Session line lifts, for both versions of the card.
enum CardBlockLift {
    /// The radius of the plate that a pressed or lifted block stands on, and of the placeholder where it would land.
    static let cornerRadius: CGFloat = 7
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
    /// Between two parts of the details line, such as "Dormant" and the bell.
    static let details: CGFloat = 5
}

/// The sizes of the small text and symbols of a card's header, for both versions of the card (ADR 0074). They are the
/// sizes at 12, and grow with the Interface font size.
enum CardHeaderFont {
    static let summary: CGFloat = 11
    /// The lock, the pin, the bell and the Guest mark.
    static let mark: CGFloat = 9
    /// The words of the details line, such as "Dormant".
    static let detail: CGFloat = 10
}

/// The marks of a card's header, for both versions of the card (ADR 0074): the word of a Guest, and the system symbols
/// of a Pinned Topic, a Locked Session and a bell.
enum CardHeaderMark {
    static let guest = "Guest"
    static let pin = "pin.fill"
    static let lock = "lock.fill"
    static let bell = "bell.fill"
}

/// The Topic Note on a card, for both versions of the card: a pencil and the whole text, on a line of its own, in a
/// yellow that reads on the light and the dark Sidebar. A closed card shows it softer.
enum CardNote {
    static let symbol = "pencil"
    /// The size of the pencil and the text at 12, which grows with the Interface font size.
    static let fontSize: CGFloat = 11.5
    /// The room between the pencil and the text.
    static let spacing: CGFloat = 4
    /// More room above the line.
    static let top: CGFloat = 1
    static let closedOpacity = 0.6
    /// The yellow on a light Sidebar, and on a dark one.
    static let light: (red: Double, green: Double, blue: Double) = (0.698, 0.42, 0)
    static let dark: (red: Double, green: Double, blue: Double) = (1, 0.765, 0.361)
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
    /// The line that an open card's rows end with for the action, when no "N more…" takes it, at 12.
    static let designFooterHeight: CGFloat = 16
    /// The action's text size, at 12.
    static let fontSize: CGFloat = 11
    /// The word in the card's top-right corner, such as how long ago a Topic was Settled: its text size at 12, and its
    /// room to the card's right edge.
    static let labelFontSize: CGFloat = 11
    static let labelTrailing: CGFloat = 10
    /// The room between the action and the card's right and bottom edges.
    static let trailing: CGFloat = 10
    static let bottom: CGFloat = 6

    static func width(_ size: InterfaceFontSize) -> CGFloat { size(designWidth) }
    static func groupWidth(_ size: InterfaceFontSize) -> CGFloat { size(designGroupWidth) }
    static func actionLineHeight(_ size: InterfaceFontSize) -> CGFloat { size(designActionLineHeight) }
    static func footerHeight(_ size: InterfaceFontSize) -> CGFloat { size(designFooterHeight) }
}

/// The word a card shows in its top-right corner, on the title's first line, above its action: how long ago a Topic in
/// the Settled group was Settled, such as "Yesterday".
struct CardCornerLabel: Equatable {
    let text: String
    let accessibilityID: String
}
