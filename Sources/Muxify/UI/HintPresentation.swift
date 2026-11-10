import SwiftUI
import MuxifyCore

struct HintPresentation: Equatable {
    private var triggers: [QuickSwitchTarget: [KeyTrigger]] = [:]

    private var restKeys: [QuickSwitchTarget: String] = [:]
    private(set) var windowSlotReserved = false

    func restKey(for target: QuickSwitchTarget) -> String? { restKeys[target] }

    static let hidden = HintPresentation()
    private init() {}

    init(modifiers: KeyTrigger.Modifiers?, keybinds: Keybinds, targets: QuickSwitchTargets,
         sidebar: Bool, browser: Bool, terminal: Bool, config: Config.Hints = .init()) {
        windowSlotReserved = config.windows.always
        for action in ConfigAction.allCases {
            let target: QuickSwitchTarget
            if let selection = action.quickSwitchSelection, let selected = targets.target(for: selection) {
                target = selected
            } else if action == .focusTerminal {
                target = .terminal
            } else { continue }
            switch target {
            case .topic, .locked, .openPlace, .session, .window: if !sidebar { continue }
            case .tab: if !browser { continue }
            case .terminal: if !terminal { continue }
            }
            let surface: Config.Hints.Surface?
            let restModifiers: KeyTrigger.Modifiers
            switch target {
            case .topic, .locked, .openPlace, .session: surface = config.cards; restModifiers = .control
            case .window: surface = config.windows; restModifiers = .command
            case .tab: surface = config.tabs; restModifiers = .option
            case .terminal: surface = nil; restModifiers = []
            }
            if surface?.always == true,
               let trigger = keybinds.triggers[action]?.first(where: { $0.modifiers == restModifiers }) {
                restKeys[target] = KeyTrigger(modifiers: [], key: trigger.key).symbol
            }
            guard config.holdDelay != nil, surface?.hold ?? config.terminal.hold,
                  let modifiers, !modifiers.isEmpty else { continue }
            let matches = (keybinds.triggers[action] ?? []).filter { trigger in
                guard trigger.modifiers == modifiers else { return false }
                if target == .terminal {
                    guard case .character(let key) = trigger.key else { return false }
                    return "0123456789".contains(key)
                }
                return true
            }
            if !matches.isEmpty { triggers[target, default: []] += matches }
        }
    }

    subscript(_ target: QuickSwitchTarget) -> [KeyTrigger] { triggers[target] ?? [] }
}

private struct QuickSwitchHintsKey: EnvironmentKey {
    static let defaultValue = HintPresentation.hidden
}

extension EnvironmentValues {
    var quickSwitchHints: HintPresentation {
        get { self[QuickSwitchHintsKey.self] }
        set { self[QuickSwitchHintsKey.self] = newValue }
    }
}
