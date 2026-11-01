// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EnvironmentWatchPrototype",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../Packages/MuxifyCore")],
    targets: [.executableTarget(name: "InventoryProbe", dependencies: ["MuxifyCore"])],
    swiftLanguageModes: [.v5]
)
