// swift-tools-version: 6.0
import PackageDescription

// The Topic code that the app and the command line tool share. A package of its own, so the app's Xcode
// project links it without the command line tool.
let package = Package(
    name: "MuxifyCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "MuxifyCore", targets: ["MuxifyCore"])],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams", exact: "6.2.2"),
    ],
    targets: [
        .target(name: "MuxifyCore", dependencies: [.product(name: "Yams", package: "Yams")]),
        .testTarget(name: "MuxifyCoreTests", dependencies: ["MuxifyCore"], resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v5]
)
