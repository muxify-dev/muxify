// swift-tools-version: 6.0
import PackageDescription

// The CLI builds without the desktop app, Ghostty or XcodeGen.
let package = Package(
    name: "MuxifyCLI",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "muxify", targets: ["MuxifyCLI"])],
    dependencies: [
        .package(path: "Packages/MuxifyCore"),
    ],
    targets: [
        .executableTarget(name: "MuxifyCLI", dependencies: [
            .product(name: "MuxifyCore", package: "MuxifyCore"),
        ]),
        .testTarget(name: "MuxifyCLITests", dependencies: ["MuxifyCLI"]),
    ],
    swiftLanguageModes: [.v5]
)
