import Foundation
import MuxifyCore

extension SessionChoice {
    /// The search fields that let typing the folder name find a row whose title is an alias.
    var nameFields: [SearchField] { displayName == name ? [] : [.hidden(name)] }
}
