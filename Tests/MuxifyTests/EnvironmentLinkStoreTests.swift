import AppKit
import XCTest
@testable import MuxifyCore

/// The store reaches its Active Environment only through its `EnvironmentLink` (ADR 0089).
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
        let store = WorkspaceStore(configStore: configStore(), defaults: isolatedDefaults(), visitStore: isolatedVisits()) { _ in link }
        XCTAssertTrue(store.palette.commands.contains(.newTopic))
        XCTAssertTrue(store.palette.commands.contains(.installExtensions))

        link.features = [.git]
        XCTAssertFalse(store.palette.commands.contains(.newTopic), "New Topic needs .topics")
        XCTAssertTrue(store.palette.commands.contains(.installExtensions), "Install Extensions asks only whether it is this Mac")

        let remote = FakeEnvironmentLink(isOnThisMac: false, features: .all)
        let remoteStore = WorkspaceStore(configStore: configStore(), defaults: isolatedDefaults(), visitStore: isolatedVisits()) { _ in remote }
        XCTAssertTrue(remoteStore.palette.commands.contains(.newTopic), "an Environment that serves Topics offers them")
        XCTAssertFalse(remoteStore.palette.commands.contains(.installExtensions))
    }

    func testChangingTheActiveEnvironmentRetiresTheOldLinkAndDropsItsLateEvents() {
        var links: [FakeEnvironmentLink] = []
        let box = RemoteEnvironment(name: "box", host: "box", username: "user")
        // The Config names no Remote Environment, so reconciling moves the App Window to Local.
        let store = WorkspaceStore(configStore: configStore(), environment: box, defaults: isolatedDefaults(), visitStore: isolatedVisits()) { environment in
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
        let store = WorkspaceStore(configStore: configStore(), defaults: isolatedDefaults(), visitStore: isolatedVisits()) { _ in link }
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

    // MARK: - The Host Server's fallback

    private let box = RemoteEnvironment(name: "box", host: "box", username: "user")

    /// A store on a Host link that serves Topics, whose Sessions-only link takes over when its server cannot run.
    private func hostStore() -> (WorkspaceStore, host: FakeEnvironmentLink, sessionsOnly: FakeEnvironmentLink) {
        let host = FakeEnvironmentLink(isOnThisMac: false, features: [.topics, .git])
        let sessionsOnly = FakeEnvironmentLink(isOnThisMac: false, features: [])
        host.fallback = sessionsOnly
        let store = WorkspaceStore(configStore: configStore(), environment: box, defaults: isolatedDefaults(), visitStore: isolatedVisits()) { _ in host }
        store.startLinkForTesting()
        host.send(.topics(TopicContents(records: [TopicRecord(id: "a", title: "A")])))
        return (store, host, sessionsOnly)
    }

    func testThreeFailedStartsWithinAMinuteSwapInTheSessionsOnlyLinkWithoutRetireAndBumpGeneration() {
        let (store, host, sessionsOnly) = hostStore()
        var time = Date(timeIntervalSince1970: 1_000)
        store.now = { time }
        XCTAssertEqual(store.records.map(\.id), ["a"])

        host.send(.serverStopped(lastLine: "first"))
        time += 30
        host.send(.serverStopped(lastLine: "second"))
        XCTAssertEqual(host.restarts, 2, "a server that stopped starts again on a new channel")
        XCTAssertTrue(store.link === host)
        XCTAssertNil(store.topicsUnavailableNote)

        time += 29
        host.send(.serverStopped(lastLine: "panic: third"))
        XCTAssertTrue(store.link === sessionsOnly, "the third stop within 60 s swaps in the Sessions-only link")
        XCTAssertEqual(host.restarts, 2, "nothing starts the server again")
        XCTAssertFalse(host.isRetired, "the swap keeps the master and the attach: no retire")
        XCTAssertEqual(store.records, [], "the Mac keeps no copy of the Host's Topics")
        XCTAssertEqual(store.topicsUnavailableNote,
                       "Topics are unavailable on box: the Host Server stopped 3 times in a minute (panic: third).")
        XCTAssertEqual(store.sidebarModeSwitchRefusal, store.topicsUnavailableNote)
        XCTAssertFalse(store.palette.commands.contains(.newTopic))

        // `generation` moved on: what the Host link still sends is dropped, the Sessions-only link's arrives.
        host.send(.topics(TopicContents(records: [TopicRecord(id: "late", title: "Late")])))
        host.send(.snapshot(snapshot([window("@9")])))
        XCTAssertEqual(store.records, [])
        XCTAssertEqual(store.windows, [])
        sessionsOnly.send(.snapshot(snapshot([window("@1")])))
        XCTAssertEqual(store.windows.map(\.id), ["@1"])
    }

    func testStopsMoreThanAMinuteApartStartTheServerAgainEachTime() {
        let (store, host, _) = hostStore()
        var time = Date(timeIntervalSince1970: 1_000)
        store.now = { time }
        for line in ["first", "second", "third", "fourth"] {
            host.send(.serverStopped(lastLine: line))
            time += 31
        }
        XCTAssertEqual(host.restarts, 4)
        XCTAssertTrue(store.link === host)
        XCTAssertNil(store.topicsUnavailableNote)
        XCTAssertEqual(store.records.map(\.id), ["a"])
    }

    func testAHostServerThatCannotRunFallsBackAtOnceWithTheSpecsReason() {
        let cases: [(String, HostServerUnavailable, String)] = [
            ("no server mode", .tooOld("muxify 1a2b3c4 1700000000"), "the Host's muxify is too old (muxify 1a2b3c4 1700000000)"),
            ("no shared protocol", .tooOld("muxify 9f8e7d6 1900000000"), "the Host's muxify is too old (muxify 9f8e7d6 1900000000)"),
            ("hello timeout", .noAnswer, "the Host Server did not answer"),
            ("no Host CLI", .notInstalled("failed: no Host CLI for sunos i86pc"),
             "the Host CLI could not be installed (failed: no Host CLI for sunos i86pc)"),
        ]
        for (name, unavailable, reason) in cases {
            let (store, host, sessionsOnly) = hostStore()
            host.send(.serverUnavailable(unavailable))
            XCTAssertTrue(store.link === sessionsOnly, name)
            XCTAssertEqual(host.restarts, 0, name)
            XCTAssertFalse(host.isRetired, name)
            XCTAssertEqual(store.topicsUnavailableNote, "Topics are unavailable on box: \(reason).", name)
        }
    }

    func testTheGitViewOfASessionsOnlyWindowSaysWhyItIsUnavailable() {
        let (store, host, sessionsOnly) = hostStore()
        host.gitAnswer = { _ in .snapshot(GitSnapshot(root: "/work/app", repositoryName: "app", head: "main")) }
        XCTAssertNil(store.gitViewUnavailableMessage, "a Host Server that serves reads the repository")

        host.send(.serverUnavailable(.tooOld("muxify 1a2b3c4 1700000000")))
        XCTAssertTrue(store.link === sessionsOnly)
        let message = "The Git View is unavailable on box: the Host's muxify is too old (muxify 1a2b3c4 1700000000)."
        XCTAssertEqual(store.gitViewUnavailableMessage, message)
        // The Git View's read fails with it, and the Git View shows it where it shows a read that failed.
        var shown: String?
        store.readGit(.status(folder: "/work/app"), \.snapshot) { result in
            if case .failure(let error) = result { shown = GitView.message(for: error) }
        }
        XCTAssertEqual(shown, message)
        let subscription = store.watchRepository("/work/app") { _ in XCTFail("a Sessions-only link sent a repository event") }
        subscription.cancel()
    }

    func testASessionsOnlyWindowRefusesTheWorktreeActionsWithTheFallbacksReason() async {
        let (store, host, sessionsOnly) = hostStore()
        host.features = .all
        XCTAssertNil(store.worktreesRefusal, "a Host Server keeps the Host's Muxify Worktrees")
        host.features = [.topics, .git]
        XCTAssertEqual(store.worktreesRefusal, "Muxify Worktrees are unavailable on box: its Host Server has not answered yet.")

        host.send(.serverUnavailable(.tooOld("muxify 1a2b3c4 1700000000")))
        XCTAssertTrue(store.link === sessionsOnly)
        let expected = "Muxify Worktrees are unavailable on box: the Host's muxify is too old (muxify 1a2b3c4 1700000000)."
        XCTAssertEqual(store.worktreesRefusal, expected)
        var alerts: [String] = []
        store.showAlert = { _, text in alerts.append(text) }
        XCTAssertFalse(store.perform(EnvironmentRequest(.createWorktree(name: "fix", from: "/home/me/app", start: .head, open: true))),
                       "Create Worktree does not start")
        XCTAssertFalse(store.perform(EnvironmentRequest(.removeWorktree("w1", kill: false, force: false))), "Remove Worktree does not start")
        XCTAssertEqual(alerts.count, 2)
        XCTAssertTrue(alerts.allSatisfy { $0.hasSuffix(expected) }, "\(alerts)")
        guard case .failure(let list) = await store.listWorktrees() else { return XCTFail("the Muxify Worktree list was not refused") }
        XCTAssertEqual(list.message, expected)
        guard case .failure(let starts) = await store.newWorktreeStarts(from: "/home/me/app") else { return XCTFail("the start step was not refused") }
        XCTAssertEqual(starts.message, expected)
        XCTAssertEqual(sessionsOnly.commands, [], "nothing reached the Host")
    }

    // MARK: - The Config

    private func configStore(text: String) throws -> ConfigStore {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("muxify-link-\(UUID().uuidString).yaml")
        try text.write(to: file, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        return ConfigStore(path: file.path)
    }

    /// A store on a Remote Environment's link, connected by the link's first read.
    private func connectedRemoteStore(_ link: FakeEnvironmentLink, local: String = "") throws -> WorkspaceStore {
        let store = WorkspaceStore(configStore: try configStore(text: local), environment: box, defaults: isolatedDefaults(), visitStore: isolatedVisits()) { _ in link }
        store.startLinkForTesting()
        link.send(.snapshot(snapshot([window("@1")])))
        return store
    }

    func testAHostConfigWithItsOverridesReplacesTheLocalOneAndAHostWithNoneFallsBackToTheLocalConfig() throws {
        let link = FakeEnvironmentLink(isOnThisMac: false, features: [.topics, .git])
        let store = try connectedRemoteStore(link, local: "ui:\n  status_line:\n    enabled: false\n")
        XCTAssertFalse(store.config.statusLine.enabled, "before the Host's Config comes, the window runs with the local one")

        link.send(.config(.host(HostConfig(path: "/home/u/.config/muxify/config.yaml", home: "/home/u",
                                           text: "override: ~/machine.yaml\nui:\n  status_line:\n    enabled: false\n",
                                           overrides: [.init(path: "~/machine.yaml", text: "ui:\n  status_line:\n    enabled: true\n")]))))
        XCTAssertTrue(store.config.statusLine.enabled, "the Host's Override applies on top of the Host's Config")
        XCTAssertNotNil(store.remoteConfig)

        link.send(.config(.host(HostConfig(path: "/home/u/.config/muxify/config.yaml", home: "/home/u", text: nil))))
        XCTAssertNil(store.remoteConfig, "a Host with no Config has no remote Config")
        XCTAssertFalse(store.config.statusLine.enabled, "a Host with no Config runs with the local Config (ADR 0010)")

        link.send(.config(.host(HostConfig(path: "/home/u/.config/muxify/config.yaml", home: "/home/u",
                                           text: "ui:\n  status_line:\n    enabled: true\n"))))
        XCTAssertTrue(store.config.statusLine.enabled)
        link.send(.config(.host(HostConfig(path: "/home/u/.config/muxify/config.yaml", home: "/home/u", text: "ui: [\n"))))
        XCTAssertTrue(store.config.statusLine.enabled, "a syntax error keeps the last good Host Config")
        XCTAssertFalse(store.remoteConfig?.problems.isEmpty ?? true)
    }

    func testReloadConfigAndConnectingAskTheLinkForItsConfigAgain() throws {
        let link = FakeEnvironmentLink(isOnThisMac: false, features: [.git])
        let store = try connectedRemoteStore(link)
        XCTAssertEqual(link.configReloads, 1, "connecting reads the Config")
        store.reloadConfig()
        XCTAssertEqual(link.configReloads, 2, "Reload Config reads the Config again")

        let local = FakeEnvironmentLink()
        let localStore = WorkspaceStore(configStore: configStore(), defaults: isolatedDefaults(), visitStore: isolatedVisits()) { _ in local }
        localStore.startLinkForTesting()
        localStore.reloadConfig()
        XCTAssertEqual(local.configReloads, 0, "this Mac's Config is the ConfigStore's, which reloads itself")
    }

    func testTheSessionsOnlyLinkReadsTheHostsConfigAgainOnEachReload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mxc-" + UUID().uuidString, isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let folder = home.appendingPathComponent(".config/muxify", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // The fixture's ssh runs the remote command here, with the Host's home.
        let ssh = root.appendingPathComponent("ssh")
        try """
        #!/bin/bash
        unset TMUX TMUX_PANE XDG_CONFIG_HOME
        export HOME=\(Tmux.shellQuote(home.path))
        for arg do command=$arg; done
        exec /bin/sh -c "$command"

        """.write(to: ssh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ssh.path)
        let file = folder.appendingPathComponent("config.yaml")
        try "override: ~/machine.yaml\nui:\n  header_height: 30\n".write(to: file, atomically: true, encoding: .utf8)
        try "ui:\n  header_height: 40\n".write(to: home.appendingPathComponent("machine.yaml"), atomically: true, encoding: .utf8)

        let link = SessionsOnlyEnvironmentLink(environment: box, sshExecutable: ssh.path)
        try link.connect()
        defer { link.retire(flushing: []); link.cleanup() }
        var configs: [HostConfig] = []
        let subscription = link.subscribe { event in
            if case .config(.host(let config)) = event { configs.append(config) }
        }
        defer { subscription.cancel() }

        link.reloadConfig()
        try await waitAsync("the Sessions-only link read no Config") { configs.count == 1 }
        XCTAssertEqual(configs.first?.path, file.path)
        XCTAssertEqual(configs.first?.shownPath, "~/.config/muxify/config.yaml")
        XCTAssertEqual(configs.first?.text, "override: ~/machine.yaml\nui:\n  header_height: 30\n")
        XCTAssertEqual(configs.first?.overrides, [.init(path: "~/machine.yaml", text: "ui:\n  header_height: 40\n")])

        try "ui:\n  header_height: 50\n".write(to: file, atomically: true, encoding: .utf8)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(configs.count, 1, "a Sessions-only link does not watch the Config")
        link.reloadConfig()
        try await waitAsync("Reload Config did not read the Config again") { configs.count == 2 }
        XCTAssertEqual(configs.last?.text, "ui:\n  header_height: 50\n")

        try FileManager.default.removeItem(at: file)
        link.reloadConfig()
        try await waitAsync("a removed Config was not read as missing") { configs.count == 3 }
        XCTAssertEqual(configs.last?.isMissing, true)
    }

    func testTheSessionsOnlyLinkRefusesARequestThatNeedsATopicRecordAndRunsTheOthers() async throws {
        let link = SessionsOnlyEnvironmentLink(environment: RemoteEnvironment(name: "box", host: "unused", username: "unused"))
        let list = await link.run(EnvironmentRequest(.list), client: nil, local: nil)
        XCTAssertEqual(list, .failed(EnvironmentLinkError.topicsRefused))
        let topic = await link.run(EnvironmentRequest(.newWindow(command: nil), target: .topic(.id("t"))), client: nil, local: nil)
        XCTAssertEqual(topic, .failed(EnvironmentLinkError.topicsRefused), "a Topic target is found through the records")
        let worktree = await link.run(EnvironmentRequest(.listWorktrees(all: true, from: nil)), client: nil, local: nil)
        XCTAssertEqual(worktree, .failed(EnvironmentLinkError.worktreesRefused))
        let window = await link.run(EnvironmentRequest(.newWindow(command: nil)), client: nil, local: nil)
        XCTAssertNil(window, "a Session request goes to the service, which a link that is not connected has not")
        XCTAssertFalse(SessionsOnlyEnvironmentLink.noRecords.state.path.hasPrefix(MuxifyPaths().state.path),
                       "a Sessions-only service never reads this Mac's Topic records")
    }

    private func waitAsync(_ message: String, seconds: TimeInterval = 10, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else { return XCTFail(message) }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
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
