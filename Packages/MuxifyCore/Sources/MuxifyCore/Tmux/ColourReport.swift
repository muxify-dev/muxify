import Foundation

/// An sRGB colour with 8 bits per channel, as Ghostty's config holds it.
public struct TerminalColour: Hashable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// The form of an OSC 10 or 11 reply: each channel written twice, `rgb:fbfb/f1f1/c7c7`.
    var oscReply: String {
        "rgb:" + [red, green, blue].map { String(format: "%02x%02x", $0, $0) }.joined(separator: "/")
    }
}

/// The colours of Muxify's Terminal, which it reports to the Panes that it shows (ADR 0095).
public struct TerminalColours: Hashable, Sendable {
    public let background: TerminalColour
    public let foreground: TerminalColour

    public init(background: TerminalColour, foreground: TerminalColour) {
        self.background = background
        self.foreground = foreground
    }
}

/// A Colour Report (ADR 0095): what Muxify tells tmux about its Terminal's colours, so that a program in a Pane that
/// asks for the background (OSC 11) or the foreground (OSC 10) gets the answer of the screen in use. tmux answers a
/// Pane from its report first, and keeps the last report that any control Client wrote.
enum ColourReport {
    /// The control-mode command lines that report `colours` for each Pane: OSC 11 first, then OSC 10. tmux reads
    /// `\033` and `\\` in a double-quoted argument as ESC and a backslash.
    static func commands(panes: [String], colours: TerminalColours) -> [String] {
        panes.filter(isPaneID).flatMap { pane in
            [(11, colours.background), (10, colours.foreground)].map { code, colour in
                #"refresh-client -r "\#(pane):\033]\#(code);\#(colour.oscReply)\033\\""#
            }
        }
    }

    static func isPaneID(_ value: String) -> Bool {
        value.count > 1 && value.first == "%" && value.dropFirst().allSatisfy(\.isASCIIDigit)
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
