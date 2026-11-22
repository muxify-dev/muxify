import MuxifyCore

extension TopicSelection {
    /// The Location of the selected Window: what a BoardModel is given while that Window is shown.
    var windowLocation: Location? { windowID.flatMap(WindowID.init(rawValue:)).map(Location.window) }
}
