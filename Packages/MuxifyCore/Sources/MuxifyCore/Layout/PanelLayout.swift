/// What a Window shows of its Terminal and Browser. The toggles say which
/// sides are shown and never hide both. Maximize shows one side alone, with
/// the Sidebar hidden, without changing the toggles; on Restore, the toggles
/// show again.
public struct PanelLayout: Hashable {
    public enum Side: Hashable {
        case terminal, browser

        public var other: Side { self == .terminal ? .browser : .terminal }
    }

    /// The sides the toggles show.
    public enum Shown: Hashable {
        case terminal, both, browser

        init(alone side: Side) {
            self = side == .terminal ? .terminal : .browser
        }

        func includes(_ side: Side) -> Bool {
            self == .both || self == Shown(alone: side)
        }
    }

    public private(set) var shown: Shown
    /// The side shown alone, or nil when the Window is not Maximized.
    public private(set) var maximized: Side?

    public init(shown: Shown = .terminal, maximized: Side? = nil) {
        self.shown = shown
        self.maximized = maximized
    }

    /// Whether `side` is on screen: the toggles, filtered by Maximize.
    public func shows(_ side: Side) -> Bool {
        if let maximized { return side == maximized }
        return shown.includes(side)
    }

    public var hidesSidebar: Bool { maximized != nil }

    /// Whether the toggles show `side`, also while Maximize hides it.
    public func isToggledOn(_ side: Side) -> Bool {
        shown.includes(side)
    }

    /// The only side on screen can't be hidden.
    public func canToggle(_ side: Side) -> Bool {
        !shows(side) || shows(side.other)
    }

    /// Shows or hides `side`. While Maximized, what is on screen becomes the
    /// toggles first, so the toggle changes what the user sees.
    public mutating func toggle(_ side: Side) {
        guard canToggle(side) else { return }
        commitMaximize()
        shown = shown.includes(side) ? Shown(alone: side.other) : .both
    }

    public mutating func show(_ side: Side) {
        if !shows(side) { toggle(side) }
    }

    /// Puts `side` on screen so it can take Focus: restores when the other
    /// side is Maximized, then shows `side` if the toggles hide it.
    public mutating func reveal(_ side: Side) {
        if maximized == side.other { maximized = nil }
        show(side)
    }

    /// Maximize of `side` changes something: it hides the Sidebar or the
    /// other side, or it moves Maximize or restores.
    public func canMaximize(_ side: Side, sidebarShown: Bool) -> Bool {
        maximized != nil || sidebarShown || !shows(side) || shows(side.other)
    }

    /// Maximizes `side`, or restores when `side` is Maximized already.
    public mutating func toggleMaximize(_ side: Side, sidebarShown: Bool) {
        guard canMaximize(side, sidebarShown: sidebarShown) else { return }
        maximized = maximized == side ? nil : side
    }

    public mutating func restore() {
        maximized = nil
    }

    /// Restores and keeps what Maximize shows: the Maximized side, alone.
    public mutating func commitMaximize() {
        guard let maximized else { return }
        shown = Shown(alone: maximized)
        self.maximized = nil
    }

    /// The Browser has no Tab left, so only the Terminal can show.
    public mutating func closeBrowser() {
        shown = .terminal
        if maximized == .browser { maximized = nil }
    }
}
