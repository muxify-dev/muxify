import Foundation

// The records lane: commands that need no plan. Each writes keys of Topic records and Locks, Agent options in tmux, or
// both.
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
        case .makeGuest: return guest(request, client: client)
        case .benchTopic: return bench(request, client: client)
        case .fillOpenPlace(let place): return fillOpenPlace(request, place: place, client: client)
        case .markRead(let change, let scope): return markRead(request, change, scope: scope, client: client)
        case .markAllRead: return markRead(request, .read, scope: nil, client: client)
        default: preconditionFailure("\(request.command) is not in the records lane")
        }
    }

    /// Pin and Unpin move the card among the Topics, with the Guest Sessions in the same order.
    private func pin(_ request: EnvironmentRequest, _ pinned: Bool, client: String?) -> EnvironmentResponse {
        do {
            let records = try store.read().records
            let topic = try openTopic(request.target, caller: request.caller, records: records, snapshot: try server.snapshot(), client: client)
            if topic.isPinned == pinned { return .changed(TopicChange(topicID: topic.id)) }
            try store.write { try $0.pin(topic.id, pinned) }
            return .changed(TopicChange(topicID: topic.id))
        } catch {
            return .failed(failure(error, phase: .nothingChanged))
        }
    }

    /// A card move writes the order of the Topics list. Up on a No Topic Session that is not a Guest makes it one.
    func moveCard(_ request: EnvironmentRequest, _ move: CardMove, client: String?) -> EnvironmentResponse {
        var phase = TopicFailure.Phase.nothingChanged
        do {
            let contents = try store.read()
            let snapshot = try server.snapshot()
            let stepping = move == .up || move == .down
            let card = try self.card(request.target, caller: request.caller, contents: contents, snapshot: snapshot,
                                     client: client, allowUnlockedSession: stepping)
            let change: (inout TopicTransaction) throws -> Void
            switch move {
            case .up, .down:
                let cards = TopicCards.order(records: contents.records, locks: contents.locks, openPlaces: contents.openPlaces)
                let step: TopicCards.Step = move == .up ? .up : .down
                var outcome = TopicCards.step(card.id, step, in: cards, inPlay: topics.inPlay)
                // The No Topic Session that is not a Guest has no card, which `card` let through for this step.
                if outcome == .hidden, card.unlocked != nil { outcome = TopicCards.stepUnlockedSession(step) }
                switch outcome {
                case .atEnd: throw TopicRequestError.cardAtEnd(card: card.label, up: move == .up, pinned: card.pinned)
                case .hidden:
                    if let window = card.unlocked { throw TopicRequestError.cardHidden(Self.makeGuestFirst(window)) }
                    throw TopicRequestError.cardHidden("\(card.label) has no card in the Topics list.")
                case .makeGuest:
                    if let window = card.unlocked {
                        try makeGuest(window, snapshot: snapshot, client: client, phase: &phase)
                        return .changed(card.change)
                    }
                    change = { try $0.apply(outcome, to: card.id) }
                case .reorder, .toGuests, .fill, .trade, .takePlace, .bench, .refused:
                    change = { try $0.apply(outcome, to: card.id) }
                }
            case .before(let ref):
                let anchor = try listID(ref, contents: contents, snapshot: snapshot)
                change = { try $0.move(card.id, to: .before(anchor)) }
            case .after(let ref):
                let anchor = try listID(ref, contents: contents, snapshot: snapshot)
                change = { try $0.move(card.id, to: .after(anchor)) }
            case .trade(let ref):
                let other = try listID(ref, contents: contents, snapshot: snapshot)
                change = { try $0.trade(card.id, with: other) }
            }
            try store.write(change)
            return .changed(card.change)
        } catch {
            return .failed(failure(error, phase: phase))
        }
    }

    /// Choose In Play writes the order of the Topics list, as a card move does.
    private func chooseInPlay(_ cards: [TopicListRef], client: String?) -> EnvironmentResponse {
        do {
            let contents = try store.read()
            let snapshot = try server.snapshot()
            let chosen = try cards.map { try listID($0, contents: contents, snapshot: snapshot) }
            try store.write { try $0.chooseInPlay(chosen, inPlay: topics.inPlay) }
            return .changed(TopicChange(topicID: nil))
        } catch {
            return .failed(failure(error, phase: .nothingChanged))
        }
    }

    /// Replace from Bench writes the order of the Topics list, as a card move does.
    private func replaceFromBench(_ request: EnvironmentRequest, with ref: TopicListRef, client: String?) -> EnvironmentResponse {
        do {
            let contents = try store.read()
            let snapshot = try server.snapshot()
            let card = try self.card(request.target, caller: request.caller, contents: contents, snapshot: snapshot, client: client)
            let benched = try listID(ref, contents: contents, snapshot: snapshot)
            try store.write { try $0.replaceFromBench(card.id, with: benched, inPlay: topics.inPlay) }
            return .changed(benched.change(in: contents, snapshot: snapshot))
        } catch {
            return .failed(failure(error, phase: .nothingChanged))
        }
    }

    /// Make a Guest writes the order of the Topics list and the Topic's Guest mark. A No Topic Session becomes a Guest
    /// through its new Lock. A Guest does not change.
    private func guest(_ request: EnvironmentRequest, client: String?) -> EnvironmentResponse {
        var phase = TopicFailure.Phase.nothingChanged
        do {
            let contents = try store.read()
            let snapshot = try server.snapshot()
            let card = try self.card(request.target, caller: request.caller, contents: contents, snapshot: snapshot, client: client,
                                     allowUnlockedSession: true)
            if let window = card.unlocked {
                try makeGuest(window, snapshot: snapshot, client: client, phase: &phase)
            } else if case .topic(let id) = card.id, let topic = contents.records.first(where: { $0.id == id }), topic.isGuest, !topic.isPinned {
                return .changed(card.change)
            } else {
                try store.write { try $0.apply(.makeGuest, to: card.id) }
            }
            return .changed(card.change)
        } catch {
            return .failed(failure(error, phase: phase))
        }
    }

    /// Make a Guest of the No Topic Session of `window`: the Session gets its new Lock's id in `@muxify_session_id`
    /// first, so a live Session never shows its own Lock as Dormant, then the Lock goes to the end of the Guests.
    private func makeGuest(_ window: TmuxWindow, snapshot: TmuxSnapshot, client: String?, phase: inout TopicFailure.Phase) throws {
        let lock = SessionLock(session: window, order: .nan, snapshot: snapshot)
        try executor.run([.tmux(["set-option", "-t", window.sessionID, "@muxify_session_id", lock.id])], client: client)
        phase = .changesStarted
        try store.write { $0.lock(lock) }
    }

    /// Bench writes the order of the Topics list, the Topic's Guest mark and the Open Places. Bench of a Guest Session,
    /// live or Dormant, ends its Lock, and a No Topic Session that is not a Guest does not change.
    private func bench(_ request: EnvironmentRequest, client: String?) -> EnvironmentResponse {
        cardChange(request, client: client, allowUnlockedSession: true) { card in
            card.unlocked != nil ? nil : { try $0.apply(.bench, to: card.id) }
        }
    }

    private func fillOpenPlace(_ request: EnvironmentRequest, place: Int, client: String?) -> EnvironmentResponse {
        let inPlay = topics.inPlay
        return cardChange(request, client: client) { card in
            { transaction in
                guard case .topic(let topic) = card.id else { throw TopicOrder.Failure.guestSession }
                let places = TopicOrder.cut(transaction.entries, inPlay: inPlay).places
                guard places.indices.contains(place - 1), case .openPlace(let open) = places[place - 1] else {
                    throw TopicOrder.Failure.notOpenPlace
                }
                try transaction.fillOpenPlace(open.id, with: topic, inPlay: inPlay)
            }
        }
    }

    /// A change of the target's card: one write of the Topics list. `change` gives nil when the card is already as the
    /// request asks.
    private func cardChange(_ request: EnvironmentRequest, client: String?, allowUnlockedSession: Bool = false,
                            _ change: (RequestCard) -> ((inout TopicTransaction) throws -> Void)?) -> EnvironmentResponse {
        do {
            let contents = try store.read()
            let snapshot = try server.snapshot()
            let card = try self.card(request.target, caller: request.caller, contents: contents, snapshot: snapshot, client: client,
                                     allowUnlockedSession: allowUnlockedSession)
            guard let write = change(card) else { return .changed(card.change) }
            try store.write(write)
            return .changed(card.change)
        } catch {
            return .failed(failure(error, phase: .nothingChanged))
        }
    }

    /// Gathers each Guest Session that an older Muxify kept among the Topics into the Guests. The host calls it at
    /// launch. A list that is already in the three sections does not change. Nil when it succeeded.
    public func gatherGuests(client: String? = nil) -> TopicFailure? {
        do {
            try store.write { $0.gatherGuests(inPlay: topics.inPlay) }
            return nil
        } catch {
            return failure(error, phase: .nothingChanged)
        }
    }

    /// One write of the Topic Unread keys, then one tmux option for each Agent. A nil `scope` is the whole Environment.
    private func markRead(_ request: EnvironmentRequest, _ change: ReadChange, scope: ReadScope?, client: String?) -> EnvironmentResponse {
        var phase = TopicFailure.Phase.nothingChanged
        do {
            let records = try store.read().records
            let snapshot = try server.snapshot()
            let place = try scope.map { try readPlace($0, request, records: records, snapshot: snapshot, client: client) } ?? .environment
            let agents = scope == .topicMark ? [] : Agent.list(panes: snapshot.panes, windows: snapshot.windows, ordered: false)
            var changed = ReadPlan.changes(change, in: place, records: records, agents: agents, windows: snapshot.windows)
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
        case (.topic, .topic(let ref)?), (.topicMark, .topic(let ref)?):
            return .topic(try ref.resolve(in: records, open: false).id)
        case (.topic, _), (.topicMark, _):
            return .topic(try openTopic(request.target, caller: request.caller, records: records, snapshot: snapshot, client: client).id)
        case (.session, _):
            return .session(try sessionWindow(request.target, caller: request.caller, snapshot: snapshot, client: client).sessionID)
        case (.window, _), (.pane, _):
            guard let pane = paneRequest(request.target, caller: request.caller) else { throw TopicRequestError.noTarget }
            let source = try executor.pane(pane, in: snapshot, client: client).source
            return scope == .window ? .window(source.window.id) : .pane(source.paneID)
        }
    }

    /// A card on the wire as the Topics list names it. A live Guest Session named by its tmux id is its Lock's card; a
    /// Session that has no Lock names no card, and the change that takes it fails as for a card that is gone.
    private func listID(_ ref: TopicListRef, contents: TopicContents, snapshot: TmuxSnapshot) throws -> TopicListID {
        switch ref {
        case .topic(let topic): return .topic(try topic.resolve(in: contents.records).id)
        case .lock(let session): return .lock(liveLock(of: session.rawValue, contents: contents, snapshot: snapshot)?.id ?? session.rawValue)
        case .guestSession(let id): return .lock(id)
        case .openPlace(let id): return .openPlace(id)
        }
    }

    private static func makeGuestFirst(_ session: TmuxWindow) -> String {
        "The Session \(session.sessionName) has no card in the Topics list. Make it a Guest first: muxify topic make-guest --session \(session.sessionID)."
    }

    /// The card that a request acts on. `unlocked` is set when the target is a No Topic Session that is not a Guest and
    /// the request may make it one: it has no card yet, and `id` is the id that its Lock would get.
    struct RequestCard {
        let id: TopicListID
        let label: String
        let pinned: Bool
        /// A Guest Session's live Session, if any.
        let session: String?
        let unlocked: TmuxWindow?

        /// What a request that changed this card changed: its Topic, or its Guest Session.
        var change: TopicChange {
            if case .topic(let id) = self.id { return TopicChange(topicID: id) }
            return TopicChange(topicID: nil, session: session.flatMap(SessionID.init(rawValue:)))
        }
    }

    /// The card that a request moves: the target's open Topic, else the target's Guest Session, live or Dormant. With
    /// `allowUnlockedSession`, a No Topic Session that is not a Guest answers as the card its Lock would have, for the
    /// change that makes it a Guest.
    private func card(_ target: EnvironmentTarget?, caller: TopicCaller?, contents: TopicContents, snapshot: TmuxSnapshot,
                      client: String?, allowUnlockedSession: Bool = false) throws -> RequestCard {
        let records = contents.records
        if case .topic(let ref)? = target {
            let topic = try ref.resolve(in: records)
            return RequestCard(id: .topic(topic.id), label: "The Topic " + TopicLabels(records).label(of: topic), pinned: topic.isPinned,
                               session: nil, unlocked: nil)
        }
        if case .guestSession(let id)? = target {
            guard let lock = contents.locks.first(where: { $0.id == id }) else { throw TopicRequestError.guestSessionUnavailable(id) }
            let live = lock.windows(in: snapshot.windows, open: records.openTopicIDs).first
            return RequestCard(id: .lock(id), label: "The Guest Session " + (live?.sessionName ?? lock.name), pinned: false,
                               session: live?.sessionID, unlocked: nil)
        }
        let window = try sessionWindow(target, caller: caller, snapshot: snapshot, client: client)
        if let topic = records.first(where: { $0.id == window.topicID && $0.settledAt == nil }) {
            return RequestCard(id: .topic(topic.id), label: "The Topic " + TopicLabels(records).label(of: topic), pinned: topic.isPinned,
                               session: nil, unlocked: nil)
        }
        guard let lock = liveLock(of: window.sessionID, contents: contents, snapshot: snapshot) else {
            guard allowUnlockedSession else { throw TopicRequestError.cardHidden(Self.makeGuestFirst(window)) }
            return RequestCard(id: .lock(window.sessionRecordID), label: "The Session " + window.sessionName, pinned: false,
                               session: window.sessionID, unlocked: window)
        }
        return RequestCard(id: .lock(lock.id), label: "The Guest Session " + window.sessionName, pinned: false, session: window.sessionID,
                           unlocked: nil)
    }

    /// The Lock of the live Session `session`, when that Session is a Guest Session.
    private func liveLock(of session: String, contents: TopicContents, snapshot: TmuxSnapshot) -> SessionLock? {
        let open = contents.records.openTopicIDs
        return contents.locks.first { $0.windows(in: snapshot.windows, open: open).first?.sessionID == session }
    }

    /// Tags are one column of one record, so a Tag change writes only that column.
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

private extension TopicListID {
    /// What a request that moved this card changed: its Topic, or its Guest Session's live Session.
    func change(in contents: TopicContents, snapshot: TmuxSnapshot) -> TopicChange {
        switch self {
        case .topic(let id): return TopicChange(topicID: id)
        case .lock(let id):
            let session = contents.locks.first { $0.id == id }?.windows(in: snapshot.windows, open: contents.records.openTopicIDs).first
            return TopicChange(topicID: nil, session: session.flatMap { SessionID(rawValue: $0.sessionID) })
        case .openPlace: return TopicChange(topicID: nil)
        }
    }
}
