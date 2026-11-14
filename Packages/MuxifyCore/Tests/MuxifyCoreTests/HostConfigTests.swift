import Foundation
import XCTest
@testable import MuxifyCore

/// A Host's Config as the Host Server reads it for the `config` subscription.
final class HostConfigTests: XCTestCase {
    func testTheOverridesAreNamedAsTheMacsRemoteConfigNamesThemAndReadAtTheHostsHome() {
        let files = [
            "/h/.config/muxify/config.yaml": "override:\n  - ~/machine.yaml\n  - local.yaml\n  - /etc/muxify.yaml\n  - ~/machine.yaml\n",
            "/h/machine.yaml": "ui: {}\n",
            "/h/.config/muxify/local.yaml": "sidebar: {}\n",
        ]
        let config = HostConfig.read(path: "/h/.config/muxify/config.yaml", home: "/h") { files[$0] }
        XCTAssertEqual(config.shownPath, "~/.config/muxify/config.yaml")
        XCTAssertEqual(config.overrides, [
            .init(path: "~/machine.yaml", text: "ui: {}\n"),
            .init(path: "~/.config/muxify/local.yaml", text: "sidebar: {}\n"),
            .init(path: "/etc/muxify.yaml", text: nil),
        ])
        XCTAssertEqual(config.watchedFolders { ["/h", "/h/.config/muxify", "/etc"].contains($0) }, ["/h", "/h/.config/muxify", "/etc"])
    }

    func testAMissingConfigNamesNoOverridesAndWatchesTheNearestFolderThatExists() {
        let config = HostConfig.read(path: "/h/.config/muxify/config.yaml", home: "/h") { _ in nil }
        XCTAssertTrue(config.isMissing)
        XCTAssertEqual(config.overrides, [])
        XCTAssertEqual(config.watchedFolders { $0 == "/h" }, ["/h"])
    }

    func testAConfigThatDoesNotParseNamesNoOverrides() {
        let config = HostConfig.read(path: "/h/c.yaml", home: "/h") { $0 == "/h/c.yaml" ? "override: [\n" : nil }
        XCTAssertEqual(config.text, "override: [\n")
        XCTAssertEqual(config.overrides, [])
    }
}
