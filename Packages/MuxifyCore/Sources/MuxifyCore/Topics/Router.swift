import Foundation

public struct Router: Equatable {
    public typealias ReadNumber = Int
    public typealias IntentID = Int

    public struct WindowIntent: Equatable {
        public let id: IntentID
        public let target: WindowID
        public let from: Location?
        public let readsOnArrival: Bool
        public var finishedBefore: ReadNumber?
    }

    public enum Intent: Equatable {
        case window(WindowIntent)
        case request(SelectRequest, until: Date)
        case topic(TopicGroupID)
    }

    public enum CommandResult: Equatable { case success, failure }

    public enum Event {
        case go(Location, readsOnArrival: Bool = false)
        case attach(WindowID?, readsOnArrival: Bool = false)
        case request(SelectRequest, at: Date)
        case result(Location?, lastStartedRead: ReadNumber)
        case settled(next: TopicGroupID?)
        case commandFinished(IntentID, CommandResult, lastStartedRead: ReadNumber)
        case read(ReadNumber)
        /// The Topic records or the Open Places changed, with no change in tmux and so no read.
        case topicsChanged
        case serverChanged
    }

    public enum Effect: Equatable {
        case switchClient(WindowID, intent: IntentID)
        case attach(WindowID?, intent: IntentID)
        case enterRead(WindowID)
        case visit(Location)
        case requestTopic(TopicGroupID)
        /// The server has no Session of the user's: the user chooses the folder of the first one. Muxify starts none
        /// by itself.
        case chooseWhereToStart
    }

    public struct Facts {
        public var windows: [TmuxWindow]
        public var ownClientWindow: WindowID?
        public var records: [TopicRecord]
        public var entryWindows: [TopicGroupID: WindowID]
        /// The ids of the Open Places that hold an In Play place.
        public var openPlaces: Set<String>
        /// The ids of the Board Sessions, live or Dormant.
        public var boardSessions: Set<String>
        public var hasTerminal: Bool
        public var allowAttach: Bool
        public var rememberedWindow: WindowID?
        public var initialWindow: WindowID?
        public var now: Date

        public init(windows: [TmuxWindow] = [], ownClientWindow: WindowID? = nil,
                    records: [TopicRecord] = [], entryWindows: [TopicGroupID: WindowID] = [:],
                    openPlaces: Set<String> = [], boardSessions: Set<String> = [], hasTerminal: Bool = true, allowAttach: Bool = false,
                    rememberedWindow: WindowID? = nil, initialWindow: WindowID? = nil,
                    now: Date = Date()) {
            self.windows = windows
            self.ownClientWindow = ownClientWindow
            self.records = records
            self.entryWindows = entryWindows
            self.openPlaces = openPlaces
            self.boardSessions = boardSessions
            self.hasTerminal = hasTerminal
            self.allowAttach = allowAttach
            self.rememberedWindow = rememberedWindow
            self.initialWindow = initialWindow
            self.now = now
        }
    }

    public private(set) var location: Location?
    public private(set) var intent: Intent?
    private struct ClientCommand: Equatable {
        var target: WindowID?
        let readsOnArrival: Bool
        var finishedBefore: ReadNumber?
    }

    // A switch can still move the Client after a page replaces its Intent.
    private var clientCommands: [IntentID: ClientCommand] = [:]
    private var nextIntentID = 0
    private var lastClientWindow: WindowID?

    public init() {}

    public mutating func handle(_ event: Event, _ facts: Facts) -> [Effect] {
        switch event {
        case .go(let destination, let readsOnArrival):
            return go(destination, readsOnArrival: readsOnArrival, facts)
        case .attach(let target, let readsOnArrival):
            if let target {
                var unattached = facts
                unattached.hasTerminal = false
                return go(.window(target), readsOnArrival: readsOnArrival, unattached)
            }
            return [.attach(nil, intent: makeCommand(nil, readsOnArrival: false))]
        case .request(let request, let at):
            intent = .request(request, until: at.addingTimeInterval(5))
            if case .topic = request { return [] }
            return resolveRequest(facts) ?? []
        case .result(let destination, let lastStartedRead):
            guard let destination else { return [] }
            let from = location
            location = destination
            if case .window(let target) = destination {
                intent = .window(makeIntent(target, from: from, readsOnArrival: false, finishedBefore: lastStartedRead))
            } else {
                intent = nil
            }
            return [.visit(destination)]
        case .settled(let next):
            intent = next.map(Intent.topic)
            return []
        case .commandFinished(let id, let result, let lastStartedRead):
            guard var command = clientCommands[id], command.finishedBefore == nil else { return [] }
            var effects: [Effect] = []
            switch result {
            case .success:
                command.target = command.target ?? facts.ownClientWindow
                command.finishedBefore = lastStartedRead
                clientCommands[id] = command
                if command.readsOnArrival, let target = command.target { effects.append(.enterRead(target)) }
            case .failure:
                clientCommands[id] = nil
            }
            guard case .window(var pending) = intent, pending.id == id else { return effects }
            switch result {
            case .failure:
                location = pending.from
                intent = nil
            case .success:
                pending.finishedBefore = lastStartedRead
                intent = .window(pending)
            }
            return effects
        case .read(let number):
            return read(number, facts)
        case .topicsChanged:
            return leaveGonePage(facts) ?? []
        case .serverChanged:
            let serial = nextIntentID
            self = Router()
            nextIntentID = serial
            return []
        }
    }

    private mutating func read(_ number: ReadNumber, _ facts: Facts) -> [Effect] {
        let waitingForCommand = clientCommands.values.contains { $0.finishedBefore.map { number <= $0 } ?? true }
        let commandedWindow = clientCommands.max { $0.key < $1.key }?.value.target
        let observedCommands = waitingForCommand ? [] : Array(clientCommands.keys)
        defer {
            if !waitingForCommand { lastClientWindow = facts.ownClientWindow }
            for id in observedCommands { clientCommands[id] = nil }
        }
        if case .window(let pending) = intent,
           pending.finishedBefore.map({ number <= $0 }) ?? true {
            return attachIfNeeded(facts)
        }
        if case .topic(let group) = intent {
            intent = nil
            let destination = facts.entryWindows[group].map(Location.window)
                ?? .emptyTopic(group.page(facts))
            return go(destination, readsOnArrival: true, facts)
        }
        if case .request(_, let until) = intent {
            if let effects = resolveRequest(facts) { return effects }
            if facts.now > until { intent = nil }
            else { return attachIfNeeded(facts) }
        }
        // tmux has already moved the Client to a Window of its choosing: follow it, and pick none ourselves.
        if let selected = location?.windowID, !facts.windows.contains(where: { $0.id == selected.rawValue }) {
            intent = nil
            if let client = facts.ownClientWindow, facts.windows.contains(where: { $0.id == client.rawValue }) {
                location = .window(client)
                return [.visit(.window(client)), .enterRead(client)]
            }
            location = nil
        }
        if case .emptyTopic(let group) = location, group != .noTopic, intent == nil, let target = facts.entryWindows[group] {
            return go(.window(target), readsOnArrival: true, facts)
        }
        if let effects = leaveGonePage(facts) { return effects }
        if case .window = intent { intent = nil }
        var effects: [Effect] = []
        if intent == nil, !waitingForCommand, let client = facts.ownClientWindow,
           (location == nil || client != commandedWindow), client != lastClientWindow,
           facts.windows.contains(where: { $0.id == client.rawValue }) {
            let destination = Location.window(client)
            if location != destination {
                location = destination
                effects.append(.visit(destination))
            }
        }
        return effects + attachIfNeeded(facts)
    }

    /// The page's Topic or Board Session is gone, or its Open Place closed (a fill from elsewhere, or a lower
    /// `topics.in_play`): the Location goes to the Window that the Client shows, or to none. Nil while the page stays.
    private mutating func leaveGonePage(_ facts: Facts) -> [Effect]? {
        guard intent == nil else { return nil }
        switch location {
        case .emptyTopic(.topic(let topic))? where !facts.records.contains(where: { $0.id == topic }): break
        case .emptyTopic(.session(let id))? where !facts.boardSessions.contains(id): break
        case .openPlace(let place)? where !facts.openPlaces.contains(place): break
        default: return nil
        }
        let destination = facts.ownClientWindow.map(Location.window)
        location = destination
        return destination.map { [.visit($0)] } ?? []
    }

    private mutating func go(_ destination: Location, readsOnArrival: Bool, _ facts: Facts) -> [Effect] {
        let from = location
        location = destination
        guard case .window(let target) = destination else {
            intent = nil
            return [.visit(destination)]
        }
        let pending = makeIntent(target, from: from, readsOnArrival: readsOnArrival)
        intent = .window(pending)
        let command: Effect = facts.hasTerminal ? .switchClient(target, intent: pending.id) : .attach(target, intent: pending.id)
        return [.visit(destination), command]
    }

    private mutating func resolveRequest(_ facts: Facts) -> [Effect]? {
        guard facts.hasTerminal || facts.allowAttach, case .request(let request, _) = intent else { return nil }
        let target: TmuxWindow?
        switch request {
        case .window(let id): target = facts.windows.first { $0.id == id }
        case .session(let name):
            target = facts.windows.first { $0.sessionName == name && $0.isActive }
                ?? facts.windows.first { $0.sessionName == name }
        case .topic(let id):
            guard facts.records.contains(where: { $0.id == id && $0.settledAt == nil }) else { return nil }
            intent = nil
            return [.requestTopic(.topic(id))]
        }
        guard let target, let id = WindowID(rawValue: target.id) else { return nil }
        return go(.window(id), readsOnArrival: true, facts)
    }

    private mutating func attachIfNeeded(_ facts: Facts) -> [Effect] {
        guard !facts.hasTerminal, facts.allowAttach else { return [] }
        // A page shows in the Terminal's place, so it needs no Client.
        if let location, location.windowID == nil { return [] }
        if case .window(var pending) = intent {
            guard facts.windows.contains(where: { $0.id == pending.target.rawValue }) else { return [] }
            if pending.finishedBefore != nil {
                pending = makeIntent(pending.target, from: pending.from, readsOnArrival: pending.readsOnArrival)
                intent = .window(pending)
            }
            return [.attach(pending.target, intent: pending.id)]
        }
        let remembered = facts.rememberedWindow.flatMap { id in
            facts.windows.contains(where: { $0.id == id.rawValue }) ? id : nil
        }
        guard let target = remembered ?? facts.initialWindow else { return [.chooseWhereToStart] }
        if case .request = intent {
            location = .window(target)
            return [.visit(.window(target)), .attach(target, intent: makeCommand(target, readsOnArrival: false))]
        }
        return go(.window(target), readsOnArrival: false, facts)
    }

    private mutating func makeIntent(_ target: WindowID, from: Location?, readsOnArrival: Bool,
                                     finishedBefore: ReadNumber? = nil) -> WindowIntent {
        let id = makeCommand(target, readsOnArrival: readsOnArrival, finishedBefore: finishedBefore)
        return WindowIntent(id: id, target: target, from: from,
                            readsOnArrival: readsOnArrival, finishedBefore: finishedBefore)
    }

    private mutating func makeCommand(_ target: WindowID?, readsOnArrival: Bool,
                                      finishedBefore: ReadNumber? = nil) -> IntentID {
        nextIntentID += 1
        clientCommands[nextIntentID] = ClientCommand(target: target, readsOnArrival: readsOnArrival,
                                                    finishedBefore: finishedBefore)
        return nextIntentID
    }
}

private extension TopicGroupID {
    /// The page of a card with no Window: its own, as a Dormant Board Session's offers Reopen and Start Fresh, or No
    /// Topic's for a Board Session whose card is gone.
    func page(_ facts: Router.Facts) -> TopicGroupID {
        if case .session(let id) = self, !facts.boardSessions.contains(id) { return .noTopic }
        return self
    }
}
