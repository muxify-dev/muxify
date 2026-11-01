import MuxifyCore

extension Pill {
    /// Why Mark Read on the current target changed nothing. Busy has no Pill: it ends in under a second, and a second
    /// press of ⇧⌘R while the first Read is written would replace that Read's Pill.
    init?(readRefusal refusal: ReadPlan.Refusal, in target: ReadPlan.Place) {
        let value: String
        switch refusal {
        case .busy: return nil
        case .disconnected: value = "Not connected to tmux"
        case .onlyHiddenByZoom(let hidden): value = "Zoomed Pane has nothing Unread · " + Pill.hiddenPanes(hidden, still: false)
        case .nothingToChange:
            let place = switch target {
            case .window: "in this Window"
            case .pane: "in the Zoomed Pane"
            case .topic: "in this Topic"
            case .session: "in this Session"
            case .environment: "in this Environment"
            }
            value = "Nothing is Unread " + place
        }
        self.init(.explanation, title: "Not marked Read", value: value)
    }

    /// Mark Read cleared the Zoomed Pane, and Zoom hides Panes that stay Unread.
    init(readOfZoomedPaneLeaving hidden: Int) {
        self.init(.explanation, title: "Marked Read", value: "Zoomed Pane · " + Pill.hiddenPanes(hidden, still: true))
    }

    /// "1 hidden Pane is Unread", "2 hidden Panes are still Unread".
    private static func hiddenPanes(_ count: Int, still: Bool) -> String {
        let state = still ? "still Unread" : "Unread"
        return count == 1 ? "1 hidden Pane is " + state : "\(count) hidden Panes are " + state
    }
}
