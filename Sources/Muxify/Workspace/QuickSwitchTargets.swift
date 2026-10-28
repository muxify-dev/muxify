import Foundation
import MuxifyCore

enum QuickSwitchSelection {
    case card(Int), window(Int), tab(Int)
}

extension ConfigAction {
    var quickSwitchSelection: QuickSwitchSelection? {
        switch self {
        case .selectCard1: .card(1)
        case .selectCard2: .card(2)
        case .selectCard3: .card(3)
        case .selectCard4: .card(4)
        case .selectCard5: .card(5)
        case .selectCard6: .card(6)
        case .selectCard7: .card(7)
        case .selectCard8: .card(8)
        case .selectCard9: .card(9)
        case .selectWindow1: .window(1)
        case .selectWindow2: .window(2)
        case .selectWindow3: .window(3)
        case .selectWindow4: .window(4)
        case .selectWindow5: .window(5)
        case .selectWindow6: .window(6)
        case .selectWindow7: .window(7)
        case .selectWindow8: .window(8)
        case .selectWindow9: .window(9)
        case .selectTab1: .tab(1)
        case .selectTab2: .tab(2)
        case .selectTab3: .tab(3)
        case .selectTab4: .tab(4)
        case .selectTab5: .tab(5)
        case .selectTab6: .tab(6)
        case .selectTab7: .tab(7)
        case .selectTab8: .tab(8)
        case .selectTab9: .tab(9)
        default: nil
        }
    }

    var step: (level: StepLevel, direction: StepDirection)? {
        switch self {
        case .selectNextWindow: (.window, .next)
        case .selectPrevWindow: (.window, .previous)
        case .selectNextTopicWindow: (.topicWindow, .next)
        case .selectPrevTopicWindow: (.topicWindow, .previous)
        case .selectNextSession: (.session, .next)
        case .selectPrevSession: (.session, .previous)
        case .selectNextTopic: (.topic, .next)
        case .selectPrevTopic: (.topic, .previous)
        default: nil
        }
    }
}

enum StepLevel {
    case window, topicWindow, session, topic
}

enum StepDirection {
    case next, previous
}

enum QuickSwitchTarget: Hashable {
    /// `locked` is a Locked Session's card in Topics mode, by Session ID.
    case topic(String), locked(String), session(String), window(String), tab(UUID), terminal

    var accessibilityID: String {
        switch self {
        case .topic(let id): "hint-topic-" + id
        case .locked(let id): "hint-locked-" + id
        case .session(let id): "hint-session-" + id
        case .window(let id): "hint-window-" + id
        case .tab(let id): "hint-tab-" + id.uuidString
        case .terminal: "hint-terminal"
        }
    }
}

struct QuickSwitchTargets {
    let cards: [QuickSwitchTarget]
    let windows: [QuickSwitchTarget]
    /// The Windows a Topic Window step goes through: the Active Topic's in Sidebar order in Topics mode, the
    /// Session's in Sessions mode.
    let topicWindows: [QuickSwitchTarget]
    let tabs: [QuickSwitchTarget]
    /// The Sessions a Session step goes through: every Session in Sessions mode, the Active Topic's in Topics mode.
    let sessions: [QuickSwitchTarget]
    /// The rows of the Topics list, Locked Sessions included, in either Sidebar mode.
    let topics: [QuickSwitchTarget]

    func target(for selection: QuickSwitchSelection) -> QuickSwitchTarget? {
        let targets: [QuickSwitchTarget]
        let position: Int
        switch selection {
        case .card(let value): targets = cards; position = value
        case .window(let value): targets = windows; position = value
        case .tab(let value): targets = tabs; position = value
        }
        guard (1...9).contains(position), position <= targets.count else { return nil }
        return targets[position - 1]
    }

    /// Wraps at both ends. Without `current` in the list, next starts at the first target and previous at the last.
    func step(_ level: StepLevel, _ direction: StepDirection, from current: QuickSwitchTarget?) -> QuickSwitchTarget? {
        let targets = switch level {
        case .window: windows
        case .topicWindow: topicWindows
        case .session: sessions
        case .topic: topics
        }
        guard !targets.isEmpty else { return nil }
        guard let index = current.flatMap(targets.firstIndex(of:)) else {
            return direction == .next ? targets.first : targets.last
        }
        let offset = direction == .next ? 1 : -1
        return targets[(index + offset + targets.count) % targets.count]
    }
}

extension QuickSwitchTargets {
    init(model: TopicsModel, sessions: [SessionGroup], windows: [TmuxWindow], tabIDs: [UUID]) {
        // No Topic Sessions get no number: the Topics list shows at most one of them, and only while it is open.
        // A Locked Session's card is numbered by its place among the Topics. A hidden Benched card gets no number,
        // and a Topic step skips it, so repeated steps do not go through the whole Bench.
        let cards = model.list.compactMap { $0.cardID?.quickSwitchTarget }
        let allSessions = sessions.map { QuickSwitchTarget.session($0.id) }
        let sessionWindows = windows.map { QuickSwitchTarget.window($0.id) }
        let shown = model.mode == .topics ? Self.sessions(of: model) : nil
        self.init(cards: model.mode == .topics ? cards : allSessions, windows: sessionWindows,
                  topicWindows: shown.map { $0.flatMap(\.windows).map { .window($0.id) } } ?? sessionWindows,
                  tabs: tabIDs.map { .tab($0) }, sessions: shown.map { $0.map { .session($0.id.session) } } ?? allSessions,
                  topics: cards)
    }

    /// The Sessions the Active Topic's card shows. No Topic has no card, so it gives its Sessions that have no
    /// Locked Session card of their own.
    private static func sessions(of model: TopicsModel) -> [TopicsModel.Session] {
        let shown: [TopicsModel.Session]
        switch model.activeTopic {
        case nil: shown = []
        case .noTopic:
            let carded = Set(model.rows.flatMap(\.sessions).map(\.id.session))
            shown = model.noTopicSessions.filter { !carded.contains($0.id.session) }
        case let active?:
            // A Settled Topic the user went to has its card in the Settled group, not in the rows.
            shown = (model.rows + model.groups.flatMap(\.topics)).first { $0.id == active }?.sessions ?? []
        }
        return shown.filter { !$0.windows.isEmpty }
    }
}

extension TopicGroupID {
    var quickSwitchTarget: QuickSwitchTarget? {
        switch self {
        case .topic(let id): .topic(id)
        case .locked(let id): .locked(id)
        case .noTopic: nil
        }
    }
}

extension WorkspaceStore {
    var quickSwitchWindows: [TmuxWindow] {
        guard let current = selectedWindow else { return [] }
        return windows.filter { $0.sessionID == current.sessionID }
    }

    var quickSwitchTargets: QuickSwitchTargets {
        QuickSwitchTargets(model: topics, sessions: sessions, windows: quickSwitchWindows,
                           tabIDs: currentBrowser?.tabs.map(\.id) ?? [])
    }

    var hintPresentation: HintPresentation {
        HintPresentation(modifiers: palette.isOpen ? nil : hintHold.visibleModifiers,
                         keybinds: config.keybinds, targets: quickSwitchTargets,
                         sidebar: sidebarShown && sessionsVisible,
                         browser: panelLayout.shows(.browser), terminal: surface != nil && panelLayout.shows(.terminal)
                            && !showsEmptyPage, config: config.hints)
    }

    func receiveHintInput(_ event: HintHoldState.Event) {
        hintHold.configure(delay: config.hints.holdDelay)
        hintHold.receive(event)
    }

    func quickSwitch(_ selection: QuickSwitchSelection) {
        if let target = quickSwitchTargets.target(for: selection) { go(to: target) }
    }

    /// Where a step goes from the selected Window, its Session or the Active Topic's row.
    func stepTarget(_ level: StepLevel, _ direction: StepDirection) -> QuickSwitchTarget? {
        let current: QuickSwitchTarget? = switch level {
        case .window, .topicWindow: selectedWindow.map { .window($0.id) }
        case .session: selectedWindow.map { .session($0.sessionID) }
        case .topic: topics.activeTopic?.quickSwitchTarget
        }
        return quickSwitchTargets.step(level, direction, from: current)
    }

    func step(_ level: StepLevel, _ direction: StepDirection) {
        if let target = stepTarget(level, direction) { go(to: target) }
    }

    private func go(to target: QuickSwitchTarget) {
        switch target {
        case .topic(let id): goToTopic(.topic(id))
        case .locked(let id): goToTopic(.locked(id))
        case .session(let id): goToSession(id)
        case .window(let id):
            if let window = windows.first(where: { $0.id == id }) { select(window) }
        case .tab(let id):
            if let browser = currentBrowser, let tab = browser.tabs.first(where: { $0.id == id }) {
                browser.jumpTo(tab)
            }
        case .terminal: focus(.terminal)
        }
    }
}
