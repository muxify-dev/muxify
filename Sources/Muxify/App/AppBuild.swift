import Foundation

/// The app's build line, `muxify <short-sha> <commit-unix-time>`, which a build phase (`scripts/stamp-build-line.sh`)
/// stamps into every app's Info.plist as `MuxifyBuild`, Debug included. The Mac's `hello` carries it. It is never
/// compared: it goes to Diagnostics (ADR 0084).
enum AppBuild {
    static let infoKey = "MuxifyBuild"

    /// The line that `bundle` carries, or `muxify dev 0` for one with no stamp.
    static func line(in bundle: Bundle) -> String {
        (bundle.object(forInfoDictionaryKey: infoKey) as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "muxify dev 0"
    }

    static let line = line(in: .main)
}
