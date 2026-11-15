import Foundation

/// The app's build line, `muxify <short-sha> <commit-unix-time>`, which a build phase (`scripts/stamp-build-line.sh`)
/// stamps into every app's Info.plist as `MuxifyBuild`, Debug included. The Mac's `hello` carries it. It is never
/// compared: it goes to Diagnostics (ADR 0086).
enum AppBuild {
    static let infoKey = "MuxifyBuild"

    /// The line that `bundle` carries, or `muxify dev 0` for one with no stamp.
    static func line(in bundle: Bundle) -> String {
        (bundle.object(forInfoDictionaryKey: infoKey) as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "muxify dev 0"
    }

    static let line = line(in: .main)

    /// The checkout a Debug build was built from, which the same build phase stamps as `MuxifySourceRoot`; nil in
    /// any other build. A Debug app serves a Host from its `build/host-cli/` (`DebugHostCLI`).
    static let sourceRootKey = "MuxifySourceRoot"

    static func sourceRoot(in bundle: Bundle) -> String? {
        (bundle.object(forInfoDictionaryKey: sourceRootKey) as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    static let sourceRoot = sourceRoot(in: .main)
}
