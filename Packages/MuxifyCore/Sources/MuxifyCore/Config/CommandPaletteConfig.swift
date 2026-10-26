/// One kind of thing a Command Palette searches (CONTEXT.md).
public enum PaletteSource: String, CaseIterable {
    /// Open Topics, then Snoozed and Settled ones. Only a Local App Window with Topics on has them.
    case topics
    /// Every running Session, in either Sidebar mode, and the SessionPaths whose launch name has no running Session.
    case sessions
    case windows
    case agents
    case commands

    public var title: String { rawValue.capitalized }
}

/// How a Command Palette lays out the rows of its Sources.
public enum PaletteOrder: String, CaseIterable {
    /// Each Source under its own header, in Source order, ranked on its own.
    case grouped
    /// One list without headers. A query ranks the rows of every Source together; an empty query keeps Source order.
    case ranked
}

public struct CommandPaletteConfig: Equatable, Identifiable {
    /// Unique among the Config's palettes.
    public let name: String
    public var triggers: [KeyTrigger]
    /// The Sources that are on when it opens, in Config order, without
    /// repeats; never empty. The other Sources can be switched on.
    public let sources: [PaletteSource]
    public let order: PaletteOrder
    /// The kinds of rows it lists.
    public let rules: PickRules

    public init(name: String, triggers: [KeyTrigger], sources: [PaletteSource], order: PaletteOrder = .grouped,
                rules: PickRules = .standard) {
        self.name = name
        self.triggers = triggers
        self.sources = sources
        self.order = order
        self.rules = rules
    }

    public var id: String { name }

    /// Every Source, the palette's own first, then the others.
    public var allSources: [PaletteSource] { sources + PaletteSource.allCases.filter { !sources.contains($0) } }

    public var placeholder: String { name.hasSuffix("…") ? name : "Search \(name)" }

    public static let goTo = CommandPaletteConfig(name: "Go to…", triggers: [try! KeyTrigger("cmd+p")],
                                                  sources: [.topics, .sessions])

    public static let commands = CommandPaletteConfig(name: "Commands", triggers: [try! KeyTrigger("cmd+shift+p")],
                                                       sources: [.commands])

    public static let defaults: [CommandPaletteConfig] = [.commands, .goTo]
}
