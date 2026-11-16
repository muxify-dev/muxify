import MuxifyCore
import SwiftUI

extension Highlighted {
    /// The marked characters in bold and the accent color.
    var attributed: AttributedString {
        var attributed = AttributedString(text)
        let count = text.count
        for mark in marks where mark < count {
            let start = attributed.index(attributed.startIndex, offsetByCharacters: mark)
            let end = attributed.index(start, offsetByCharacters: 1)
            attributed[start..<end].inlinePresentationIntent = .stronglyEmphasized
            attributed[start..<end].foregroundColor = .accentColor
        }
        return attributed
    }
}
