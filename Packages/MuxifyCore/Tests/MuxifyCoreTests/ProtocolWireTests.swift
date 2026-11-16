import XCTest
@testable import MuxifyCore

/// The JSON of every frame of the Host Server protocol is a contract (ADR 0086's change rule): these strings are
/// pinned, and every release's fixtures folder must still decode.
final class ProtocolWireTests: XCTestCase {
    private static let build = "muxify 1a2b3c4 1763100000"

    private static let requestID = RequestID("3f2b8c1e-7a4d-4e9b-9c0a-5d6e7f8a9b0c")!

    /// This release's messages, in the order of the newest fixtures folder: the capabilities that the phone uses.
    private func thisReleasesFrames() throws -> [Data] {
        let id = Self.requestID
        let created = EnvironmentResponse.changed(TopicChange(topicID: id.rawValue, created: true))
        func failed(_ failure: TopicFailure) -> ProtocolError { ProtocolError(.failed, failure.message, topicFailure: failure) }
        return [
            try ProtocolLine.hello(ProtocolHello(protocolVersion: 1, minProtocol: 1, build: Self.build, capabilities: HostProtocol.capabilities)),
            try ProtocolLine.hello(ProtocolHello(protocolVersion: 1, build: Self.build, capabilities: HostProtocol.capabilities)),
            try ProtocolLine.request(id: 1, HostRequest.environment(EnvironmentRequest(.create(title: "T"), request: id))),
            try ProtocolLine.ok(id: 1, created),
            try ProtocolLine.ok(id: 2, created),
            ProtocolLine.error(id: 3, failed(RequestRefusal.clash(id, verb: "environment create").failure)),
            ProtocolLine.error(id: 4, failed(RequestRefusal.inDoubt(id, phrase: EnvironmentCommand.moveCard(.up).actionName).failure)),
            ProtocolLine.error(id: 5, failed(HostEnvironment.requestOnRead(.list))),
            try ProtocolLine.request(id: 6, HostRequest.subscribe(.topic(TopicSubscription(id: "t")))),
            try ProtocolLine.item(id: 6, try Self.topicItem()),
            try ProtocolLine.item(id: 6, TopicDetailItem.none),
        ]
    }

    /// A `topic` item: a Topic with one Session, one Window and a Pane where a Claude Agent waits, Unread.
    private static func topicItem() throws -> TopicDetailItem {
        let pane = try JSONDecoder().decode(PaneSummary.self, from: Data(#"""
            {"active":true,"agent":{"conversation":null,"kind":"claude","status":"blocked","unread":true},"command":"claude","id":"%3",\#
            "index":0,"label":"claude","path":"/work/game","window_id":"@2"}
            """#.utf8))
        let window = TopicDetail.Window(id: "@2", index: 1, name: "claude", active: true, mark: nil, panes: [pane])
        let session = TopicDetail.Session(id: "$1", name: "game/ship", baseName: "game", directory: "/work/game", worktree: nil, windows: [window])
        return .topic(TopicDetail(id: "t", label: "Ship", title: "Ship", slug: "ship", createdAt: "2026-11-16T10:00:00Z", state: .live,
                                  tags: [], sessions: [session]))
    }

    /// The first server's messages, pinned in `1-first-server`.
    private func firstServersFrames() throws -> [Data] {
        [
            try ProtocolLine.hello(ProtocolHello(protocolVersion: 1, minProtocol: 1, build: Self.build)),
            try ProtocolLine.hello(ProtocolHello(protocolVersion: 1, build: Self.build)),
            try ProtocolLine.request(id: 1, HostRequest.ping),
            try ProtocolLine.request(id: 2, HostRequest.shutdown),
            try ProtocolLine.item(id: 3, ProtocolChunk(data: Data("hello".utf8))),
            try ProtocolLine.ok(id: 1, ProtocolEmpty()),
            ProtocolLine.error(id: 4, ProtocolError(.unsupported, "this muxify does not know the request frob")),
            ProtocolLine.error(id: 5, ProtocolError(.invalid, "m")),
            ProtocolLine.error(id: 6, ProtocolError(.cancelled, "cancelled")),
            ProtocolLine.error(id: 7, ProtocolError(.unavailable, "the subscriber fell behind")),
            ProtocolLine.error(id: 8, ProtocolError(.failed, "m")),
            ProtocolLine.cancel(id: 6),
        ]
    }

    func testEveryEnvelopeKindAndHelloArePinned() throws {
        func text(_ line: Data) -> String { String(decoding: line, as: UTF8.self) }
        XCTAssertEqual(text(try ProtocolLine.hello(ProtocolHello(protocolVersion: 1, minProtocol: 1, build: Self.build))),
                       #"{"hello":{"build":"muxify 1a2b3c4 1763100000","capabilities":[],"min_protocol":1,"protocol":1},"id":0,"kind":"hello"}"# + "\n")
        XCTAssertEqual(text(try ProtocolLine.hello(ProtocolHello(protocolVersion: 2, build: "muxify dev 0", capabilities: ["events.git"]))),
                       #"{"hello":{"build":"muxify dev 0","capabilities":["events.git"],"protocol":2},"id":0,"kind":"hello"}"# + "\n")
        XCTAssertEqual(text(try ProtocolLine.request(id: 1, HostRequest.ping)), #"{"id":1,"kind":"request","request":{"ping":{}}}"# + "\n")
        XCTAssertEqual(text(try ProtocolLine.request(id: 9, HostRequest.shutdown)), #"{"id":9,"kind":"request","request":{"shutdown":{}}}"# + "\n")
        XCTAssertEqual(text(try ProtocolLine.item(id: 3, ProtocolChunk(data: Data("hi".utf8)))), #"{"id":3,"item":{"data":"aGk="},"kind":"item"}"# + "\n")
        XCTAssertEqual(text(try ProtocolLine.ok(id: 1, ProtocolEmpty())), #"{"end":{"ok":{}},"id":1,"kind":"end"}"# + "\n")
        for code in ProtocolErrorCode.allCases {
            XCTAssertEqual(text(ProtocolLine.error(id: 2, ProtocolError(code, "m"))),
                           #"{"end":{"error":{"code":"\#(code.rawValue)","message":"m"}},"id":2,"kind":"end"}"# + "\n")
        }
        XCTAssertEqual(text(ProtocolLine.cancel(id: 4)), #"{"id":4,"kind":"cancel"}"# + "\n")
        XCTAssertEqual(text(ProtocolLine.magic), "MUXIFY-PROTOCOL\n")
    }

    func testTheEnvironmentSurfaceIsPinned() throws {
        func text(_ line: Data) -> String { String(decoding: line, as: UTF8.self) }
        XCTAssertEqual(text(try ProtocolLine.hello(ProtocolHello(protocolVersion: 1, build: "c", nonce: "0a1b"))),
                       #"{"hello":{"build":"c","capabilities":[],"nonce":"0a1b","protocol":1},"id":0,"kind":"hello"}"# + "\n")
        XCTAssertEqual(text(try ProtocolLine.request(id: 2, HostRequest.subscribe(.environment))),
                       #"{"id":2,"kind":"request","request":{"subscribe":{"environment":{}}}}"# + "\n")
        XCTAssertEqual(text(try ProtocolLine.request(id: 3, HostRequest.markRead(MarkRead(topics: ["t1"], panes: ["%3", "%4"])))),
                       #"{"id":3,"kind":"request","request":{"mark_read":{"panes":["%3","%4"],"topics":["t1"]}}}"# + "\n")
        XCTAssertEqual(text(try ProtocolLine.request(id: 4, HostRequest.view(.splitPane(target: "%3", side: .right)))),
                       #"{"id":4,"kind":"request","request":{"view":{"split_pane":{"side":"right","target":"%3"}}}}"# + "\n")
        XCTAssertEqual(text(try ProtocolLine.ok(id: 4, ViewOutput(output: "%5\n"))), #"{"end":{"ok":{"output":"%5\n"}},"id":4,"kind":"end"}"# + "\n")
        XCTAssertEqual(text(try ProtocolLine.request(id: 5, HostRequest.environment(EnvironmentRequest(.create(title: "T"))))),
                       text(try ProtocolLine.request(id: 5, ["environment": EnvironmentRequest(.create(title: "T"))])),
                       "an environment request carries the EnvironmentRequest as it is")

        let server = EnvironmentServer(clients: [TmuxClient(tty: "/dev/pts/1", sessionID: "$1", windowID: "@2", pid: 42)],
                                       lastWindowID: "@2", isRunning: true, serverID: "100:1763100000",
                                       socketPath: "/tmp/tmux-1000/default", home: "/home/u", hostName: "box",
                                       ownClient: ViewCommandExecutor.Client(tty: "/dev/pts/1", pid: 42))
        XCTAssertEqual(text(try ProtocolLine.item(id: 2, EnvironmentItem(changes: [.server(server)]))),
                       #"{"id":2,"item":{"changes":[{"server":{"browser_socket":null,"clients":[{"control":false,"pid":42,"session_id":"$1","tty":"/dev/pts/1","window_id":"@2"}],"home":"/home/u","host_name":"box","last_window_id":"@2","own_client":{"pid":42,"tty":"/dev/pts/1"},"running":true,"server_id":"100:1763100000","socket_path":"/tmp/tmux-1000/default"}}]},"kind":"item"}"# + "\n")
        var before = server
        before.ownClient = nil
        XCTAssertTrue(text(try ProtocolLine.item(id: 2, EnvironmentItem(changes: [.server(before)]))).contains(#""own_client":null"#),
                      "own_client is null before the marker names a Client")
        XCTAssertEqual(text(try ProtocolLine.item(id: 2, EnvironmentItem(changes: [.session("$1", nil), .topic("t1", nil)]))),
                       #"{"id":2,"item":{"changes":[{"session":"$1","value":null},{"topic":"t1","value":null}]},"kind":"item"}"# + "\n")
    }

    func testTheConfigSubscriptionIsPinned() throws {
        func text(_ line: Data) -> String { String(decoding: line, as: UTF8.self) }
        XCTAssertEqual(text(try ProtocolLine.request(id: 2, HostRequest.subscribe(.config))),
                       #"{"id":2,"kind":"request","request":{"subscribe":{"config":{}}}}"# + "\n")
        let present = HostConfig(path: "/home/u/.config/muxify/config.yaml", home: "/home/u", text: "override: ~/m.yaml\n",
                                 overrides: [.init(path: "~/m.yaml", text: nil)])
        XCTAssertEqual(text(try ProtocolLine.item(id: 2, present)),
                       #"{"id":2,"item":{"home":"/home/u","overrides":[{"path":"~/m.yaml"}],"path":"/home/u/.config/muxify/config.yaml","text":"override: ~/m.yaml\n"},"kind":"item"}"# + "\n")
        let missing = HostConfig(path: "/home/u/.config/muxify/config.yaml", home: "/home/u", text: nil)
        XCTAssertEqual(text(try ProtocolLine.item(id: 2, missing)),
                       #"{"id":2,"item":{"home":"/home/u","overrides":[],"path":"/home/u/.config/muxify/config.yaml"},"kind":"item"}"# + "\n",
                       "a Host with no Config sends no text")
        let decoded = try JSONDecoder().decode(HostConfig.self, from: Data(#"{"path":"/c.yaml"}"#.utf8))
        XCTAssertEqual(decoded, HostConfig(path: "/c.yaml", home: "", text: nil), "every key but the path is optional")
        XCTAssertTrue(decoded.isMissing)
    }

    func testTopicChoicesAndATopicFailureArePinned() throws {
        func text(_ line: Data) -> String { String(decoding: line, as: UTF8.self) }
        let choices = HostRequest.topicChoices(TopicChoicesRequest(.settle, target: .session(SessionID(rawValue: "$1")!)))
        let line = text(try ProtocolLine.request(id: 6, choices))
        XCTAssertTrue(line.hasPrefix(#"{"id":6,"kind":"request","request":{"topic_choices":{"action":"settle","target":"#), line)
        let frame = try XCTUnwrap(try ProtocolFrame.decode(Data(line.dropLast().utf8)))
        XCTAssertEqual(try frame.payload(HostRequest.self), choices)

        let failure = TopicFailure(kind: .topicUnavailable, phase: .nothingChanged, message: "m")
        XCTAssertEqual(text(ProtocolLine.error(id: 7, ProtocolError(.failed, "m", topicFailure: failure))),
                       #"{"end":{"error":{"code":"failed","message":"m","topic_failure":{"kind":"topic_unavailable","message":"m","phase":"nothing_changed"}}},"id":7,"kind":"end"}"# + "\n")
        XCTAssertEqual(text(ProtocolLine.error(id: 8, ProtocolError(.failed, "m"))),
                       #"{"end":{"error":{"code":"failed","message":"m"}},"id":8,"kind":"end"}"# + "\n",
                       "an error with no TopicFailure keeps its pinned form")
    }

    func testTheWorktreeRequestsAndAnswersArePinned() throws {
        func text(_ line: Data) -> String { String(decoding: line, as: UTF8.self) }
        func roundTrip(_ request: HostRequest, _ pinned: String) throws {
            let line = text(try ProtocolLine.request(id: 9, request))
            XCTAssertEqual(line, pinned + "\n")
            XCTAssertEqual(try XCTUnwrap(try ProtocolFrame.decode(Data(line.dropLast().utf8))).payload(HostRequest.self), request)
        }
        try roundTrip(.worktreeStarts(WorktreeStartsRequest(from: "/src/app")),
                      #"{"id":9,"kind":"request","request":{"worktree_starts":{"from":"/src/app"}}}"#)
        let row = MuxifyWorktreeRecord(id: "w", repository: "/src/app", name: "fix", path: "/t/fix", branch: "fix", base: "abc",
                                       createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        try roundTrip(.adoptWorktrees(AdoptWorktrees(rows: [row])),
                      #"{"id":9,"kind":"request","request":{"adopt_worktrees":{"rows":[{"base":"abc","branch":"fix","created_at":"2023-11-14T22:13:20Z","id":"w","name":"fix","path":"/t/fix","repository":"/src/app"}]}}}"#)
        XCTAssertEqual(text(try ProtocolLine.ok(id: 9, AdoptedWorktrees(rows: [AdoptedWorktree(id: "w"), AdoptedWorktree(id: "v", skipped: "why")]))),
                       #"{"end":{"ok":{"rows":[{"id":"w","result":"taken"},{"id":"v","reason":"why","result":"skipped"}]}},"id":9,"kind":"end"}"# + "\n")
        XCTAssertEqual(text(try ProtocolLine.ok(id: 9, WorktreeStarts(starts: [WorktreeStartChoice(branch: "main", checkedOutAt: "/src/app"),
                                                                                WorktreeStartChoice(branch: "x", checkedOutAt: nil)]))),
                       #"{"end":{"ok":{"starts":[{"branch":"main","checked_out_at":"/src/app"},{"branch":"x"}]}},"id":9,"kind":"end"}"# + "\n")
    }

    func testTheHostToMacSurfaceIsPinned() throws {
        func text(_ line: Data) -> String { String(decoding: line, as: UTF8.self) }
        XCTAssertEqual(text(try ProtocolLine.request(id: 9, HostRequest.claimOpen)), #"{"id":9,"kind":"request","request":{"claim_open":{}}}"# + "\n")
        XCTAssertEqual(text(try ProtocolLine.request(id: 9, HostRequest.releaseOpen)), #"{"id":9,"kind":"request","request":{"release_open":{}}}"# + "\n")
        XCTAssertEqual(text(try ProtocolLine.request(id: 1, MacRequest.select(.session("my work")))),
                       #"{"id":1,"kind":"request","request":{"select":{"session":"my work"}}}"# + "\n")
        XCTAssertEqual(text(try ProtocolLine.request(id: 2, MacRequest.select(.window("@3")))),
                       #"{"id":2,"kind":"request","request":{"select":{"window":"@3"}}}"# + "\n")
        XCTAssertEqual(text(try ProtocolLine.request(id: 3, MacRequest.select(.topic("t1")))),
                       #"{"id":3,"kind":"request","request":{"select":{"topic":"t1"}}}"# + "\n")
        let browser = BrowserAgentRequest(window: "@3", command: .tabs)
        XCTAssertEqual(text(try ProtocolLine.request(id: 4, MacRequest.browser(browser))),
                       text(try ProtocolLine.request(id: 4, ["browser": browser])),
                       "a browser request carries the BrowserAgentRequest as the CLI sends it")
        XCTAssertEqual(text(try ProtocolLine.ok(id: 4, BrowserAgentReply.png(Data()))), #"{"end":{"ok":{"png":{"_0":""}}},"id":4,"kind":"end"}"# + "\n",
                       "a picture's bytes come as chunks before its end")
        for request in [MacRequest.browser(browser), .select(.window("@3"))] {
            let line = try ProtocolLine.request(id: 5, request)
            XCTAssertEqual(try XCTUnwrap(try ProtocolFrame.decode(line.dropLast())).payload(MacRequest.self), request)
        }
        XCTAssertEqual(HostServerSocket.request(try JSONEncoder().encode(browser)), .browser(browser),
                       "the server's socket takes the bare line that muxify browser sends every socket")
    }

    func testSessionPathsAndUploadArePinned() throws {
        func text(_ line: Data) -> String { String(decoding: line, as: UTF8.self) }
        let sessionPaths = HostRequest.sessionPaths(SessionPathsRequest(roots: [SessionPathRoot(path: "~/code/*", depth: 1, displayDepth: 2)]))
        XCTAssertEqual(text(try ProtocolLine.request(id: 2, sessionPaths)),
                       #"{"id":2,"kind":"request","request":{"session_paths":{"roots":[{"depth":1,"path":"~/code/*"}]}}}"# + "\n")
        XCTAssertEqual(text(try ProtocolLine.ok(id: 2, SessionPathsOutput(output: "H\u{1F}/home/u\n"))),
                       #"{"end":{"ok":{"output":"H\u001f/home/u\n"}},"id":2,"kind":"end"}"# + "\n")
        XCTAssertEqual(text(try ProtocolLine.ok(id: 2, SessionPathsOutput(output: nil))), #"{"end":{"ok":{"output":null}},"id":2,"kind":"end"}"# + "\n")
        let upload = HostRequest.upload(UploadChunk(name: "a.png", offset: 65536, data: Data("hi".utf8), last: true))
        XCTAssertEqual(text(try ProtocolLine.request(id: 3, upload)),
                       #"{"id":3,"kind":"request","request":{"upload":{"data":"aGk=","last":true,"name":"a.png","offset":65536}}}"# + "\n")
        XCTAssertEqual(text(try ProtocolLine.ok(id: 3, UploadPath(path: "/tmp/muxify-paste.x/a.png"))),
                       #"{"end":{"ok":{"path":"/tmp/muxify-paste.x/a.png"}},"id":3,"kind":"end"}"# + "\n")
        for request in [sessionPaths, upload] {
            let line = try ProtocolLine.request(id: 4, request)
            let frame = try XCTUnwrap(try ProtocolFrame.decode(line.dropLast()))
            XCTAssertEqual(try frame.payload(HostRequest.self), request)
        }
    }

    func testEnvironmentEventsRoundTrip() throws {
        var window = TmuxWindow(id: "@2", sessionID: "$1", sessionName: "work", index: 1, name: "fish", paneTitle: "~/w", path: "/w",
                                command: "fish", isActive: true, paneCount: 2, hasBell: false, sessionActivity: 7, agent: "claude",
                                storedBrowser: StoredBrowser(tabURLs: ["https://a"], activeTab: 0), openRequests: ["https://b"])
        window.topicID = "t1"
        window.savedSessionID = "s1"
        window.lockOrder = 1.5
        window.layout = "abcd,120x40,0,0"
        let pane = TmuxPane(id: "%3", windowID: "@2", index: 1, isActive: true, title: "t", path: "/w", command: "node",
                            agent: "", agentStatus: "", unread: true, tty: "/dev/pts/1")
        var record = TopicRecord(id: "t1", title: "Topic")
        record.isUnread = true
        let changes: [EnvironmentChange] = [
            .session("$1", EnvironmentSession(windows: [window], panes: [pane])), .session("$9", nil),
            .topic("t1", record), .topic("t2", nil), .openPlaces([]),
            .server(EnvironmentServer(isRunning: false, home: "/home/u", hostName: "box")),
        ]
        let line = try ProtocolLine.item(id: 1, EnvironmentItem(changes: changes))
        let decoded = try XCTUnwrap(try ProtocolFrame.decode(line.dropLast())).payload(EnvironmentItem.self)
        XCTAssertEqual(decoded.changes.map(\.key), changes.map(\.key))
        guard case .session(_, let session?) = decoded.changes[0] else { return XCTFail("no session") }
        XCTAssertEqual(session.panes, [pane])
        XCTAssertEqual(session.windows.first?.id, window.id)
        XCTAssertEqual(session.windows.first?.topicID, "t1")
        XCTAssertEqual(session.windows.first?.lockOrder, 1.5)
        XCTAssertEqual(session.windows.first?.storedBrowser, window.storedBrowser)
        XCTAssertEqual(session.windows.first?.openRequests, ["https://b"])
        XCTAssertEqual(decoded.changes[2], .topic("t1", record))
        XCTAssertEqual(decoded.changes[5], changes[5])
    }

    func testAFrameIsOneLineEvenWhenItsStringsHoldNewlines() throws {
        let line = ProtocolLine.error(id: 1, ProtocolError(.failed, "one\ntwo\r\nthree"))
        XCTAssertEqual(line.filter { $0 == UInt8(ascii: "\n") }.count, 1)
        XCTAssertEqual(try XCTUnwrap(try ProtocolFrame.decode(line.dropLast())).outcome(ProtocolEmpty.self),
                       .failure(ProtocolError(.failed, "one\ntwo\r\nthree")))
    }

    func testUnknownKeysAreIgnoredAndAnUnknownCodeReadsAsFailed() throws {
        let hello = try XCTUnwrap(try ProtocolFrame.decode(Data(#"{"id":0,"kind":"hello","later":true,"hello":{"protocol":3,"min_protocol":1,"build":"b","capabilities":["x"],"later":{}}}"#.utf8)))
        XCTAssertEqual(try hello.payload(ProtocolHello.self), ProtocolHello(protocolVersion: 3, minProtocol: 1, build: "b", capabilities: ["x"]))
        let request = try XCTUnwrap(try ProtocolFrame.decode(Data(#"{"id":1,"kind":"request","request":{"ping":{"later":1},"later":{}}}"#.utf8)))
        XCTAssertEqual(try request.payload(HostRequest.self), .ping)
        let end = try XCTUnwrap(try ProtocolFrame.decode(Data(#"{"id":1,"kind":"end","end":{"error":{"code":"later","message":"m"}}}"#.utf8)))
        XCTAssertEqual(end.outcome(ProtocolEmpty.self), .failure(ProtocolError(.failed, "m")))
        XCTAssertNil(try ProtocolFrame.decode(Data(#"{"id":1,"kind":"later"}"#.utf8)), "a kind this build does not know is skipped")
        XCTAssertThrowsError(try ProtocolFrame.decode(Data(#"{"kind":"end"}"#.utf8)), "a line with no id is not a frame")
    }

    func testTheRequestCapabilityIsPinned() throws {
        func text(_ line: Data) -> String { String(decoding: line, as: UTF8.self) }
        XCTAssertEqual(HostProtocol.capabilities, ["request", "snapshot", "topic-detail", "ranked-session-paths", "browser-tabs"])
        let request = HostRequest.environment(EnvironmentRequest(.create(title: "T"), request: Self.requestID))
        let line = text(try ProtocolLine.request(id: 1, request))
        XCTAssertEqual(line, #"{"id":1,"kind":"request","request":{"environment":{"command":{"create":{"title":"T"}},"request":"3f2b8c1e-7a4d-4e9b-9c0a-5d6e7f8a9b0c","version":2}}}"# + "\n")
        XCTAssertEqual(try XCTUnwrap(try ProtocolFrame.decode(Data(line.dropLast().utf8))).payload(HostRequest.self), request)
        XCTAssertEqual(request.capability, .request)
        XCTAssertNil(HostRequest.environment(EnvironmentRequest(.create(title: "T"))).capability, "an environment request with no id is protocol 1's base")
        XCTAssertThrowsError(try JSONDecoder().decode(EnvironmentRequest.self, from: Data(#"{"version":2,"command":{"list":{}},"request":"x"}"#.utf8)),
                             "a Request id is a UUID")

        let same = PendingRequest(EnvironmentRequest(.create(title: "T"), request: Self.requestID))
        XCTAssertEqual(same, PendingRequest(EnvironmentRequest(.create(title: "T"), request: Self.requestID)))
        XCTAssertEqual(same?.verb, "environment create")
        XCTAssertNotEqual(same?.arguments, PendingRequest(EnvironmentRequest(.create(title: "U"), request: Self.requestID))?.arguments)
        XCTAssertNotEqual(same?.arguments, PendingRequest(EnvironmentRequest(.create(title: "T"), target: .topic(.id("t")), request: Self.requestID))?.arguments)
        let panes: Set<PaneID> = [PaneID(rawValue: "%1")!, PaneID(rawValue: "%2")!, PaneID(rawValue: "%3")!]
        XCTAssertEqual(PendingRequest(EnvironmentRequest(.killWindow, expectedPaneIDs: panes, request: Self.requestID))?.arguments,
                       #"{"caller":null,"command":{"kill_window":{}},"expected_pane_ids":["%1","%2","%3"],"expected_session_ids":null,"target":null}"#,
                       "a set of Panes is in one order")
    }

    func testTheTopicSubscriptionIsPinned() throws {
        func text(_ line: Data) -> String { String(decoding: line, as: UTF8.self) }
        let request = HostRequest.subscribe(.topic(TopicSubscription(id: "t")))
        let line = text(try ProtocolLine.request(id: 6, request))
        XCTAssertEqual(line, #"{"id":6,"kind":"request","request":{"subscribe":{"topic":{"id":"t"}}}}"# + "\n")
        XCTAssertEqual(try XCTUnwrap(try ProtocolFrame.decode(Data(line.dropLast().utf8))).payload(HostRequest.self), request)
        XCTAssertEqual(request.capability, .topicDetail)

        let item = try Self.topicItem()
        let itemLine = text(try ProtocolLine.item(id: 6, item))
        XCTAssertEqual(itemLine, #"{"id":6,"item":{"topic":{"created_at":"2026-11-16T10:00:00Z","id":"t","label":"Ship","note":null,"#
            + #""sessions":[{"base_name":"game","directory":"/work/game","id":"$1","name":"game/ship","windows":[{"active":true,"id":"@2","#
            + #""index":1,"mark":null,"name":"claude","panes":[{"active":true,"agent":{"conversation":null,"kind":"claude","status":"blocked","#
            + #""unread":true},"command":"claude","id":"%3","index":0,"label":"claude","path":"/work/game","window_id":"@2"}]}],"worktree":null}],"#
            + #""slug":"ship","state":"live","tags":[],"title":"Ship"}},"kind":"item"}"# + "\n")
        XCTAssertEqual(try XCTUnwrap(try ProtocolFrame.decode(Data(itemLine.dropLast().utf8))).payload(TopicDetailItem.self), item)

        let gone = text(try ProtocolLine.item(id: 6, TopicDetailItem.none))
        XCTAssertEqual(gone, #"{"id":6,"item":null,"kind":"item"}"# + "\n")
        XCTAssertEqual(try XCTUnwrap(try ProtocolFrame.decode(Data(gone.dropLast().utf8))).payload(TopicDetailItem.self), .none)
    }

    /// Whether an `item` decodes as one of the protocol's items: a chunk, or a `topic` subscription's detail or null.
    private static func decodesAsAnItem(_ frame: ProtocolFrame) -> Bool {
        // `try?` would flatten a null item into a failure.
        do { _ = try frame.payload(ProtocolChunk.self); return true } catch {}
        do { _ = try frame.payload(TopicDetailItem.self); return true } catch { return false }
    }

    func testAnUnknownRequestCaseThrowsUnsupported() {
        XCTAssertThrowsError(try JSONDecoder().decode(HostRequest.self, from: Data(#"{"frob":{}}"#.utf8))) { error in
            XCTAssertEqual((error as? ProtocolError)?.code, .unsupported)
        }
    }

    /// The newest folder holds exactly this release's messages; every folder, this one and those of earlier
    /// releases, decodes.
    func testEveryReleasesFixturesDecode() throws {
        let root = try XCTUnwrap(Bundle.module.url(forResource: "Protocol", withExtension: nil, subdirectory: "Fixtures"))
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        XCTAssertEqual(folders.map(\.lastPathComponent).suffix(2), ["1-first-server", "2-phone"])
        for folder in folders {
            let text = try String(contentsOf: folder.appendingPathComponent("frames.jsonl"), encoding: .utf8)
            let lines = text.split(separator: "\n").map { Data($0.utf8) }
            XCTAssertFalse(lines.isEmpty, folder.lastPathComponent)
            for line in lines {
                let frame = try XCTUnwrap(try ProtocolFrame.decode(line), String(decoding: line, as: UTF8.self))
                switch frame.kind {
                case .hello: XCTAssertNoThrow(try frame.payload(ProtocolHello.self))
                case .request: XCTAssertNoThrow(try frame.payload(HostRequest.self))
                case .item: XCTAssertTrue(Self.decodesAsAnItem(frame), String(decoding: line, as: UTF8.self))
                case .end:
                    if case .failure(let error) = frame.outcome(ProtocolEmpty.self) { XCTAssertNotEqual(error.message, "", "\(error)") }
                case .cancel: XCTAssertGreaterThan(frame.id, 0)
                }
            }
            if folder == folders.last {
                XCTAssertEqual(lines, try thisReleasesFrames().map { $0.dropLast() }, "the newest fixtures are this release's messages")
            }
            if folder.lastPathComponent == "1-first-server" {
                XCTAssertEqual(lines, try firstServersFrames().map { $0.dropLast() }, "the first server's messages still encode as pinned")
            }
        }
    }

    // MARK: - Lines

    func testTheReaderSkipsShellOutputBeforeTheMagicLine() throws {
        var reader = ProtocolLineReader(awaitingMagic: true)
        XCTAssertEqual(try reader.feed(Data("Welcome to fish\r\nlast login\nMUXIFY-PRO".utf8)), [])
        XCTAssertEqual(try reader.feed(Data("TOCOL\r\n{\"a\":1}\n\n{\"b\"".utf8)), [Data(#"{"a":1}"#.utf8)])
        XCTAssertEqual(try reader.feed(Data(":2}\n".utf8)), [Data(#"{"b":2}"#.utf8)])
        XCTAssertNil(reader.endFailure)
    }

    func testTheReaderFailsWithTheByteCountAndFirstLineWhenTheMagicLineIsLateOrMissing() throws {
        var missing = ProtocolLineReader(awaitingMagic: true)
        XCTAssertEqual(try missing.feed(Data("bash: muxify: command not found\nbye".utf8)), [])
        XCTAssertEqual(missing.endFailure, .noMagicLine(printed: 35, firstLine: "bash: muxify: command not found"))

        let line = String(repeating: "x", count: 1023) + "\n"
        var exactly = ProtocolLineReader(awaitingMagic: true)
        XCTAssertEqual(try exactly.feed(Data((String(repeating: line, count: 64) + "MUXIFY-PROTOCOL\n{}\n").utf8)), [Data("{}".utf8)],
                       "64 KiB of shell output is skipped")
        var late = ProtocolLineReader(awaitingMagic: true)
        XCTAssertThrowsError(try late.feed(Data(("motd\n" + String(repeating: line, count: 64) + "MUXIFY-PROTOCOL\n").utf8))) { error in
            XCTAssertEqual(error as? ProtocolLineReader.Failure, .noMagicLine(printed: 5 + 64 * 1024, firstLine: "motd"))
        }
        var endless = ProtocolLineReader(awaitingMagic: true)
        XCTAssertThrowsError(try endless.feed(Data(repeating: UInt8(ascii: "y"), count: 64 * 1024 + 100))) { error in
            XCTAssertEqual(error as? ProtocolLineReader.Failure, .noMagicLine(printed: 64 * 1024 + 100, firstLine: String(repeating: "y", count: 200)))
        }
    }

    func testALineOverTheLimitIsAProtocolError() throws {
        var reader = ProtocolLineReader(awaitingMagic: false, maxFrameBytes: 8)
        XCTAssertEqual(try reader.feed(Data("12345678\n".utf8)), [Data("12345678".utf8)])
        XCTAssertThrowsError(try reader.feed(Data("123456789\n".utf8)))
        var partial = ProtocolLineReader(awaitingMagic: false, maxFrameBytes: 8)
        XCTAssertThrowsError(try partial.feed(Data("1234567890".utf8)), "a long line fails before its newline comes")
    }

    // MARK: - The writer queue

    func testANewerEventReplacesAnUnsentOneWithTheSameKey() {
        var queue = ProtocolWriterQueue(capacity: 3)
        XCTAssertEqual(queue.pushEvent(Data("a1".utf8), request: 1, key: "session $1"), .queued)
        XCTAssertEqual(queue.pushEvent(Data("b1".utf8), request: 1, key: "topic t"), .queued)
        XCTAssertEqual(queue.pushEvent(Data("a2".utf8), request: 1, key: "session $1"), .replaced)
        XCTAssertEqual(queue.pushEvent(Data("other".utf8), request: 2, key: "session $1"), .queued, "another subscription's key is its own")
        queue.pushControl(Data("end".utf8))
        XCTAssertEqual([queue.pop(), queue.pop(), queue.pop(), queue.pop(), queue.pop()],
                       [Data("a2".utf8), Data("b1".utf8), Data("other".utf8), Data("end".utf8), nil])
    }

    func testAFullQueueRefusesANewEventAndItemsButNotControlFrames() {
        var queue = ProtocolWriterQueue(capacity: 2)
        XCTAssertEqual(queue.pushEvent(Data("a".utf8), request: 1, key: "a"), .queued)
        XCTAssertTrue(queue.pushItem(Data("chunk".utf8)))
        XCTAssertEqual(queue.pushEvent(Data("b".utf8), request: 1, key: "b"), .full)
        XCTAssertEqual(queue.pushEvent(Data("a2".utf8), request: 1, key: "a"), .replaced, "replacing needs no room")
        XCTAssertFalse(queue.pushItem(Data("chunk".utf8)))
        queue.pushControl(Data("end".utf8))
        queue.removeEvents(of: 1)
        XCTAssertEqual([queue.pop(), queue.pop(), queue.pop()], [Data("chunk".utf8), Data("end".utf8), nil])
    }

    func testTheClientPicksTheHighestProtocolBothSpeak() {
        XCTAssertEqual(ProtocolClient.pick(1...3, 1...2), 2)
        XCTAssertEqual(ProtocolClient.pick(2...2, 1...4), 2)
        XCTAssertEqual(ProtocolClient.pick(1...1, 1...1), 1)
        XCTAssertNil(ProtocolClient.pick(3...4, 1...2))
        XCTAssertEqual(ProtocolHello(protocolVersion: 3, minProtocol: 2, build: "b").offered, 2...3)
        XCTAssertEqual(ProtocolHello(protocolVersion: 3, build: "b").offered, 3...3)
        XCTAssertNil(ProtocolHello(protocolVersion: 1, minProtocol: 2, build: "b").offered)
    }
}
