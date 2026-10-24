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
        case request(SelectRequest, at: Date)
        case result(Location?, lastStartedRead: ReadNumber)
        case settled(next: TopicGroupID?)
        case commandFinished(IntentID, CommandResult, lastStartedRead: ReadNumber)
        case read(ReadNumber)
        case serverChanged
    }

    public enum Effect: Equatable {
        case switchClient(WindowID, intent: IntentID)
        case attach(WindowID?, intent: IntentID?)
        case enterRead(WindowID)
        case visit(Location)
        case requestTopic(TopicGroupID)
    }

    public struct Facts {
        public var windows: [TmuxWindow]
        public var ownClientWindow: WindowID?
        public var records: [TopicRecord]
        public var entryWindows: [TopicGroupID: WindowID]
        public var hasTerminal: Bool
        public var allowAttach: Bool
        public var rememberedWindow: WindowID?
        public var initialWindow: WindowID?
        public var now: Date

        public init(windows: [TmuxWindow] = [], ownClientWindow: WindowID? = nil,
                    records: [TopicRecord] = [], entryWindows: [TopicGroupID: WindowID] = [:],
                    hasTerminal: Bool = true, allowAttach: Bool = false,
                    rememberedWindow: WindowID? = nil, initialWindow: WindowID? = nil,
                    now: Date = Date()) {
            self.windows = windows
            self.ownClientWindow = ownClientWindow
            self.records = records
            self.entryWindows = entryWindows
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
        let target: WindowID
        var finishedBefore: ReadNumber?
    }

    // A switch can still move the Client after a page replaces its Intent.
    private var clientCommands: [IntentID: ClientCommand] = [:]
    private var nextIntentID = 0
    private var previousWindow: WindowID?
    private var lastWindow: WindowID?
    private var lastClientWindow: WindowID?
    private var lastInventory: [TmuxWindow] = []

    public init() {}

    public mutating func handle(_ event: Event, _ facts: Facts) -> [Effect] {
        switch event {
        case .go(let destination, let readsOnArrival):
            return go(destination, readsOnArrival: readsOnArrival, facts)
        case .request(let request, let at):
            intent = .request(request, until: at.addingTimeInterval(5))
            if case .topic = request { return [] }
            return resolveRequest(facts) ?? []
        case .result(let destination, let lastStartedRead):
            guard let destination else { return [] }
            let from = location
            setLocation(destination, facts)
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
            switch result {
            case .success: clientCommands[id]?.finishedBefore = lastStartedRead
            case .failure: clientCommands[id] = nil
            }
            guard case .window(var pending) = intent, pending.id == id else { return [] }
            switch result {
            case .failure:
                setLocation(pending.from, facts)
                intent = nil
                return []
            case .success:
                pending.finishedBefore = lastStartedRead
                intent = .window(pending)
                return pending.readsOnArrival ? [.enterRead(pending.target)] : []
            }
        case .read(let number):
            return read(number, facts)
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
            rememberInventory(facts)
            return attachIfNeeded(facts)
        }
        if case .topic(let group) = intent {
            intent = nil
            let destination = facts.entryWindows[group].map(Location.window)
                ?? .emptyTopic(group.pageGroup)
            return go(destination, readsOnArrival: false, facts)
        }
        if case .request(_, let until) = intent {
            if let effects = resolveRequest(facts) { return effects }
            if facts.now > until { intent = nil }
            else { return attachIfNeeded(facts) }
        }
        if let selected = location?.windowID, !facts.windows.contains(where: { $0.id == selected.rawValue }) {
            intent = nil
            if let fallback = fallback(in: facts.windows) {
                return go(.window(fallback), readsOnArrival: false, facts)
            }
            location = nil
            previousWindow = nil
            lastWindow = nil
            lastInventory = []
        }
        rememberInventory(facts)
        if case .emptyTopic(.topic(let topic)) = location, intent == nil {
            if let target = facts.entryWindows[.topic(topic)] {
                return go(.window(target), readsOnArrival: false, facts)
            }
            if !facts.records.contains(where: { $0.id == topic }) {
                let destination = facts.ownClientWindow.map(Location.window)
                setLocation(destination, facts)
                return destination.map { [.visit($0)] } ?? []
            }
        }
        if case .window = intent { intent = nil }
        var effects: [Effect] = []
        if intent == nil, !waitingForCommand, let client = facts.ownClientWindow,
           client != commandedWindow, client != lastClientWindow,
           facts.windows.contains(where: { $0.id == client.rawValue }) {
            let destination = Location.window(client)
            if location != destination {
                setLocation(destination, facts)
                effects.append(.visit(destination))
            }
        }
        return effects + attachIfNeeded(facts)
    }

    private mutating func go(_ destination: Location, readsOnArrival: Bool, _ facts: Facts) -> [Effect] {
        let from = location
        setLocation(destination, facts)
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
        return go(.window(id), readsOnArrival: false, facts)
    }

    private mutating func attachIfNeeded(_ facts: Facts) -> [Effect] {
        guard !facts.hasTerminal, facts.allowAttach else { return [] }
        if case .emptyTopic = location { return [] }
        if case .window(let pending) = intent {
            guard facts.windows.contains(where: { $0.id == pending.target.rawValue }) else { return [] }
            return [.attach(pending.target, intent: pending.id)]
        }
        let remembered = facts.rememberedWindow.flatMap { id in
            facts.windows.contains(where: { $0.id == id.rawValue }) ? id : nil
        }
        guard let target = remembered ?? facts.initialWindow else { return [.attach(nil, intent: nil)] }
        if case .request = intent {
            setLocation(.window(target), facts)
            return [.visit(.window(target)), .attach(target, intent: nil)]
        }
        return go(.window(target), readsOnArrival: false, facts)
    }

    private mutating func makeIntent(_ target: WindowID, from: Location?, readsOnArrival: Bool,
                                     finishedBefore: ReadNumber? = nil) -> WindowIntent {
        nextIntentID += 1
        clientCommands[nextIntentID] = ClientCommand(target: target, finishedBefore: finishedBefore)
        return WindowIntent(id: nextIntentID, target: target, from: from,
                            readsOnArrival: readsOnArrival, finishedBefore: finishedBefore)
    }

    private mutating func setLocation(_ destination: Location?, _ facts: Facts) {
        location = destination
        if let window = destination?.windowID, window != lastWindow {
            previousWindow = lastWindow
            lastWindow = window
        }
        rememberInventory(facts)
    }

    private mutating func rememberInventory(_ facts: Facts) {
        if let selected = location?.windowID, facts.windows.contains(where: { $0.id == selected.rawValue }) {
            lastInventory = facts.windows
        }
    }

    private func fallback(in windows: [TmuxWindow]) -> WindowID? {
        if let closed = lastInventory.first(where: { $0.id == location?.windowID?.rawValue }) {
            let siblings = lastInventory.filter { $0.sessionID == closed.sessionID }.map(\.id)
            if let index = siblings.firstIndex(of: closed.id) {
                for id in siblings[..<index].reversed() + siblings[(index + 1)...] {
                    if windows.contains(where: { $0.id == id }), let target = WindowID(rawValue: id) { return target }
                }
            }
        }
        return windows.first(where: { $0.id == previousWindow?.rawValue }).flatMap { WindowID(rawValue: $0.id) }
            ?? windows.first.flatMap { WindowID(rawValue: $0.id) }
    }
}

private extension TopicGroupID {
    var pageGroup: TopicGroupID {
        if case .locked = self { return .noTopic }
        return self
    }
}
