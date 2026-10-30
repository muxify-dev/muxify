/// What a keybinding can do, with its default triggers.
public protocol KeybindAction: CaseIterable, Hashable, RawRepresentable where RawValue == String {
    /// The defaults as the user spells them, so the template can show them.
    static var defaultSpelling: KeyValuePairs<Self, [String]> { get }
    static var defaultTriggers: [Self: [KeyTrigger]] { get }
    /// The side that must have Focus for the keybind to act, or nil when it
    /// acts whatever has Focus.
    var requiredFocus: PanelLayout.Side? { get }
}

extension KeybindAction {
    static func parse(_ spelling: KeyValuePairs<Self, [String]>) -> [Self: [KeyTrigger]] {
        Dictionary(uniqueKeysWithValues: spelling.map { action, spellings in (action, spellings.map { try! KeyTrigger($0) }) })
    }

    public var requiredFocus: PanelLayout.Side? { nil }

    /// Two actions can share a trigger when no Focus has both acting on it:
    /// one acts only while one side has Focus, and the other acts only on the
    /// other side or everywhere else.
    public func canShareTrigger(with other: Self) -> Bool {
        requiredFocus != other.requiredFocus
    }

    /// Whether the user's `trigger` for this action takes the same default
    /// trigger from `other`. It does when the two cannot share it. A trigger
    /// new to an action that acts everywhere takes it from every default, so
    /// a default for one side does not hide it there. Restating a default
    /// keeps the defaults that share it.
    func takesDefault(_ trigger: KeyTrigger, from other: Self) -> Bool {
        !canShareTrigger(with: other) || (requiredFocus == nil && !Self.defaultTriggers[self, default: []].contains(trigger))
    }
}

/// What a Muxify keybind can do, anywhere in an App Window.
public enum ConfigAction: String, KeybindAction {
    case newAppWindow = "new_app_window"
    case newTopic = "new_topic"
    case movePane = "move_pane"
    case moveWindow = "move_window"
    case moveSession = "move_session"
    case addSessionToTopic = "add_session_to_topic"
    case settleTopic = "settle_topic"
    case removeSessionFromTopic = "remove_session_from_topic"
    case forgetTopic = "forget_topic"
    case renameTopic = "rename_topic"
    case setTopicNote = "set_topic_note"
    case toggleLock = "toggle_lock"
    case moveTopicUp = "move_topic_up"
    case moveTopicDown = "move_topic_down"
    case togglePinTopic = "toggle_pin_topic"
    case markRead = "mark_read"
    case markUnread = "mark_unread"
    case markAllRead = "mark_all_read"
    case toggleSidebar = "toggle_sidebar"
    case toggleBench = "toggle_bench"
    case chooseInPlay = "choose_in_play"
    case replaceFromBench = "replace_from_bench"
    case toggleTerminal = "toggle_terminal"
    case toggleBrowser = "toggle_browser"
    case toggleGitView = "toggle_git_view"
    case toggleMaximize = "toggle_maximize"
    case toggleMaximizeTerminal = "toggle_maximize_terminal"
    case toggleMaximizeBrowser = "toggle_maximize_browser"
    case focusTerminal = "focus_terminal"
    case focusBrowser = "focus_browser"
    case toggleFocus = "toggle_focus"
    case toggleZoomPane = "toggle_zoom_pane"
    case resizePaneLeft = "resize_pane_left"
    case resizePaneRight = "resize_pane_right"
    case resizePaneUp = "resize_pane_up"
    case resizePaneDown = "resize_pane_down"
    case findInPane = "find_in_pane"
    case findInPage = "find_in_page"
    case selectNextTab = "select_next_tab"
    case selectPrevTab = "select_prev_tab"
    case browserBack = "browser_back"
    case browserForward = "browser_forward"
    case closeTab = "close_tab"
    case reopenClosedTab = "reopen_closed_tab"
    case selectCard1 = "select_card_1"
    case selectCard2 = "select_card_2"
    case selectCard3 = "select_card_3"
    case selectCard4 = "select_card_4"
    case selectCard5 = "select_card_5"
    case selectCard6 = "select_card_6"
    case selectCard7 = "select_card_7"
    case selectCard8 = "select_card_8"
    case selectCard9 = "select_card_9"
    case selectTab1 = "select_tab_1"
    case selectTab2 = "select_tab_2"
    case selectTab3 = "select_tab_3"
    case selectTab4 = "select_tab_4"
    case selectTab5 = "select_tab_5"
    case selectTab6 = "select_tab_6"
    case selectTab7 = "select_tab_7"
    case selectTab8 = "select_tab_8"
    case selectTab9 = "select_tab_9"
    case selectWindow1 = "select_window_1"
    case selectWindow2 = "select_window_2"
    case selectWindow3 = "select_window_3"
    case selectWindow4 = "select_window_4"
    case selectWindow5 = "select_window_5"
    case selectWindow6 = "select_window_6"
    case selectWindow7 = "select_window_7"
    case selectWindow8 = "select_window_8"
    case selectWindow9 = "select_window_9"
    case selectNextWindow = "select_next_window"
    case selectPrevWindow = "select_prev_window"
    case selectNextTopicWindow = "select_next_topic_window"
    case selectPrevTopicWindow = "select_prev_topic_window"
    case selectNextSession = "select_next_session"
    case selectPrevSession = "select_prev_session"
    case selectNextTopic = "select_next_topic"
    case selectPrevTopic = "select_prev_topic"

    public static let defaultSpelling: KeyValuePairs<ConfigAction, [String]> = [
        .newAppWindow: ["cmd+shift+n"],
        .newTopic: ["cmd+n"],
        .movePane: ["cmd+shift+t"],
        .moveWindow: [],
        .moveSession: ["cmd+shift+m"],
        .addSessionToTopic: ["cmd+shift+a"],
        .settleTopic: [],
        .removeSessionFromTopic: [],
        .forgetTopic: [],
        .renameTopic: [],
        .setTopicNote: [],
        .toggleLock: [],
        .moveTopicUp: ["alt+cmd+up"],
        .moveTopicDown: ["alt+cmd+down"],
        .togglePinTopic: [],
        .markRead: ["cmd+shift+r"],
        .markUnread: ["cmd+shift+u"],
        .markAllRead: [],
        .toggleSidebar: ["cmd+s", "ctrl+cmd+s"],
        .toggleBench: ["shift+cmd+s"],
        .chooseInPlay: ["shift+alt+cmd+s"],
        .replaceFromBench: ["alt+cmd+s"],
        .toggleTerminal: ["cmd+j"],
        .toggleBrowser: ["cmd+b"],
        .toggleGitView: ["cmd+g"],
        .toggleMaximize: ["shift+cmd+enter"],
        .toggleMaximizeTerminal: ["alt+cmd+j"],
        .toggleMaximizeBrowser: ["alt+cmd+b"],
        .focusTerminal: ["cmd+shift+j", "ctrl+backquote", "ctrl+0", "alt+0"],
        .focusBrowser: ["cmd+shift+b"],
        .toggleFocus: ["cmd+0"],
        .toggleZoomPane: ["cmd+m"],
        .resizePaneLeft: [],
        .resizePaneRight: [],
        .resizePaneUp: [],
        .resizePaneDown: [],
        .findInPane: ["cmd+f"],
        .findInPage: ["cmd+f"],
        .selectNextTab: ["cmd+shift+right_bracket", "ctrl+tab"],
        .selectPrevTab: ["cmd+shift+left_bracket", "ctrl+shift+tab"],
        .browserBack: ["cmd+left_bracket"],
        .browserForward: ["cmd+right_bracket"],
        .closeTab: ["cmd+w"],
        .reopenClosedTab: ["cmd+shift+t"],
        .selectCard1: ["ctrl+1"],
        .selectCard2: ["ctrl+2"],
        .selectCard3: ["ctrl+3"],
        .selectCard4: ["ctrl+4"],
        .selectCard5: ["ctrl+5"],
        .selectCard6: ["ctrl+6"],
        .selectCard7: ["ctrl+7"],
        .selectCard8: ["ctrl+8"],
        .selectCard9: ["ctrl+9"],
        .selectTab1: ["alt+1"],
        .selectTab2: ["alt+2"],
        .selectTab3: ["alt+3"],
        .selectTab4: ["alt+4"],
        .selectTab5: ["alt+5"],
        .selectTab6: ["alt+6"],
        .selectTab7: ["alt+7"],
        .selectTab8: ["alt+8"],
        .selectTab9: ["alt+9"],
        .selectWindow1: ["cmd+1"],
        .selectWindow2: ["cmd+2"],
        .selectWindow3: ["cmd+3"],
        .selectWindow4: ["cmd+4"],
        .selectWindow5: ["cmd+5"],
        .selectWindow6: ["cmd+6"],
        .selectWindow7: ["cmd+7"],
        .selectWindow8: ["cmd+8"],
        .selectWindow9: ["cmd+9"],
        .selectNextWindow: [],
        .selectPrevWindow: [],
        .selectNextTopicWindow: [],
        .selectPrevTopicWindow: [],
        .selectNextSession: [],
        .selectPrevSession: [],
        .selectNextTopic: [],
        .selectPrevTopic: [],
    ]

    public static let defaultTriggers = parse(defaultSpelling)

    /// With Focus elsewhere, the key goes on to Ghostty, the page, the menu or
    /// an action that shares the trigger, so a Pane key does not take a key
    /// from the Browser, and a Tab key does not take one from the Terminal.
    public var requiredFocus: PanelLayout.Side? {
        switch self {
        case .toggleZoomPane, .resizePaneLeft, .resizePaneRight, .resizePaneUp, .resizePaneDown, .findInPane: .terminal
        case .findInPage, .selectNextTab, .selectPrevTab, .browserBack, .browserForward, .closeTab, .reopenClosedTab: .browser
        default: nil
        }
    }
}

/// What a keybind does while a Command Palette is open, from
/// `keybindings.command_palette`. These win over the other keybinds then.
public enum PaletteAction: String, KeybindAction {
    case jumpTo = "jump_to"
    case markRead = "mark_read"
    case markUnread = "mark_unread"
    case newSession = "new_session"
    case selectNext = "select_next"
    case selectPrev = "select_prev"
    case showActions = "show_actions"
    case copyFolder = "copy_folder"
    case copyTmuxTarget = "copy_tmux_target"
    case pasteFolder = "paste_folder"

    case move
    case addSessionToTopic = "add_session_to_topic"
    case rename
    case editTags = "edit_tags"
    case setTopicNote = "set_topic_note"
    case clearTopicNote = "clear_topic_note"
    case settleTopic = "settle_topic"
    case forgetTopic = "forget_topic"
    case reopenTopic = "reopen_topic"
    case startTopicFresh = "start_topic_fresh"
    case pinTopic = "pin_topic"
    case unpinTopic = "unpin_topic"
    case removeFromTopic = "remove_from_topic"
    case removeFromTopicAndKill = "remove_from_topic_and_kill"
    case newWindow = "new_window"
    case revealFolder = "reveal_folder"
    case killWindow = "kill_window"
    case killSession = "kill_session"
    case lockSession = "lock_session"
    case unlockSession = "unlock_session"
    case makeGuest = "make_guest"
    case endGuest = "end_guest"
    case choosePane = "choose_pane"
    case chooseWindow = "choose_window"
    case chooseSession = "choose_session"
    case toggleIncludeTab = "toggle_include_tab"
    case toggleNewWorktree = "toggle_new_worktree"

    public static let defaultSpelling: KeyValuePairs<PaletteAction, [String]> = [
        .jumpTo: ["enter"],
        .markRead: [],
        .markUnread: [],
        .newSession: ["cmd+enter"],
        .selectNext: ["down", "ctrl+j"],
        .selectPrev: ["up", "ctrl+k"],
        .showActions: ["cmd+k"],
        .copyFolder: ["cmd+c"],
        .copyTmuxTarget: ["cmd+shift+c"],
        .pasteFolder: ["ctrl+y"],
        .move: [],
        .addSessionToTopic: [],
        .rename: [],
        .editTags: [],
        .setTopicNote: [],
        .clearTopicNote: [],
        .settleTopic: [],
        .forgetTopic: [],
        .reopenTopic: [],
        .startTopicFresh: [],
        .pinTopic: [],
        .unpinTopic: [],
        .removeFromTopic: [],
        .removeFromTopicAndKill: [],
        .newWindow: [],
        .revealFolder: [],
        .killWindow: [],
        .killSession: [],
        .lockSession: [],
        .unlockSession: [],
        .makeGuest: [],
        .endGuest: [],
        .choosePane: ["alt+1"],
        .chooseWindow: ["alt+2"],
        .chooseSession: ["alt+3"],
        .toggleIncludeTab: ["alt+t"],
        .toggleNewWorktree: ["alt+w"],
    ]

    public static let defaultTriggers = parse(defaultSpelling)
}

/// What a keybind does while the field of a find bar, Find in Pane's or Find
/// in Page's, has Focus, from `keybindings.find`. These win over the other
/// keybinds then.
public enum FindAction: String, KeybindAction {
    case next
    case prev
    case close

    public static let defaultSpelling: KeyValuePairs<FindAction, [String]> = [
        .next: ["enter"],
        .prev: ["shift+enter"],
        .close: ["escape"],
    ]

    public static let defaultTriggers = parse(defaultSpelling)
}

/// Each action's triggers, in the order they were listed. A trigger belongs to
/// two actions only when they can share it (`canShareTrigger(with:)`), so for
/// each Focus at most one action acts on a trigger.
public struct KeybindSet<Action: KeybindAction>: Equatable {
    public let triggers: [Action: [KeyTrigger]]

    public init(triggers: [Action: [KeyTrigger]]) {
        self.triggers = triggers
    }

    public static var defaults: Self { Self(triggers: Action.defaultTriggers) }

    /// The action that acts on `trigger` while `focus`, the side with Focus
    /// or nil for neither, has it. The action for that side wins over one
    /// that acts everywhere.
    public func action(for trigger: KeyTrigger, focus: PanelLayout.Side?) -> Action? {
        let owners = triggers.filter { $0.value.contains(trigger) }.map(\.key)
        return owners.first { $0.requiredFocus != nil && $0.requiredFocus == focus }
            ?? owners.first { $0.requiredFocus == nil }
    }

    /// The trigger menus and tooltips show for `action`.
    public func firstTrigger(for action: Action) -> KeyTrigger? {
        triggers[action]?.first
    }
}

/// Muxify's keybinds that work throughout an App Window.
public typealias Keybinds = KeybindSet<ConfigAction>
/// The keybinds of an open Command Palette.
public typealias PaletteKeybinds = KeybindSet<PaletteAction>
/// The keybinds of a find bar's field.
public typealias FindKeybinds = KeybindSet<FindAction>

extension KeybindSet where Action == PaletteAction {
    /// The palette's keybinds act whatever has Focus.
    public func action(for trigger: KeyTrigger) -> PaletteAction? {
        action(for: trigger, focus: nil)
    }
}

extension KeybindSet where Action == FindAction {
    /// The find bar's keybinds act whatever side has Focus.
    public func action(for trigger: KeyTrigger) -> FindAction? {
        action(for: trigger, focus: nil)
    }
}

extension KeybindSet where Action == ConfigAction {
    /// Ghostty's own Cmd+N opens an App Window. New App Window has only the
    /// keys the Config gives it, so Cmd+N does nothing while no action acts
    /// on it under `focus`.
    public func suppressesDefaultAppWindowShortcut(_ trigger: KeyTrigger, focus: PanelLayout.Side?) -> Bool {
        trigger == Self.ghosttyNewWindow && action(for: trigger, focus: focus) == nil
    }

    private static let ghosttyNewWindow = KeyTrigger(modifiers: .command, key: .character("n"))
}
