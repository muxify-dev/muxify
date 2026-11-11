/// The commit that this `muxify` was built from, for `muxify --version`.
///
/// `make host-cli` writes `BuildStamp+Generated.swift` beside this file, which git ignores, with an extension that
/// conforms `BuildStamp` to `StampedBuild`. Without that file, as in a plain `swift build` or the Xcode build, the
/// stamp is `dev 0`, which any published build is newer than.
enum BuildStamp {
    /// `<short-sha> <commit-unix-time>`, or `dev 0` for a build with no stamp.
    static var value: String { (BuildStamp.self as Any.Type as? StampedBuild.Type)?.stamp ?? "dev 0" }

    /// The one line that `muxify --version` prints.
    static var versionLine: String { "muxify \(value)" }
}

/// The generated source conforms `BuildStamp` to this protocol to give it a stamp.
protocol StampedBuild {
    static var stamp: String { get }
}
