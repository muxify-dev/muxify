import Foundation

/// How the Git View opens, from the Config's `git_view` section.
public struct GitViewConfig: Equatable {
    public enum Display: String {
        /// Floats over the whole App Window, like `tmux display-popup`.
        case popup
        /// Takes the terminal's place.
        case fullscreen
    }

    public var display = Display.popup
    /// The popup's share of the App Window's width and height, from 0.1 to 1.
    public var width = 0.8
    public var height = 0.8

    public init(display: Display = .popup, width: Double = 0.8, height: Double = 0.8) {
        self.display = display
        self.width = width
        self.height = height
    }

    /// `80%` or `80` as 0.8, from 10% to 100%.
    public static func share(_ text: String) -> Double? {
        var number = text.trimmingCharacters(in: .whitespaces)
        if number.hasSuffix("%") { number.removeLast() }
        guard let percent = Double(number.trimmingCharacters(in: .whitespaces)), percent.isFinite,
              (10...100).contains(percent) else { return nil }
        return percent / 100
    }
}
