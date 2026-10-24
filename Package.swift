// swift-tools-version: 6.0
import PackageDescription

// The CLI builds without the desktop app, Ghostty or XcodeGen.
let package = Package(
    name: "MuxifyCLI",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "muxify", targets: ["MuxifyCLIMain"]),
        // The app's Xcode project builds its own `muxify` from this library, so the app,
        // the CLI and all tests share one build of MuxifyCore.
        .library(name: "MuxifyCLI", targets: ["MuxifyCLI"]),
    ],
    dependencies: [
        .package(path: "Packages/MuxifyCore"),
    ],
    targets: [
        .target(name: "MuxifyCLI", dependencies: [
            .product(name: "MuxifyCore", package: "MuxifyCore"),
        ]),
        .executableTarget(name: "MuxifyCLIMain", dependencies: ["MuxifyCLI"]),
        // MuxifyCLIMain is here so that `swift test` builds the `muxify` that the integration tests run.
        .testTarget(name: "MuxifyCLITests", dependencies: [
            "MuxifyCLI",
            "MuxifyCLIMain",
            .product(name: "MuxifyTestSupport", package: "MuxifyCore"),
        ]),
    ],
    swiftLanguageModes: [.v5]
)
