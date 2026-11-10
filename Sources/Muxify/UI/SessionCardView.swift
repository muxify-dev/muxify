import AppKit
import MuxifyCore

/// A Session card of the AppKit Sessions list (ADR 0074). It is bare: the card's outline and, in its header, the
/// Session's title. It gives the accessibility rows of the SwiftUI card: `card-session-<id>` for the card and
/// `session-<id>` for its header.
final class SessionCardView: NSView {
    let sessionID: String
    private let header: SessionCardHeaderView

    init(sessionID: String) {
        self.sessionID = sessionID
        header = SessionCardHeaderView(identifier: "session-" + sessionID)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = CardOutline.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = CardOutline.borderWidth
        addSubview(header)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("card-session-" + sessionID)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    func show(title: String, environment: SessionsListEnvironment) {
        header.show(title: title, font: environment.typography.nsFont(for: .session))
        colorOutline()
        layOut()
    }

    /// The card's height at `width`.
    func height(width: CGFloat) -> CGFloat { header.height(width: width) }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layOut()
    }

    private func layOut() {
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: header.height(width: bounds.width))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        colorOutline()
    }

    /// The plain border. A layer keeps the colour it got, so it gets the text colour again for each appearance.
    private func colorOutline() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let text = NSColor.labelColor
            layer?.borderColor = text.withAlphaComponent(text.alphaComponent * CardOutline.borderOpacity).cgColor
        }
    }
}

/// The header of a Session card: its title on one line. Its accessibility row has the title as its label.
private final class SessionCardHeaderView: NSView {
    private let title = SidebarLabel()

    init(identifier: String) {
        super.init(frame: .zero)
        addSubview(title)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier(identifier)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    func show(title text: String, font: NSFont) {
        title.text = text
        title.font = font
        setAccessibilityLabel(text)
        layOut()
    }

    func height(width: CGFloat) -> CGFloat {
        CardHeaderPadding.top + title.lineHeight + CardHeaderPadding.bottom(isOpen: false)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layOut()
    }

    private func layOut() {
        let width = max(0, bounds.width - CardHeaderPadding.leading - CardHeaderPadding.trailing)
        title.frame = NSRect(x: CardHeaderPadding.leading, y: CardHeaderPadding.top, width: width, height: title.lineHeight)
    }
}
