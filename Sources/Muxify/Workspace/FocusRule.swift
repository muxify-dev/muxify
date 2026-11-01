import MuxifyCore

/// A view of the App Window that keeps Focus between the things that take it for a while, such as a Command
/// Palette or a sheet: the Terminal side (the Terminal or its Find in Pane field), the Browser, or the Git View.
enum FocusHolder: Equatable {
    case terminal, browser, gitView
}

/// The App Window as the Focus rule (ADR 0065) sees it a turn after its first responder changed. While nothing
/// takes input on its own, one view of the App Window has Focus: when the first responder is the window itself,
/// Focus goes back to the holder that had it last, or to the one on screen.
struct FocusGap: Equatable {
    /// The first responder is a view, so Focus is somewhere already.
    var firstResponderIsView: Bool
    var paletteIsOpen: Bool
    /// A sheet or an alert is attached to the App Window, or a modal window runs.
    var sheetIsOpen: Bool
    /// An Empty Topic page shows: it takes no input, on purpose.
    var showsEmptyPage: Bool
    var gitViewIsOpen: Bool
    var layout: PanelLayout
    var lastFocus: FocusHolder?

    /// The holder that takes Focus, or nil when a view has it, when something else takes input, or when the Empty
    /// Topic page shows. An open Git View takes it over its sides, as going to a Window does.
    var focusToRestore: FocusHolder? {
        guard !firstResponderIsView, !paletteIsOpen, !sheetIsOpen, !showsEmptyPage else { return nil }
        if gitViewIsOpen { return .gitView }
        let side: PanelLayout.Side = lastFocus == .browser ? .browser : .terminal
        let shown = layout.shows(side) ? side : side.other
        return shown == .terminal ? .terminal : .browser
    }
}
