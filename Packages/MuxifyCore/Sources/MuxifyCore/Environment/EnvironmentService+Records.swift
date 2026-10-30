import Foundation

// The records lane: commands that take the record lock only. Each writes keys of Topic records, Agent options in tmux, or both.
extension EnvironmentService {
    func changeRecords(_ request: EnvironmentRequest, client: String?) -> EnvironmentResponse {
        switch request.command {
        case .tags(let change): return changeTags(request, change, client: client)
        case .note(let note): return setNote(request, note, client: client)
        case .pin: return pin(request, true, client: client)
        case .unpin: return pin(request, false, client: client)
        case .moveCard(let move): return moveCard(request, move, client: client)
        case .chooseInPlay(let cards): return chooseInPlay(cards, client: client)
        case .replaceFromBench(let benched): return replaceFromBench(request, with: benched, client: client)
        case .markRead(let change, let scope): return markRead(request, change, scope: scope, client: client)
        case .markAllRead: return markRead(request, .read, scope: nil, client: client)
        default: preconditionFailure("\(request.command) is not in the records lane")
        }
    }

    /// Upgrades the records that a Muxify with Snooze and Zen wrote, with this service's place for a returning Topic,
    /// and sets the Locks it moved in tmux. Nil when it succeeded or had nothing to upgrade.
    public func upgradeRecords(client: String? = nil) -> TopicFailure? {
        var phase = TopicFailure.Phase.nothingChanged
        do {
            let contents = try store.read()
            guard contents.needsUpgrade else { return nil }
            let locks = SessionLock.locks(in: try server.snapshot().windows, records: contents.records)
            let moved = try store.upgrade(locks: locks, arrival: topics.arrival)
            phase = .recordSaved
            try executor.run(moved.map { .tmux($0.setOption) }, client: client)
            return nil
        } catch {
            return failure(error, phase: phase)
        }
    }

    /// Pin and Unpin move the card among the Topics and may renumber the Locks, which tmux keeps, so the moved Locks go
    /// to tmux after the one write.
    private func pin(_ request: EnvironmentRequest, _ pinned: Bool, client: String?) -> EnvironmentResponse {
        var phase = TopicFailure.Phase.nothingChanged
        do {
            let records = try store.read().records
            let snapshot = try server.snapshot()
            let topic = try openTopic(request.target, caller: request.caller, records: records, snapshot: snapshot, client: client)
            if topic.isPinned == pinned { return .changed(TopicChange(topicID: topic.id)) }
            let moved = try store.write(locks: SessionLock.locks(in: snapshot.windows, records: records)) { try $0.pin(topic.id, pinned) }
            phase = .changesStarted
            try executor.run(moved.map { .tmux($0.setOption) }, client: client)
            return .changed(TopicChange(topicID: topic.id))
        } catch {
            return .failed(failure(error, phase: phase))
        }
    }

    /// A card move writes the order of the Topics list, and may renumber the Locks, which tmux keeps.
    func moveCard(_ request: EnvironmentRequest, _ move: CardMove, client: String?) -> EnvironmentResponse {
        var phase = TopicFailure.Phase.nothingChanged
        do {
            let contents = try store.read()
            let snapshot = try server.snapshot()
            let card = try self.card(request.target, caller: request.caller, records: contents.records, snapshot: snapshot, client: client)
            let change: (inout TopicTransaction) throws -> [SessionLock]
            switch move {
            case .up, .down:
                let cards = TopicCards.order(records: contents.records, windows: snapshot.windows)
                switch TopicCards.step(card.id, move == .up ? .up : .down, in: cards) {
                case .to(let found): change = { try $0.move(card.id, to: found) }
                case .atEnd: throw TopicRequestError.cardAtEnd(card: card.label, up: move == .up, pinned: card.pinned)
                case .hidden: throw TopicRequestError.cardHidden("\(card.label) has no card in the Topics list.")
                }
            case .before(let ref):
                let anchor = try listID(ref, records: contents.records)
                change = { try $0.move(card.id, to: .before(anchor)) }
            case .after(let ref):
                let anchor = try listID(ref, records: contents.records)
                change = { try $0.move(card.id, to: .after(anchor)) }
            case .trade(let ref):
                let other = try listID(ref, records: contents.records)
                change = { try $0.trade(card.id, with: other) }
            }
            let moved = try store.write(locks: SessionLock.locks(in: snapshot.windows, records: contents.records), change)
            phase = .changesStarted
            try executor.run(moved.map { .tmux($0.setOption) }, client: client)
            switch card.id {
            case .topic(let id): return .changed(TopicChange(topicID: id))
            case .lock(let sessionID): return .changed(TopicChange(topicID: nil, session: SessionID(rawValue: sessionID)))
            }
        } catch {
            return .failed(failure(error, phase: phase))
        }
    }

    /// Choose In Play writes the order of the Topics list, as a card move does.
    private func chooseInPlay(_ cards: [TopicListRef], client: String?) -> EnvironmentResponse {
        var phase = TopicFailure.Phase.nothingChanged
        do {
            guard topics.inPlay != nil else { throw TopicRequestError.inPlayOff }
            let contents = try store.read()
            let snapshot = try server.snapshot()
            let chosen = try cards.map { try listID($0, records: contents.records) }
            let moved = try store.write(locks: SessionLock.locks(in: snapshot.windows, records: contents.records)) { try $0.chooseInPlay(chosen) }
            phase = .changesStarted
            try executor.run(moved.map { .tmux($0.setOption) }, client: client)
            return .changed(TopicChange(topicID: nil))
        } catch {
            return .failed(failure(error, phase: phase))
        }
    }

    /// Replace from Bench writes the order of the Topics list, as a card move does.
    private func replaceFromBench(_ request: EnvironmentRequest, with ref: TopicListRef, client: String?) -> EnvironmentResponse {
        var phase = TopicFailure.Phase.nothingChanged
        do {
            guard let inPlay = topics.inPlay else { throw TopicRequestError.inPlayOff }
            let contents = try store.read()
            let snapshot = try server.snapshot()
            let card = try self.card(request.target, caller: request.caller, records: contents.records, snapshot: snapshot, client: client)
            let benched = try listID(ref, records: contents.records)
            let moved = try store.write(locks: SessionLock.locks(in: snapshot.windows, records: contents.records)) {
                try $0.replaceFromBench(card.id, with: benched, inPlay: inPlay)
            }
            phase = .changesStarted
            try executor.run(moved.map { .tmux($0.setOption) }, client: client)
            switch benched {
            case .topic(let id): return .changed(TopicChange(topicID: id))
            case .lock(let sessionID): return .changed(TopicChange(topicID: nil, session: SessionID(rawValue: sessionID)))
            }
        } catch {
            return .failed(failure(error, phase: phase))
        }
    }

    /// One write of the Topic Unread keys, then one tmux option for each Agent. A nil `scope` is the whole Environment.
    private func markRead(_ request: EnvironmentRequest, _ change: ReadChange, scope: ReadScope?, client: String?) -> EnvironmentResponse {
        var phase = TopicFailure.Phase.nothingChanged
        do {
            let records = topicsAvailable ? try store.read().records : []
            let snapshot = try server.snapshot()
            let place = try scope.map { try readPlace($0, request, records: records, snapshot: snapshot, client: client) } ?? .environment
            var changed = ReadPlan.changes(change, in: place, records: records,
                                           agents: Agent.list(panes: snapshot.panes, windows: snapshot.windows, ordered: false),
                                           windows: snapshot.windows)
            if !changed.topicIDs.isEmpty {
                let ids = changed.topicIDs, unread = change == .unread
                let written = try store.write { transaction -> Set<String> in
                    var written: Set<String> = []
                    for record in transaction.records where ids.contains(record.id) && record.isUnread != unread {
                        try transaction.update(record.id) { $0.isUnread = unread }
                        written.insert(record.id)
                    }
                    return written
                }
                changed.topicIDs = ids.filter(written.contains)
                phase = .recordSaved
            }
            if !changed.paneIDs.isEmpty {
                if phase == .nothingChanged { phase = .changesStarted }
                try executor.run(changed.paneIDs.map { .tmux(AgentUnread.command(change == .unread, paneID: $0.rawValue)) }, client: client)
            }
            return .readChanged(changed)
        } catch {
            return .failed(failure(error, phase: phase))
        }
    }

    /// The place of `scope` that holds the target: the target itself when it is that kind, else the place of its Pane.
    /// A Settled Topic keeps its Unread mark in the Settled list, so a Topic named by ref is read whether it is open or not.
    private func readPlace(_ scope: ReadScope, _ request: EnvironmentRequest, records: [TopicRecord], snapshot: TmuxSnapshot,
                           client: String?) throws -> ReadPlan.Place {
        switch (scope, request.target) {
        case (.topic, .topic(let ref)?):
            return .topic(try ref.resolve(in: records, open: false).id)
        case (.topic, _):
            return .topic(try openTopic(request.target, caller: request.caller, records: records, snapshot: snapshot, client: client).id)
        case (.session, _):
            return .session(try sessionWindow(request.target, caller: request.caller, snapshot: snapshot, client: client).sessionID)
        case (.window, _), (.pane, _):
            guard let pane = paneRequest(request.target, caller: request.caller) else { throw TopicRequestError.noTarget }
            let source = try executor.pane(pane, in: snapshot, client: client).source
            return scope == .window ? .window(source.window.id) : .pane(source.paneID)
        }
    }

    private func listID(_ ref: TopicListRef, records: [TopicRecord]) throws -> TopicListID {
        switch ref {
        case .topic(let topic): return .topic(try topic.resolve(in: records).id)
        case .lock(let session): return .lock(sessionID: session.rawValue)
        }
    }

    /// The card that a request moves: the target's open Topic, else the target's Locked Session.
    private func card(_ target: EnvironmentTarget?, caller: TopicCaller?, records: [TopicRecord], snapshot: TmuxSnapshot,
                      client: String?) throws -> (id: TopicListID, label: String, pinned: Bool) {
        if case .topic(let ref)? = target {
            let topic = try ref.resolve(in: records)
            return (.topic(topic.id), "The Topic " + TopicSummary(record: topic).label, topic.isPinned)
        }
        let window = try sessionWindow(target, caller: caller, snapshot: snapshot, client: client)
        if let topic = records.first(where: { $0.id == window.topicID && $0.settledAt == nil }) {
            return (.topic(topic.id), "The Topic " + TopicSummary(record: topic).label, topic.isPinned)
        }
        guard SessionLock.locks(in: snapshot.windows, records: records).contains(where: { $0.sessionID == window.sessionID }) else {
            throw TopicRequestError.cardHidden("The Session \(window.sessionName) has no card in the Topics list. Lock it first: "
                                               + "muxify session lock --session \(window.sessionID).")
        }
        return (.lock(sessionID: window.sessionID), "The Locked Session " + window.sessionName, false)
    }

    /// Tags are one key of one record, so a Tag change also takes only the record lock.
    private func changeTags(_ request: EnvironmentRequest, _ change: TopicTagChange, client: String?) -> EnvironmentResponse {
        do {
            let records = try store.read().records
            let topic = try openTopic(request.target, caller: request.caller, records: records, snapshot: try server.snapshot(), client: client)
            try checkDefined(change, on: topic.tags)
            try store.write { try $0.changeTags(of: topic.id, change) }
            return .changed(TopicChange(topicID: topic.id))
        } catch {
            return .failed(failure(error, phase: .nothingChanged))
        }
    }

    /// The Topic Note is one key of one record, as Tags are.
    private func setNote(_ request: EnvironmentRequest, _ note: String?, client: String?) -> EnvironmentResponse {
        do {
            let records = try store.read().records
            let topic = try openTopic(request.target, caller: request.caller, records: records, snapshot: try server.snapshot(), client: client)
            try store.write { try $0.setNote(of: topic.id, note) }
            return .changed(TopicChange(topicID: topic.id))
        } catch {
            return .failed(failure(error, phase: .nothingChanged))
        }
    }

    /// Only the Tags in `topics.tags` can be added; a Tag the Config no longer defines can stay on its Topic.
    func checkDefined(_ change: TopicTagChange, on tags: Set<Tag>) throws {
        let undefined = topics.tags?.undefinedTags(added: change, to: tags) ?? change.applied(to: tags).subtracting(tags).sorted()
        guard undefined.isEmpty else { throw TopicRequestError.undefinedTags(undefined) }
    }
}
