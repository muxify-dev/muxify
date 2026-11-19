import Foundation
import Observation

/// What the Open Place page keeps while it is the Location: the query of its search field, its selected row, and its
/// field's Focus. The App Window's key monitor gives the page its keys while `fieldHasFocus`, so ↑ ↓ ↩ and ⎋ act
/// on the list and every other keybind still acts as on any Location.
@MainActor @Observable
final class OpenPlacePage {
    var query = ""
    /// The Topic of the selected row. A row the query hides gives the selection to the first row.
    var selectedID: String?
    /// The page moves Focus to its field once it shows. The store asks for it (`focusOpenPlaceField`).
    var fieldFocusRequested = false
    var fieldHasFocus = false

    /// A new arrival on the page starts with no query, at the first row.
    func arrive() {
        query = ""
        selectedID = nil
    }
}
