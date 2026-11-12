// swift-tools-version: 6.0
import PackageDescription

// The Topic code that the app and the command line tool share. A package of its own, so the app's Xcode
// project links it without the command line tool.
let package = Package(
    name: "MuxifyCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MuxifyCore", targets: ["MuxifyCore"]),
        .library(name: "MuxifyTestSupport", targets: ["MuxifyTestSupport"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams", exact: "6.2.2"),
        // The SQLite of the state database, built from source, so the static Linux Host CLI links the same one.
        .package(url: "https://github.com/swiftlang/swift-toolchain-sqlite", exact: "1.0.9"),
    ],
    targets: [
        // The Host CLI install script, a file of its own because `make host-cli` also publishes it (ADR 0076).
        .target(name: "MuxifyCore", dependencies: [
                    .product(name: "Yams", package: "Yams"),
                    .product(name: "SwiftToolchainCSQLite", package: "swift-toolchain-sqlite"),
                ],
                resources: [.copy("Environment/host-cli-install.sh")]),
        .target(name: "MuxifyTestSupport", dependencies: ["MuxifyCore"]),
        .testTarget(name: "MuxifyCoreTests", dependencies: ["MuxifyCore", "MuxifyTestSupport"], resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v5]
)
