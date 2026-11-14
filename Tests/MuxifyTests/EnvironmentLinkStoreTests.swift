import AppKit
import XCTest
@testable import MuxifyCore

/// The store reaches its Active Environment only through its `EnvironmentLink` (ADR draft `10-mac-side-seam`).
@MainActor
final class EnvironmentLinkStoreTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // A read the store applies asks whether the app is active.
        _ = NSApplication.shared
    }

    private func configStore() -> ConfigStore {
        ConfigStore(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("muxify-link-\(UUID().uuidString).yaml").path)
    }

    private func window(_ id: String, session: String = "$1") -> TmuxWindow {
        TmuxWindow(id: id, sessionID: session, sessionName: "app", index: 1, name: "shell", paneTitle: "",
                   path: "/work/app", command: "zsh", isActive: true, paneCount: 1,
                   hasBell: false, sessionActivity: 0, agent: "", storedBrowser: .init(), openRequests: [],
                   sessionPath: "/work/app")
    }

    private func snapshot(_ windows: [TmuxWindow]) -> TmuxSnapshot {
        TmuxSnapshot(windows: windows, clients: [], panes: [], serverRunning: true, serverID: "test")
    }

    /// Runs the main run loop until `condition` holds, for a store whose link changes after a background cleanup.
    private func wait(until condition: () -> Bool, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    func testAnActionWhoseFeatureTheLinkLacksIsHiddenFromTheCommandPalette() {
        let link = FakeEnvironmentLink(features: .all)
        let store = WorkspaceStore(configStore: configStore(), defaults: isolatedDefaults()) { _ in link }
        XCTAssertTrue(store.palette.commands.contains(.newTopic))
        XCTAssertTrue(store.palette.commands.contains(.installExtensions))

        link.features = [.git]
        XCTAssertFalse(store.palette.commands.contains(.newTopic), "New Topic needs .topics")
        XCTAssertTrue(store.palette.commands.contains(.installExtensions), "Install Extensions asks only whether it is this Mac")

        let remote = FakeEnvironmentLink(isOnThisMac: false, features: .all)
        let remoteStore = WorkspaceStore(configStore: configStore(), defaults: isolatedDefaults()) { _ in remote }
        XCTAssertTrue(remoteStore.palette.commands.contains(.newTopic), "an Environment that serves Topics offers them")
        XCTAssertFalse(remoteStore.palette.commands.contains(.installExtensions))
    }

    func testChangingTheActiveEnvironmentRetiresTheOldLinkAndDropsItsLateEvents() {
        var links: [FakeEnvironmentLink] = []
        let box = RemoteEnvironment(name: "box", host: "box", username: "user")
        // The Config names no Remote Environment, so reconciling moves the App Window to Local.
        let store = WorkspaceStore(configStore: configStore(), environment: box, defaults: isolatedDefaults()) { environment in
            let link = FakeEnvironmentLink(isOnThisMac: environment == nil, features: environment == nil ? .all : [.git])
            links.append(link)
            return link
        }
        store.startLinkForTesting()
        XCTAssertEqual(links.count, 1)
        XCTAssertTrue(links[0].isConnected)

        store.reconcileEnvironments()
        wait { links.count == 2 && links[1].isConnected }
        XCTAssertEqual(links.count, 2, "a link never changes target: the new Environment gets a new one")
        XCTAssertTrue(links[1].isConnected)
        XCTAssertTrue(links[0].isRetired)
        XCTAssertTrue(store.link === links[1])
        XCTAssertTrue(store.link.isOnThisMac)

        links[0].send(.snapshot(snapshot([window("@1")])))
        links[0].send(.topics(TopicContents(records: [TopicRecord(id: "late", title: "Late")], openPlaces: [OpenPlace(order: 1)])))
        XCTAssertEqual(store.windows, [], "a retired link's late events are dropped")
        XCTAssertEqual(store.records, [])
        XCTAssertEqual(store.openPlaces, [])

        links[1].send(.snapshot(snapshot([window("@2")])))
        XCTAssertEqual(store.windows.map(\.id), ["@2"])
    }

    func testALinksFirstEventsFillWindowsRecordsAndOpenPlacesWhole() {
        let link = FakeEnvironmentLink()
        let first = [TopicRecord(id: "a", title: "A"), TopicRecord(id: "b", title: "B")]
        let places = [OpenPlace(id: "p", order: 1)]
        link.initial = [.topics(TopicContents(records: first, openPlaces: places))]
        let store = WorkspaceStore(configStore: configStore(), defaults: isolatedDefaults()) { _ in link }
        XCTAssertEqual(store.records, [], "nothing shows before the store subscribes")

        store.startLinkForTesting()
        XCTAssertEqual(store.records, first)
        XCTAssertEqual(store.openPlaces, places)
        link.send(.snapshot(snapshot([window("@1"), window("@2", session: "$2")])))
        XCTAssertEqual(store.windows.map(\.id), ["@1", "@2"])

        // Each event replaces what its key names whole: nothing of the last one is kept.
        let next = [TopicRecord(id: "c", title: "C")]
        link.send(.topics(TopicContents(records: next)))
        XCTAssertEqual(store.records, next)
        XCTAssertEqual(store.openPlaces, [])
        link.send(.snapshot(snapshot([window("@3")])))
        XCTAssertEqual(store.windows.map(\.id), ["@3"])
    }

    func testARetiredLinkEndsItsRequestsCancelled() async throws {
        let state = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: state) }
        let link = LocalEnvironmentLink(topics: TopicStore(paths: MuxifyPaths(environment: ["XDG_STATE_HOME": state.path],
                                                                               home: "/nonexistent")))
        try link.connect()
        // Retiring flushes nothing and runs no tmux here: there are no commands and no Client marker.
        link.retire(flushing: [])
        do {
            _ = try await link.view(.activePane(window: "@1"))
            XCTFail("a retired link ran a request")
        } catch {
            XCTAssertEqual(error as? TmuxError, .cancelled)
        }
    }
}
