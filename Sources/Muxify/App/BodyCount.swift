#if DEBUG
/// How many times each counted view's body ran since the last reset. The TestDriver's `counts` command reads it, so
/// a verify check can prove that a scroll of the Bench does not draw every card again.
enum BodyCount {
    private(set) static var counts: [String: Int] = [:]

    static func tick(_ name: String) { counts[name, default: 0] += 1 }

    static func reset() { counts = [:] }
}
#endif
