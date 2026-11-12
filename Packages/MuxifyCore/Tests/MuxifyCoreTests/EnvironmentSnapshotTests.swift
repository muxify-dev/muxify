import XCTest
@testable import MuxifyCore

final class EnvironmentSnapshotTests: XCTestCase {
    private func window(_ session: String, name: String? = nil, topic: String? = nil, lock: Double? = nil, created: Int = 0,
                        activity: Int = 0, index: Int = 0, active: Bool = true) -> TmuxWindow {
        TmuxWindow(id: "@\(UUID().uuidString.prefix(8))", sessionID: session, sessionName: name ?? "s" + session.dropFirst(),
                   index: index, name: "shell", paneTitle: "", path: "/work", command: "zsh", isActive: active, paneCount: 1, hasBell: false,
                   sessionActivity: activity, agent: "", storedBrowser: StoredBrowser(), openRequests: [], topicID: topic, lockOrder: lock,
                   sessionCreated: created)
    }

    private func topic(_ id: String, order: Double, title: String? = nil) -> TopicRecord {
        var record = TopicRecord(id: id, title: title ?? id.capitalized)
        record.order = order
        return record
    }

    /// An Agent in the first Window of `session`.
    private struct AgentPane {
        let session: String
        let status: AgentStatus
        var unread = false
    }

    private func snapshot(_ records: [TopicRecord], openPlaces: [OpenPlace] = [], windows: [TmuxWindow], agents: [AgentPane] = [],
                          inPlay: Int = Config.Topics.defaultInPlay, tags: ConfigTags? = nil) -> EnvironmentSnapshot {
        var topics = Config.Topics()
        topics.inPlay = inPlay
        topics.tags = tags
        let panes = agents.enumerated().map { index, agent in
            TmuxPane(id: "%\(index)", windowID: windows.first { $0.sessionID == agent.session }!.id, command: "claude", agent: "claude",
                     agentStatus: agent.status.rawValue, unread: agent.unread)
        }
        return EnvironmentSnapshot(contents: TopicContents(records: records, openPlaces: openPlaces),
                                   tmux: TmuxSnapshot(windows: windows, clients: [], panes: panes, serverRunning: true),
                                   topics: topics, notifications: Config.Notifications())
    }

    /// Each card as one short line: the kind, then the Topic id or the Session id or the Open Place id.
    private func names(_ cards: [EnvironmentSnapshot.Card]) -> [String] {
        cards.map { card in
            switch card {
            case .topic(let topic, _, _): return "topic:" + topic.id
            case .session(let session, _): return "session:" + session
            case .openPlace(let id): return "open:" + id
            }
        }
    }

    private func sections(_ snapshot: EnvironmentSnapshot) -> (places: [String], guests: [String], bench: [String])? {
        guard case .inPlay(_, let places, let guests, let bench) = snapshot.unpinned else { return nil }
        return (names(places), names(guests), names(bench))
    }

    private func topicCard(_ id: String, in snapshot: EnvironmentSnapshot) -> (topic: EnvironmentSnapshot.Topic, mark: CardMark?, sessions: [String])? {
        for card in snapshot.cards {
            if case .topic(let topic, let mark, let sessions) = card, topic.id == id { return (topic, mark, sessions) }
        }
        return nil
    }

    func testWindowReadsKeepIndexOrderAndShareNotificationRules() throws {
        let record = topic("a", order: 0)
        let windows = (0..<6).map { window("$1", topic: record.id, index: $0, active: $0 == 2) }
        let panes = [
            TmuxPane(id: "%0", windowID: windows[0].id, command: "claude", agent: "claude", agentStatus: "working", unread: false),
            TmuxPane(id: "%1", windowID: windows[0].id, command: "claude", agent: "claude", agentStatus: "blocked", unread: false),
            TmuxPane(id: "%2", windowID: windows[1].id, command: "claude", agent: "claude", agentStatus: "done", unread: true),
            TmuxPane(id: "%3", windowID: windows[2].id, command: "claude", agent: "claude", agentStatus: "failed", unread: true),
            TmuxPane(id: "%4", windowID: windows[3].id, command: "claude", agent: "claude", agentStatus: "working", unread: false),
            TmuxPane(id: "%5", windowID: windows[4].id, command: "claude", agent: "claude", agentStatus: "done", unread: false)
        ]
        let loose = window("$2")
        let tmux = TmuxSnapshot(windows: Array(windows.reversed()) + [loose], clients: [], panes: panes, serverRunning: true)
        for enabled in [true, false] {
            var notifications = Config.Notifications()
            notifications.doneEnabled = enabled
            notifications.failedEnabled = enabled
            notifications.blockedEnabled = enabled
            let shown = EnvironmentSnapshot(contents: TopicContents(records: [record], openPlaces: []),
                                            tmux: tmux, topics: Config.Topics(), notifications: notifications)
            let detail = TopicDetail(record: record, label: "A", snapshot: tmux, sessionPaths: [], topics: Config.Topics(),
                                     notifications: notifications, branches: TopicBranches(records: [record]) { _ in nil })
            let session = try XCTUnwrap(shown.sessions.first { $0.id == "$1" })
            let detailed = try XCTUnwrap(detail.sessions.first)
            let expected: [AgentMark?] = enabled ? [.blocked, .done, .failed, .working, nil, nil]
                                                : [.working, nil, nil, .working, nil, nil]
            XCTAssertEqual(session.windows.map(\.id), windows.map(\.id))
            XCTAssertEqual(session.windows.map(\.index), Array(0..<6))
            XCTAssertEqual(session.windows.map(\.name), windows.map(\.name))
            XCTAssertEqual(session.windows.map(\.active), [false, false, true, false, false, false])
            XCTAssertEqual(session.windows.map(\.mark), expected)
            XCTAssertEqual(detailed.windows.map(\.id), windows.map(\.id))
            XCTAssertEqual(detailed.windows.map(\.mark), expected)
            XCTAssertEqual(shown.sessions.first { $0.id == "$2" }?.windows.map(\.id), [loose.id])
            let data = try JSONEncoder().encode(shown)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let sessions = try XCTUnwrap(json["sessions"] as? [[String: Any]])
            let encoded = try XCTUnwrap(sessions.first { $0["id"] as? String == "$1" }?["windows"] as? [[String: Any]])
            XCTAssertEqual(Set(try XCTUnwrap(encoded.first).keys), ["id", "index", "name", "active", "mark"])
            XCTAssertTrue(encoded[5]["mark"] is NSNull)
            XCTAssertEqual(encoded[0]["mark"] as? String, enabled ? "blocked" : "working")
            XCTAssertEqual(try JSONDecoder().decode(EnvironmentSnapshot.self, from: data), shown)
            let detailData = try JSONEncoder().encode(detail)
            let detailJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: detailData) as? [String: Any])
            let detailSessions = try XCTUnwrap(detailJSON["sessions"] as? [[String: Any]])
            let detailWindows = try XCTUnwrap(detailSessions.first?["windows"] as? [[String: Any]])
            XCTAssertTrue(detailWindows[5]["mark"] is NSNull)
            XCTAssertEqual(try JSONDecoder().decode(TopicDetail.self, from: detailData), detail)
        }
    }

    func testALockedSessionThatWasAmongTheTopicsIsAGuestAndNotInNoTopic() {
        let shown = snapshot([topic("a", order: 0), topic("b", order: 2)],
                             windows: [window("$1", topic: "a"), window("$3", lock: 1), window("$4")])
        XCTAssertEqual(sections(shown)?.places, ["topic:a", "topic:b"])
        XCTAssertEqual(sections(shown)?.guests, ["session:$3"])
        XCTAssertEqual(shown.noTopic, ["$4"], "a Locked Session has a card, so it is not in no_topic")
    }

    func testAnOpenPlaceKeepsItsPlaceAndThePlacesAfterIt() {
        let shown = snapshot([topic("a", order: 0), topic("b", order: 2), topic("c", order: 3)], openPlaces: [OpenPlace(id: "gap", order: 1)],
                             windows: [], inPlay: 3)
        XCTAssertEqual(sections(shown)?.places, ["topic:a", "open:gap", "topic:b"], "place 2 is the Open Place")
        XCTAssertEqual(sections(shown)?.bench, ["topic:c"])
    }

    func testAGuestTopicAndAGuestSessionAreGuestsInListOrder() {
        var guest = topic("g", order: 1)
        guest.isGuest = true
        let shown = snapshot([topic("a", order: 0), guest, topic("b", order: 3)], windows: [window("$5", lock: 2)], inPlay: 1)
        XCTAssertEqual(sections(shown)?.places, ["topic:a"])
        XCTAssertEqual(sections(shown)?.guests, ["topic:g", "session:$5"])
        XCTAssertEqual(sections(shown)?.bench, ["topic:b"], "a Locked Session is never Benched")
    }

    func testAPinnedTopicIsPinnedAndHoldsNoPlace() {
        var pinned = topic("p", order: 5)
        pinned.isPinned = true
        let shown = snapshot([topic("a", order: 0), pinned], windows: [], inPlay: 1)
        XCTAssertEqual(names(shown.pinned), ["topic:p"])
        XCTAssertEqual(sections(shown)?.places, ["topic:a"])
    }

    func testABenchedDormantTopicAndABenchedEmptyTopic() {
        var dormant = topic("d", order: 1)
        dormant.sessions = [.object(["id": .string("saved"), "directory": .string("/work")])]
        let shown = snapshot([topic("a", order: 0), dormant, topic("e", order: 2)], windows: [window("$1", topic: "a")], inPlay: 1)
        XCTAssertEqual(sections(shown)?.bench, ["topic:d", "topic:e"])
        XCTAssertEqual(topicCard("a", in: shown)?.topic.state, .live)
        XCTAssertEqual(topicCard("d", in: shown)?.topic.state, .dormant)
        XCTAssertEqual(topicCard("d", in: shown)?.sessions, [])
        XCTAssertEqual(topicCard("e", in: shown)?.topic.state, .empty)
    }

    func testATopicListsItsSessionsInTheOrderTheUserGave() {
        var record = topic("a", order: 0)
        let windows = [window("$8", topic: "a", created: 1), window("$9", topic: "a", created: 2)]
        XCTAssertEqual(topicCard("a", in: snapshot([record], windows: windows))?.sessions, ["$8", "$9"], "oldest first by default")
        record.hasManualSessionOrder = true
        record.sessions = [.object(["id": .string("$9")]), .object(["id": .string("$8")])]
        XCTAssertEqual(topicCard("a", in: snapshot([record], windows: windows))?.sessions, ["$9", "$8"])
    }

    func testTwoUntitledTopicsGetTheirNumbers() {
        var slugged = TopicRecord(id: "u1", slug: "untitled-2")
        slugged.order = 0
        var blank = TopicRecord(id: "u2", title: "  ")
        blank.order = 1
        let shown = snapshot([slugged, blank], windows: [])
        XCTAssertEqual(topicCard("u1", in: shown)?.topic.label, "Untitled 2", "the number of its slug")
        XCTAssertEqual(topicCard("u2", in: shown)?.topic.label, "Untitled 1", "the lowest free number")
    }

    func testTheMarkIsBlockedOrFailedThenUnreadThenTheAgentMark() {
        // The Topic is Unread or not; its Session runs these Agents, as (Status, Agent Unread).
        let cases: [(unread: Bool, agents: [(AgentStatus, Bool)], card: CardMark?, session: AgentMark?)] = [
            (true, [(.blocked, false), (.working, false)], .agent(.blocked), .blocked),
            (true, [(.failed, true)], .agent(.failed), .failed),
            (true, [(.done, true), (.working, false)], .unread, .done),
            (false, [(.done, true), (.working, false)], .agent(.done), .done),
            (true, [(.working, false)], .unread, .working),
            (false, [(.working, false)], .agent(.working), .working),
            (false, [(.done, false)], nil, nil),
            (false, [], nil, nil),
        ]
        for (unread, statuses, card, session) in cases {
            var record = topic("a", order: 0)
            record.isUnread = unread
            let agents = ["$1", "$2"].flatMap { id in statuses.map { AgentPane(session: id, status: $0.0, unread: $0.1) } }
            let shown = snapshot([record], windows: [window("$1", topic: "a"), window("$2", lock: 1)], agents: agents)
            let context = "unread=\(unread) \(statuses)"
            XCTAssertEqual(topicCard("a", in: shown)?.mark, card, context)
            XCTAssertEqual(shown.sessions.first { $0.id == "$1" }?.mark, session.map(CardMark.agent), "a Session shows its Agent mark: " + context)
            guard case .inPlay(_, _, let guests, _) = shown.unpinned, case .session(_, let locked)? = guests.last else { return XCTFail("no Locked card") }
            XCTAssertEqual(locked, session.map(CardMark.agent), "a Locked Session's card has no Unread of its own: " + context)
        }
    }

    func testATopicCardShowsTheStrongestMarkOfItsSessions() {
        let shown = snapshot([topic("a", order: 0)], windows: [window("$1", topic: "a", created: 1), window("$2", topic: "a", created: 2)],
                             agents: [AgentPane(session: "$1", status: .working), AgentPane(session: "$2", status: .blocked)])
        XCTAssertEqual(topicCard("a", in: shown)?.mark, .agent(.blocked))
        XCTAssertEqual(shown.sessions.map(\.mark), [.agent(.working), .agent(.blocked)])
    }

    func testATagThatTheConfigNoLongerDefinesStaysOnTheTopicButNotAtTheTop() throws {
        let backend = try XCTUnwrap(Tag(name: "backend")), ui = try XCTUnwrap(Tag(name: "ui")), old = try XCTUnwrap(Tag(name: "old"))
        let tags = ConfigTags([TagDefinition(tag: backend, color: .single(.system(.orange))),
                               TagDefinition(tag: ui, color: .pair(light: .rgb(red: 0x11, green: 0x22, blue: 0x33), dark: .system(.blue)))])
        var record = topic("a", order: 0)
        record.tags = [old, backend]
        let shown = snapshot([record], windows: [], tags: tags)
        XCTAssertEqual(topicCard("a", in: shown)?.topic.tags, [backend, old], "Config order, then the Tags it no longer defines")
        XCTAssertEqual(shown.tags.map(\.name), ["backend", "ui"])
        XCTAssertEqual(shown.tags.map(\.color), [.init(light: "orange", dark: "orange"), .init(light: "#112233", dark: "blue")],
                       "always a light and dark pair")
    }

    func testSessionsAreEachLiveSessionOnceInTmuxOrder() {
        let windows = [window("$2", name: "game/fix", topic: "a", activity: 20), window("$2", name: "game/fix", topic: "a", activity: 20),
                       window("$1", name: "notes", activity: 10), window("$3", name: "gone", topic: "settled", activity: 30)]
        var settled = topic("settled", order: 1)
        settled.settledAt = "2026-10-01T10:00:00Z"
        let shown = snapshot([topic("a", order: 0), settled], windows: windows)
        XCTAssertEqual(shown.sessions.map(\.id), ["$2", "$1", "$3"])
        XCTAssertEqual(shown.sessions.map(\.name), ["game/fix", "notes", "gone"])
        XCTAssertEqual(shown.sessions.map(\.activity), [20, 10, 30])
        XCTAssertEqual(shown.sessions.map(\.topic), ["a", nil, nil], "a Settled Topic is not open, so its Session is in no Topic")
        XCTAssertEqual(shown.noTopic, ["$1", "$3"])
    }

    func testTheJSONHasEveryKeyWithNullForAMissingValue() throws {
        let shown = snapshot([topic("a", order: 0)], openPlaces: [OpenPlace(id: "gap", order: 1)],
                             windows: [window("$1", topic: "a"), window("$2", lock: 2)], agents: [AgentPane(session: "$1", status: .blocked)],
                             inPlay: 2)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let text = String(decoding: try encoder.encode(shown), as: UTF8.self)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["tags", "sessions", "pinned", "unpinned", "no_topic"])
        XCTAssertTrue(text.contains(#"{"id":"gap","kind":"open_place","sessions":[]}"#), text)
        XCTAssertTrue(text.contains(#""topic":{"id":"a","label":"A","note":null,"state":"live","tags":[]}"#), text)
        XCTAssertTrue(text.contains(#"{"kind":"session","mark":null,"sessions":["$2"]}"#), text)
        XCTAssertTrue(text.contains(#""kind":"in_play","limit":2"#), text)
        XCTAssertTrue(text.contains(#""topic":null"#), "a Session in no Topic: \(text)")
        XCTAssertTrue(text.contains(#"{"kind":"topic","mark":"blocked","sessions":["$1"]"#), "a mark is its name: \(text)")
        XCTAssertEqual(try JSONDecoder().decode(EnvironmentSnapshot.self, from: Data(text.utf8)), shown)
        XCTAssertEqual(try JSONDecoder().decode(EnvironmentResponse.self, from: try encoder.encode(EnvironmentResponse.snapshot(shown))),
                       .snapshot(shown))
    }
}
