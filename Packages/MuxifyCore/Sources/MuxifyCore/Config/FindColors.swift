/// `ui.find_colors`: the highlight of Find in Pane's matches and of its current match, the same in every theme.
public struct FindColors: Equatable, Sendable {
    public var match = MarkColor.Single.rgb(red: 0xFF, green: 0xD5, blue: 0x4F)
    public var current = MarkColor.Single.rgb(red: 0xFF, green: 0x96, blue: 0x00)

    public init() {}
}
