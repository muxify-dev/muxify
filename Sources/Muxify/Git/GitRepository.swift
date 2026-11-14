import Foundation
import MuxifyCore

/// What the Git View shows of a repository beside its reads (`GitRead`), writes (`GitWrite`) and network commands
/// (`GitNetwork`), all in MuxifyCore.
enum GitRepository {
    /// lazygit's ages: `45s`, `3m`, `2h`, `5d`, `1w`, `4M`, `2y`.
    static func age(of date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        let units: [(String, Int)] = [("y", 31_536_000), ("M", 2_592_000), ("w", 604_800), ("d", 86_400), ("h", 3_600), ("m", 60)]
        for (unit, length) in units where seconds >= length { return "\(seconds / length)\(unit)" }
        return "\(seconds)s"
    }
}
