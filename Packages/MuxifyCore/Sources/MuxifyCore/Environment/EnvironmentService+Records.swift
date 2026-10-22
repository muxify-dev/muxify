import Foundation

// The records lane: commands that take the record lock only. Each writes keys of Topic records, Agent options in tmux, or both.
extension EnvironmentService {
    func changeRecords(_ request: EnvironmentRequest, client: String?) -> EnvironmentResponse {
        switch request.command {
        case .snooze(let deadline, let topics): return snooze(request, topics, until: deadline, client: client)
        case .unsnooze(let topics): return snooze(request, topics, until: nil, client: client)
        case .tags(let change): return changeTags(request, change, client: client)
        case .pin: return pin(request, true, client: client)
        case .unpin: return pin(request, false, client: client)
        case .moveCard(let move): return moveCard(request, move, client: client)
        case .startZen(let deadline): return startZen(request, until: deadline, client: client)
        case .endZen: return endZen(client: client)
        case .markRead(let change, let scope): return markRead(request, change, scope: scope, client: client)
        case .markAllRead: return markRead(request, .read, scope: nil, client: client)
        default: preconditionFailure("\(request.command) is not in the records lane")
        }
    }

    /// A nil `deadline` is an Unsnooze. Every Topic resolves before the one write, so a bad ref changes nothing.
    private func snooze(_ request: EnvironmentRequest, _ topics: [TopicRef], until deadline: SnoozeDeadline?, client: String?) -> EnvironmentResponse {
        var phase = TopicFailure.Phase.nothingChanged
        do {
            if !topics.isEmpty, request.target != nil { throw TopicRequestError.targetAndTopics }
            let records = try store.read().records
            let resolved = topics.isEmpty
                ? [try openTopic(request.target, caller: request.caller, records: records, snapshot: try server.snapshot(), client: client)]
                : try topics.map { try $0.resolve(in: records) }
            var ids: [String] = []
            for topic in resolved where !ids.contains(topic.id) { ids.append(topic.id) }
            let locks = SessionLock.locks(in: try server.snapshot().windows, records: records)
            let (shortened, moved) = try store.write(locks: locks) { transaction -> ([String], [SessionLock]) in
                guard let deadline else {
                    let saves = try ids.map { id in
                        guard var record = transaction.records.first(where: { $0.id == id && $0.settledAt == nil }) else {
                            throw TopicRequestError.topicUnavailable(id)
                        }
                        record.snoozedUntil = nil
                        return record
                    }
                    return ([], try transaction.setSnoozes(saves, insertPosition: self.topics.insertPosition))
                }
                let set = SnoozeSet(ids, until: deadline, records: transaction.records)
                // A Topic that was Settled after the read has no save.
                if let settled = ids.first(where: { id in !set.saves.contains { $0.id == id } }) {
                    throw TopicRequestError.topicUnavailable(settled)
                }
                return (set.shortened, try transaction.setSnoozes(set.saves, insertPosition: self.topics.insertPosition))
            }
            phase = .changesStarted
            try executor.run(moved.map { .tmux($0.setOption) }, client: client)
            return .snoozeChanged(TopicSnoozeChange(topicIDs: ids, shortened: shortened))
        } catch {
            return .failed(failure(error, phase: phase))
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
            let placement: TopicPlacement
            switch move {
            case .up, .down:
                let cards = TopicCards.order(records: contents.records, windows: snapshot.windows, zen: contents.zen, now: Date())
                switch TopicCards.step(card.id, move == .up ? .up : .down, in: cards) {
                case .to(let found): placement = found
                case .atEnd: throw TopicRequestError.cardAtEnd(card: card.label, up: move == .up, pinned: card.pinned)
                case .hidden:
                    if case .lock = card.id { throw TopicRequestError.cardHidden("Zen is on, so the Topics list shows no card for \(card.label).") }
                    throw TopicRequestError.cardHidden("\(card.label) is Snoozed, so the Topics list shows no card for it.")
                }
            case .before(let ref): placement = .before(try listID(ref, records: contents.records))
            case .after(let ref): placement = .after(try listID(ref, records: contents.records))
            }
            let moved = try store.write(locks: SessionLock.locks(in: snapshot.windows, records: contents.records)) { try $0.move(card.id, to: placement) }
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

    /// One write: the Zen record goes down before the Snoozes, so a Topic that Zen Snoozed is always in it. Snoozing
    /// moves no card back, so no Lock changes.
    private func startZen(_ request: EnvironmentRequest, until deadline: SnoozeDeadline, client: String?) -> EnvironmentResponse {
        do {
            let records = try store.read().records
            let kept = try openTopic(request.target, caller: request.caller, records: records, snapshot: try server.snapshot(), client: client)
            let ids = try store.write { transaction -> [String] in
                guard transaction.zen == nil else { throw TopicRequestError.zenOn }
                guard transaction.records.contains(where: { $0.id == kept.id && $0.settledAt == nil }) else {
                    throw TopicRequestError.topicUnavailable(kept.id)
                }
                let (zen, saves) = ZenRecord.start(keeping: kept.id, until: deadline, records: transaction.records)
                transaction.zen = zen
                try transaction.setSnoozes(saves)
                return saves.map(\.id)
            }
            return .snoozeChanged(TopicSnoozeChange(topicIDs: ids))
        } catch {
            return .failed(failure(error, phase: .nothingChanged))
        }
    }

    /// The Topics that Zen Snoozed come back to the list and may renumber the Locks, which tmux keeps.
    private func endZen(client: String?) -> EnvironmentResponse {
        var phase = TopicFailure.Phase.nothingChanged
        do {
            let records = try store.read().records
            let locks = SessionLock.locks(in: try server.snapshot().windows, records: records)
            let (ids, moved) = try store.write(locks: locks) { try $0.endZen(insertPosition: self.topics.insertPosition) }
            phase = .changesStarted
            try executor.run(moved.map { .tmux($0.setOption) }, client: client)
            return .snoozeChanged(TopicSnoozeChange(topicIDs: ids))
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

    /// Only the Tags in `topics.tags` can be added; a Tag the Config no longer defines can stay on its Topic.
    func checkDefined(_ change: TopicTagChange, on tags: Set<Tag>) throws {
        let undefined = topics.tags?.undefinedTags(added: change, to: tags) ?? change.applied(to: tags).subtracting(tags).sorted()
        guard undefined.isEmpty else { throw TopicRequestError.undefinedTags(undefined) }
    }
}
