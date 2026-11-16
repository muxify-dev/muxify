import Foundation
import MuxifyCore

/// The visit times that an older Muxify kept in one UserDefaults key, before the state database had them.
enum LegacyVisits {
    static let defaultsKey = "visits"

    /// Moves them into the table as this machine's visits, where a key keeps its newer time, and removes the
    /// UserDefaults key, so this runs one time. A key the table cannot take stays for the next launch.
    static func move(from defaults: UserDefaults, to store: VisitStore) {
        guard let stored = defaults.dictionary(forKey: defaultsKey) else { return }
        var times: [VisitKey: Date] = [:]
        for (key, value) in stored {
            guard let key = VisitKey(stored: key), let seconds = value as? Double else { continue }
            times[key] = Date(timeIntervalSince1970: seconds)
        }
        guard (try? store.add(times)) != nil else { return }
        defaults.removeObject(forKey: defaultsKey)
    }
}
