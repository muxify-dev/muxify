import AppKit
import Foundation
import Yams

/// A Config value that could not apply, or the syntax error that stopped the
/// whole file from applying.
public struct ConfigProblem: Equatable, CustomStringConvertible {
    public let path: String
    public let line: Int
    public let message: String

    public var description: String { "\(path):\(line): \(message)" }
}

/// A Config file that is not valid YAML. Nothing in it applies.
public struct ConfigSyntaxError: Error, Equatable {
    public let problem: ConfigProblem
}

/// What the Sidebar lists above the Agents section. Raw values are the stored choice and the button titles.
public enum SidebarMode: String {
    case topics = "Topics"
    case sessions = "Sessions"
}

/// The Config: how Muxify itself behaves, read from a YAML file.
public struct Config: Equatable {
    public var sidebar = Sidebar()
    /// What `SessionPathDiscovery` found for `sessionRoots` last. Loading a Config never fills it.
    public var sessionPaths: [SessionPath] = []
    /// `sessions.paths`, in Config order.
    public var sessionRoots: [SessionPathRoot] = []
    /// A SessionPath path as the Config wrote it, `~` included, to its alias, from `sessions.aliases`.
    public var sessionAliases: [String: String] = [:]
    public var topics = Topics()
    public var notifications = Notifications()
    public var hints = Hints()
    public var browser = Browser()

    /// The Browser renders on this Mac, so only the Local Config sets it.
    public struct Browser: Equatable {
        public var vimKeys = true
    }

    /// `diagnostics.enabled`: the app logs freezes, CPU and errors to a file (docs/development.md). It is about the
    /// app on this Mac, so only the Local Config sets it.
    public var diagnostics = false

    public struct Hints: Equatable {
        public var holdDelay: TimeInterval? = 0.35
        public var cards = Surface(always: true)
        public var windows = Surface(always: false)
        public var tabs = Surface(always: true)
        public var terminal = Terminal()

        public init() {}

        public struct Surface: Equatable {
            public var always: Bool
            public var hold = true
        }

        public struct Terminal: Equatable {
            public var hold = true
        }
    }

    public struct Topics: Equatable, Sendable {
        public var sessionOrder = SessionOrder.oldestFirst
        public var insertPosition = TopicInsertPosition.bottom
        /// Nil: Tags are off, and `#` in New Topic is plain title text.
        public var tags: ConfigTags?
        /// How many cards that are not Pinned the Sidebar shows In Play; the others are on the Bench. Nil: the Sidebar
        /// shows every card and has no Bench.
        public var inPlay: Int?

        public init() {}
    }

    public struct Notifications: Equatable {
        public var manualRead = false
        public var doneEnabled = true
        public var failedEnabled = true
        public var blockedEnabled = true
    }

    public struct Sidebar: Equatable {
        public var topics = true
        public var sessions = true
        /// Animate switching between Topics and Sessions. False keeps swipes and buttons, with an instant switch.
        public var animateSwitching = true
        /// The Agents section, for each Sidebar mode. Nil leaves that mode to the View menu's Show Agents;
        /// a value decides, and the menu item is disabled in that mode.
        public var agents = PerMode<Bool?>(nil)
        /// The Pane rows. Nil leaves the choice to the View menu's Show Panes; a value decides in both modes.
        public var panes: Bool?
        public var agentsScope = PerMode(AgentsScope.active)
        public var formats = SidebarFormats()
        /// `titles.wrap`: a Topic or Session card's title wraps onto as many lines as it needs.
        /// False keeps it on one line and cuts it with "…".
        public var wrapsTitles = true
        public var windowTooltips = WindowTooltips.always
        public var tagPlacement = TagPlacement.none

        /// When a Window row opens its hover label, in either Sidebar mode.
        public enum WindowTooltips: String {
            case off
            /// Only when the row cuts off its formatted title.
            case truncated
            case always
        }

        /// Where a Topic card shows its Tags.
        public enum TagPlacement: String {
            /// No Tags on the cards.
            case none
            /// One Tag Mark per Tag in the right corner of the title's first line, after the Pin or Lock.
            case corner
            /// The first Tag as a chip, and "+N", in the right corner of the title's first line, after the Pin or Lock.
            case title
            /// Chips on their own line under the title.
            case line
        }

        /// The mode the Sidebar shows when the user chose `chosen`; a mode that is off gives way to the other.
        public func shownMode(chosen: SidebarMode) -> SidebarMode {
            topics && (!sessions || chosen == .topics) ? .topics : .sessions
        }

        /// A setting with its own value in Topics mode and in Sessions mode.
        public struct PerMode<Value: Equatable>: Equatable {
            public var topics: Value
            public var sessions: Value

            public init(_ both: Value) {
                topics = both
                sessions = both
            }

            public subscript(mode: SidebarMode) -> Value {
                get { mode == .topics ? topics : sessions }
                set { if mode == .topics { topics = newValue } else { sessions = newValue } }
            }
        }

        /// Which Agents the Agents section lists.
        public enum AgentsScope: String {
            /// Those of the Active Topic in Topics mode, of the selected Window's Session in Sessions mode.
            case active
            case window
            case all
        }
    }

    public var keybinds = Keybinds.defaults
    /// Height of the app's header in points; at least 24 to fit its buttons.
    public var headerHeight: Double = 30
    /// `ui.status_line`: the Session name and Window selector in the header.
    public var statusLine = StatusLine()

    public struct StatusLine: Equatable {
        /// `enabled`: show the Session name and Window selector, independently of Git and panel controls.
        public var enabled = true
        /// `session.wrap`: while the Sidebar shows, the Session name stays over the Sidebar, and a long one is cut
        /// with "…" in the middle. False shows it whole and lets it push the Window list right.
        public var wrapsSession = true
    }

    /// `ui.pulse`: every Working mark moves. False keeps them still.
    public var pulse = true
    /// `ui.focus_marker`: a short line on the top edge of the side that has Focus, while the Terminal and the Browser
    /// both show.
    public var focusMarker = false
    /// `ui.focus_marker_color`. Nil is the system accent color.
    public var focusMarkerColor: MarkColor?
    /// `ui.focus_marker_opacity`.
    public var focusMarkerOpacity = AppearanceOpacity(light: 0.45, dark: 0.45)
    /// `ui.agent_colors`.
    public var agentColors = AgentColors()
    /// `ui.find_colors`.
    public var findColors = FindColors()
    /// The keybinds of an open Command Palette (`keybindings.command_palette`).
    public var paletteKeybinds = PaletteKeybinds.defaults
    /// The keybinds of a find bar's field (`keybindings.find`).
    public var findKeybinds = FindKeybinds.defaults
    /// In Config order (ADR 0009).
    public var commandPalettes = CommandPaletteConfig.defaults
    /// `pick_lists`: the rules of the Action lists it names.
    public var pickLists: [ActionList: PickRules] = [:]
    /// Typography of the Sidebar's Sessions and Agents, not the terminal.
    public var sidebarTypography = SidebarTypography()
    /// How the Git View opens.
    public var gitView = GitViewConfig()

    /// An Action list's rules: its `pick_lists` entry, else every kind and the standard tiebreak.
    public func rules(for list: ActionList) -> PickRules { pickLists[list] ?? .standard }
    /// The Ghostty config file the terminal loads on top of Ghostty's
    /// default files, as an absolute path.
    public var ghosttyConfigFile: String?
    /// In file order; Local is always available and is never declared here.
    public var remoteEnvironments: [RemoteEnvironment] = []
    public var problems: [ConfigProblem] = []

    /// Reads the Config at `path`. A missing file gives the defaults. A value
    /// that cannot apply is skipped and recorded in `problems`; a syntax error
    /// fails the whole read. A Remote Environment's Config skips the sections
    /// about the app itself (ADR 0010).
    public static func load(path: String, isRemote: Bool = false,
                     fontFamilies: @escaping () -> [String] = { SidebarTypography.fontFamilies },
                     read: (String) -> String?) -> Result<Config, ConfigSyntaxError> {
        guard let text = read(path) else { return .success(Config()) }
        let root: Node?
        do {
            root = try Yams.compose(yaml: text)
        } catch {
            return .failure(ConfigSyntaxError(path: path, error))
        }
        guard let root else { return .success(Config()) }
        return withoutActuallyEscaping(read) { read in
            var reader = ConfigReader(path: path, isRemote: isRemote, read: read, fontFamilies: fontFamilies)
            reader.readSections(root)
            return .success(reader.config)
        }
    }

    /// What Open Config writes into a new Config file.
    public static var template: String {
        func spell<Action: KeybindAction>(_ defaults: KeyValuePairs<Action, [String]>, indent: String) -> String {
            defaults.map { action, spellings in
                "#\(indent)\(action.rawValue): \(spellings.count == 1 ? spellings[0] : "[\(spellings.joined(separator: ", "))]")"
            }.joined(separator: "\n")
        }
        return """
        # Muxify Config. Muxify reloads it when it changes.
        #
        # ghostty:
        #   # The Ghostty config the terminal loads after Ghostty's default
        #   # files. ~/ is the home directory; a relative path starts at the
        #   # directory of this file.
        #   config_file: ~/.config/ghostty/config
        #
        # ui:
        #   # Header height in points (minimum 24). Changes apply live.
        #   header_height: 30
        #   status_line:
        #     # Show the Session name and Window selector. Git and other controls stay visible.
        #     enabled: true
        #     session:
        #       # A long Session name is cut with "…" in the middle to stay over
        #       # the Sidebar. false shows it whole and lets it push the Window
        #       # list right.
        #       wrap: true
        #   # false keeps every Working mark still.
        #   pulse: true
        #   # A short line on the top edge of the Terminal or the Browser, whichever
        #   # has Focus. It shows only while both show.
        #   focus_marker: false
        #   # The marker's color: accent (the macOS accent color), a color as in
        #   # agent_colors, or a mapping with light and dark.
        #   focus_marker_color: accent
        #   # Above 0 and at most 1, or a mapping with light and dark.
        #   focus_marker_opacity: 0.45
        #   # The color of each Agent mark, in the Sidebar and the Command
        #   # Palette: blue, orange, red, green, yellow, purple, pink, teal,
        #   # gray, or a quoted '#RRGGBB'.
        #   agent_colors:
        #     working: gray
        #     done: blue
        #     blocked: orange
        #     failed: red
        #   # The highlight of Find in Pane's matches and of its current match:
        #   # one color name as in agent_colors or a quoted '#RRGGBB', the same
        #   # in every theme.
        #   find_colors:
        #     match: '#FFD54F'
        #     current: '#FF9600'
        #   sidebar:
        #     # Positive base size in points; other text scales proportionally.
        #     # Changes apply live. Invalid values use the defaults below.
        #     font_size: 12
        #     # system, or an installed macOS font family (case-insensitive).
        #     font_family: system
        #
        # git_view:
        #   # The Git View (toggle_git_view, cmd+g) shows the current Window's
        #   # repository: popup over the App Window, or fullscreen in the
        #   # terminal's place.
        #   display: popup
        #   # The popup's share of the App Window, like tmux's
        #   # display-popup -w 80% -h 80%: from 10% to 100%.
        #   width: 80%
        #   height: 80%
        #   # What e runs in a new tmux Window to edit a file, in the
        #   # repository's folder: {file} and {line} are filled in and
        #   # quoted. Without it: ${VISUAL:-${EDITOR:-vi}} +{line} {file}
        #   editor: nvim +{line} {file}
        #   # false runs editor with no Window, for a command that hands the
        #   # file to an editor that already runs, such as
        #   # nvim --server <socket> --remote {file}.
        #   editor_in_window: true
        #
        # sessions:
        #   # Folders where you open Sessions. A path may be a glob, and each
        #   # folder it matches is a root. depth 0 (the default) is the root
        #   # itself; 1 lists its subfolders, 2 goes two levels deep. Hidden
        #   # folders are skipped, and so are folders this machine doesn't
        #   # have. A repository is one SessionPath, with its Worktrees as rows.
        #   # display_depth is how many trailing folder names name a SessionPath.
        #   paths:
        #     - path: ~/Dev/*/*
        #       display_depth: 2
        #     - path: ~/sessionPaths
        #       depth: 1
        #     - path: ~/.dotfiles
        #   # The name lists and the Sidebar show for a SessionPath, by its path.
        #   # tmux Sessions keep the folder name, and typing it still finds
        #   # the SessionPath.
        #   aliases:
        #     - ~/Dev/obsidian_vaults/notes: My Notes
        #
        # command_palettes:
        #   # A palette opens with its sources selected: topics, sessions (with
        #   # the SessionPaths above), windows, agents or commands. Cmd+1–Cmd+5
        #   # select the others too. The defaults are Commands on cmd+shift+p
        #   # and Go to… on cmd+p. An empty list removes both palettes.
        #   - name: Commands
        #     keybinding: cmd+shift+p
        #     sources: [commands]
        #   - name: Go to…
        #     keybinding: cmd+p
        #     sources: [topics, sessions]
        #     # grouped puts each source under its own header; ranked ranks
        #     # the rows of every source in one list for a query.
        #     order: grouped
        #     # On an equal match, the first rule that differs decides:
        #     # open, running, visit, activity or length.
        #     tiebreak: [open, length, running, visit, activity]
        #     # The kinds of rows it lists; without show, every kind:
        #     # topic, settled, session, topic-session,
        #     # session-path, worktree, window, agent, command or tag.
        #     show: [topic, settled, session, session-path, worktree]
        #   - name: Agents
        #     keybinding: cmd+shift+o
        #     sources: [agents]
        #
        # pick_lists:
        #   # An Action's list takes show and tiebreak as a palette does:
        #   # add_session, move, move_session, tags or worktree_start.
        #   add_session:
        #     show: [session-path]
        #
        # remote_environments:
        #   # A Remote Environment's App Window uses that machine's own Config
        #   # when it has one, without its ghostty, browser and remote_environments.
        #   - name: Macbook Home
        #     host: macbook-home.example.ts.net
        #     username: your-user
        #     # port: 22
        #     # identity_file: ~/.ssh/id_ed25519
        #     # forward_agent: false  # Agent forwarding is enabled by default.
        #
        # sidebar:
        #   topics: true
        #   sessions: true
        #   # false switches Topics/Sessions instantly, without a swipe preview or animation.
        #   animate_switching: true
        #   # The Agents section and the Pane rows. Leave them out to choose in the
        #   # View menu; a value here decides, and the menu item is disabled.
        #   agents: true
        #   panes: false
        #   # active: Agents of the Topic or Session you look at. all: every Agent.
        #   # window: Agents of the selected Window; every Agent if none is selected.
        #   agents_scope: active
        #   # agents and agents_scope also take one value for each Sidebar mode:
        #   # agents:
        #   #   topics: true
        #   #   sessions: false
        #   # agents_scope:
        #   #   topics: active
        #   #   sessions: all
        #   # A long Topic or Session card title wraps onto more lines. false keeps
        #   # it on one line and cuts it with "…" at the card's edge.
        #   titles:
        #     wrap: true
        #   # Window hover labels: off, truncated (only when the title is cut off), or always.
        #   window_tooltips: always
        #   # Titles and summaries set plain text. Each Format can have topics/sessions values.
        #   # An empty summary hides its line. An empty title uses its default.
        #   formats:
        #     topic:
        #       title: '#{topic_title}'
        #       summary: '#{window_count} Windows'
        #     session:
        #       title: '#{session_name}'
        #     window:
        #       title: '#{window_title}'
        #       summary: '#{pane_current_command}'
        #       # Omitted or null parts keep native content. Empty strings hide them.
        #       left: '#{current_app_icon}'
        #       right: '#{symbol:globe} #{tab_count}  #{symbol:rectangle.split.2x1} #{window_panes}'
        #     pane:
        #       title: '#{pane_label}'
        #       summary: ''
        #     agent:
        #       title: '#{window_name}'
        #       summary: '#{agent_group}'
        #   # Where a Topic card shows its Tags: none, corner (marks in the
        #   # title line's right corner), title (chips after the title) or line
        #   # (chips under it).
        #   # formats.topic.tags gives each Tag's text: '#{T:#{tag}}'; '' hides them.
        #   tag_placement: none
        #
        # hints:
        #   hold_delay: 0.35 # seconds; 0 shows at once; false disables hold Hints
        #   cards: { always: true, hold: true }
        #   windows: { always: false, hold: true }
        #   tabs: { always: true, hold: true }
        #   terminal: { hold: true }
        #
        # browser:
        #   # h, j, k, l, d, u, gg and G scroll the page when the page does
        #   # not use the key itself and no text field has Focus.
        #   vim_keys: true
        #
        # diagnostics:
        #   # Logs each freeze, with a sample of the app taken during it, CPU
        #   # and memory each minute, and errors to ~/Library/Logs/Muxify.
        #   enabled: false
        #
        # notifications:
        #   manual_read: false
        #   done_enabled: true
        #   failed_enabled: true
        #   blocked_enabled: true
        #
        # topics:
        #   # The order of a Topic's Sessions, by when tmux created them:
        #   # oldest_first or newest_first. Once you move a Session, the Topic
        #   # keeps your order, and a new Session goes to this order's end.
        #   session_order: oldest_first
        #   # New and returning Settled Topics go at the bottom or top of their
        #   # part of the list. Dormant Topics keep their place. With in_play,
        #   # they go to the top of the Bench instead.
        #   insert_position: bottom
        #   # The Sidebar shows the Pinned Topics and this many other Topics and
        #   # Locked Sessions In Play. The rest wait on the Bench, behind one line
        #   # that shows them. Not set: the Sidebar shows them all.
        #   in_play: 5
        #   # The only Tags a Topic can have, in this order. A key is lower case
        #   # letters, digits and -. color is as in ui.agent_colors; a Tag
        #   # without one gets a fixed color from its name. No tags: Tags are off.
        #   tags:
        #     work:
        #       color: blue
        #     personal:
        #       color: {light: '#5E8C6A', dark: '#7FA88A'}
        #
        # keybindings:
        #   # An action maps to one trigger or a list of them, spelled as in
        #   # Ghostty. Naming an action replaces its defaults, and [] leaves it
        #   # with no keybinding. A trigger listed here is taken from the
        #   # defaults of other actions.
        #   # Keybindings work throughout Muxify, including in the Browser.
        #   # focus_terminal also uses Ctrl+backquote, Ctrl+0 and Alt+0.
        #   # Cmd+backquote stays available for macOS App Window switching.
        #   # select_card_1 through select_card_9 Jump To Topic or Session cards.
        #   # select_tab_1 through select_tab_9 select Tabs and show the Browser.
        #   # toggle_zoom_pane, resize_pane_* and find_in_pane act only while
        #   # the Terminal has Focus. find_in_page, select_next_tab, select_prev_tab,
        #   # browser_back and browser_forward act only while the Browser has Focus. With Focus
        #   # elsewhere, their keys go on to Ghostty, the page or the menu.
        #   # resize_pane_* move the Pane's border 10 cells and are unbound.
        #   # Hold the exact modifiers alone to show Hints after hints.hold_delay.
        #   # Hints show the resolved triggers. The shortcuts act without a wait.
        #   # select_window_1 through select_window_9 pick the first through
        #   # ninth Windows in the current Session, not their tmux indices.
        #   # select_next_window and select_prev_window wrap within the Session
        #   # and have no keybindings until you assign them.
        #   # select_next_topic_window and select_prev_topic_window step
        #   # through every Window of the Active Topic in Topics mode, and
        #   # wrap within the Session in Sessions mode. They are unbound.
        #   # While the Browser has Focus, these four Window step actions
        #   # select the next or previous Tab instead.
        #   # select_next_session and select_prev_session step through the
        #   # Sessions the Sidebar shows: in Topics mode, those of the Active
        #   # Topic. select_next_topic and select_prev_topic go to the Topic
        #   # below or above in the Topics list. All four wrap and are unbound.
        #   # The defaults:
        \(spell(ConfigAction.defaultSpelling, indent: "   "))
        #   # While a Command Palette is open, these act instead:
        #   command_palette:
        \(spell(PaletteAction.defaultSpelling, indent: "     "))
        #   # While the field of Find in Pane or Find in Page has Focus, these
        #   # act instead. close in the Terminal goes on to the active Pane, and
        #   # also closes Find in Pane when that Pane is the searched one.
        #   find:
        \(spell(FindAction.defaultSpelling, indent: "     "))

        """
    }
}

/// What Muxify runs with: the last Config that read without a syntax error,
/// and the problems of the latest read. A half-typed edit shows its syntax
/// error but does not reset the keybinds in use.
public struct LoadedConfig: Equatable {
    public private(set) var config = Config()
    public private(set) var problems: [ConfigProblem] = []

    public init() {}

    public mutating func update(sessionPaths: [SessionPath]) {
        config.sessionPaths = sessionPaths
    }

    public mutating func update(with result: Result<Config, ConfigSyntaxError>) {
        switch result {
        case .success(let config):
            self.config = config
            problems = config.problems
        case .failure(let error):
            problems = [error.problem]
        }
    }
}

private extension ConfigSyntaxError {
    init(path: String, _ error: Error) {
        switch error as? YamlError {
        case let .scanner(context, message, mark, _), let .parser(context, message, mark, _), let .composer(context, message, mark, _):
            let text = [context?.text, message].compactMap { $0 }.joined(separator: ": ")
            problem = ConfigProblem(path: path, line: mark.line, message: text)
        case let .duplicatedKeysInMapping(duplicates, context):
            problem = ConfigProblem(path: path, line: context.mark.line, message: "duplicate key \(duplicates.joined(separator: ", "))")
        default:
            problem = ConfigProblem(path: path, line: 1, message: "\(error)")
        }
    }
}

/// Turns the YAML nodes of one Config file into a Config, skipping what
/// cannot apply.
private struct ConfigReader {
    let path: String
    let isRemote: Bool
    let read: (String) -> String?
    let fontFamilies: () -> [String]
    var config = Config()

    /// Who a trigger can be bound to anywhere in an App Window.
    private enum Claimant: Hashable {
        case action(ConfigAction)
        case palette(String)

        var description: String {
            switch self {
            case .action(let action): action.rawValue
            case .palette(let name): "the \(name) Command Palette"
            }
        }

        /// A Command Palette's trigger acts before every keybind, so it shares
        /// with nothing.
        func canShareTrigger(with other: Claimant) -> Bool {
            guard case .action(let action) = self, case .action(let otherAction) = other else { return false }
            return action.canShareTrigger(with: otherAction)
        }

        func takesDefault(_ trigger: KeyTrigger, from action: ConfigAction) -> Bool {
            guard case .action(let claimant) = self else { return true }
            return claimant.takesDefault(trigger, from: action)
        }
    }

    private struct Claim<Owner> {
        let owner: Owner
        let trigger: KeyTrigger
        let node: Node
    }

    /// The `keybindings` actions and Command Palettes, whose triggers are
    /// settled once every section is read.
    private var namedActions: [ConfigAction] = []
    private var palettes: [CommandPaletteConfig]?
    private var claims: [Claim<Claimant>] = []

    init(path: String, isRemote: Bool, read: @escaping (String) -> String?, fontFamilies: @escaping () -> [String]) {
        self.path = path
        self.isRemote = isRemote
        self.read = read
        self.fontFamilies = fontFamilies
    }

    static let sections: [String: (inout ConfigReader, Node) -> Void] = [
        "topics": { $0.readTopics($1) },
        "notifications": { $0.readNotifications($1) },
        "hints": { $0.readHints($1) },
        "browser": { $0.readBrowser($1) },
        "diagnostics": { $0.readDiagnostics($1) },
        "sidebar": { $0.readSidebar($1) },
        "ghostty": { $0.readGhostty($1) },
        "ui": { $0.readUI($1) },
        "keybindings": { $0.readKeybindings($1) },
        "command_palettes": { $0.readCommandPalettes($1) },
        "pick_lists": { $0.readPickLists($1) },
        "git_view": { $0.readGitView($1) },
        "sessions": { $0.readSessions($1) },
        "remote_environments": { $0.readRemoteEnvironments($1) },
    ]

    /// About the app on this Mac, not the machine the Config is on.
    static let appSections: Set<String> = ["ghostty", "browser", "diagnostics", "remote_environments"]

    mutating func readSections(_ root: Node) {
        for (name, key, value) in entries(of: root, "the Config") {
            if isRemote, Self.appSections.contains(name) { continue }
            guard let section = Self.sections[name] else {
                problem(at: key, "unknown section \"\(name)\"")
                continue
            }
            section(&self, value)
        }
        resolveKeybindings()
        // In file order, although conflicts are found after every section.
        config.problems = config.problems.enumerated()
            .sorted { ($0.element.line, $0.offset) < ($1.element.line, $1.offset) }
            .map(\.element)
    }

    /// A folder missing on this machine is not a problem: the Config may be shared by several Macs.
    public mutating func readSessions(_ node: Node) {
        for (name, key, value) in entries(of: node, "sessions") {
            switch name {
            case "paths": readSessionPaths(value)
            case "aliases": readSessionPathAliases(value)
            default: problem(at: key, "unknown key \"sessions.\(name)\"")
            }
        }
    }

    mutating func readSessionPaths(_ node: Node) {
        guard let sequence = node.sequence else {
            problem(at: node, "sessions.paths: expected a list")
            return
        }
        for item in sequence {
            guard item.mapping != nil else {
                problem(at: item, "sessions.paths: expected a mapping with a path")
                continue
            }
            let problemCount = config.problems.count
            var values: [String: Node] = [:]
            for (name, key, value) in entries(of: item, "a sessions.paths entry") {
                guard ["path", "depth", "display_depth"].contains(name) else {
                    problem(at: key, "unknown key \"sessions.paths.\(name)\"")
                    continue
                }
                values[name] = value
            }
            let path = values["path"].flatMap { $0.tag == Yams.Tag(.str) ? string($0) : nil }?.trimmingCharacters(in: .whitespacesAndNewlines)
            if path?.isEmpty != false || path?.rangeOfCharacter(from: .controlCharacters) != nil {
                problem(at: values["path"] ?? item, "sessions.paths.path: expected a path or a path glob")
            }
            let depth = count(values["depth"], "sessions.paths.depth", atLeast: 0) ?? 0
            let displayDepth = count(values["display_depth"], "sessions.paths.display_depth", atLeast: 1) ?? 1
            guard config.problems.count == problemCount, let path else { continue }
            config.sessionRoots.append(SessionPathRoot(path: written(path), depth: depth, displayDepth: displayDepth))
        }
    }

    /// A whole number of at least `minimum`; nil when the key is missing or the value is wrong.
    private mutating func count(_ node: Node?, _ place: String, atLeast minimum: Int) -> Int? {
        guard let node, node.null == nil else { return nil }
        guard node.tag == Yams.Tag(.int), let number = node.int, number >= minimum else {
            problem(at: node, "\(place): expected a whole number of \(minimum) or more")
            return nil
        }
        return number
    }

    /// `~` stays, so each machine reads it as its own home folder. A relative path starts at the Config's folder.
    private func written(_ path: String) -> String {
        if path == "~" || path.hasPrefix("~/") { return path }
        return ConfigFileSet.resolve(path, relativeTo: (self.path as NSString).deletingLastPathComponent)
    }

    mutating func readSessionPathAliases(_ node: Node) {
        guard let sequence = node.sequence else {
            problem(at: node, "sessions.aliases: expected a list")
            return
        }
        for entry in sequence {
            guard let pair = entry.mapping, pair.count == 1, let (key, value) = pair.first else {
                problem(at: entry, "sessions.aliases: expected one SessionPath path mapped to its alias")
                continue
            }
            guard key.tag == Yams.Tag(.str), let pattern = key.string, !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                problem(at: key, "sessions.aliases: expected a SessionPath path")
                continue
            }
            guard value.tag == Yams.Tag(.str), let alias = value.string?.trimmingCharacters(in: .whitespaces), !alias.isEmpty,
                  alias.rangeOfCharacter(from: .controlCharacters) == nil else {
                problem(at: value, "sessions.aliases.\(pattern): expected a nonempty one-line alias")
                continue
            }
            let repositoryPath = written(pattern.trimmingCharacters(in: .whitespacesAndNewlines))
            let written = repositoryPath.hasPrefix("~/") ? "~/" + (String(repositoryPath.dropFirst(2)) as NSString).standardizingPath : repositoryPath
            guard config.sessionAliases[written] == nil else {
                problem(at: key, "sessions.aliases: \(pattern) already has an alias")
                continue
            }
            config.sessionAliases[written] = alias
        }
    }

    public mutating func readTopics(_ node: Node) {
        for (name, key, value) in entries(of: node, "topics") {
            switch name {
            case "insert_position":
                guard value.tag == Yams.Tag(.str), let position = value.string.flatMap(TopicInsertPosition.init(rawValue:)) else {
                    problem(at: value, "topics.insert_position: expected bottom or top")
                    continue
                }
                config.topics.insertPosition = position
            case "session_order":
                guard value.tag == Yams.Tag(.str), let order = value.string.flatMap(SessionOrder.init(rawValue:)) else {
                    problem(at: value, "topics.session_order: expected oldest_first or newest_first")
                    continue
                }
                config.topics.sessionOrder = order
            case "tags": readTags(value)
            case "in_play": config.topics.inPlay = count(value, "topics.in_play", atLeast: 1)
            default: problem(at: key, "unknown key \"topics.\(name)\"")
            }
        }
    }

    /// A Tag that cannot apply is left out, so a later Tag change cannot add it. A bad `color` leaves only the
    /// colour out.
    mutating func readTags(_ node: Node) {
        guard node.null == nil else { return }
        var definitions: [TagDefinition] = []
        for (name, key, value) in entries(of: node, "topics.tags") {
            guard let tag = Tag(name: name) else {
                problem(at: key, "topics.tags: \"\(name)\" is not a Tag: use lower case letters, digits and -, e.g. backend")
                continue
            }
            var color: MarkColor?
            if value.null == nil {
                for (field, fieldKey, fieldValue) in entries(of: value, "topics.tags.\(name)") {
                    switch field {
                    case "color": color = markColor(fieldValue, "topics.tags.\(name).color")
                    default: problem(at: fieldKey, "unknown key \"topics.tags.\(name).\(field)\"")
                    }
                }
            }
            definitions.append(TagDefinition(tag: tag, color: color))
        }
        config.topics.tags = ConfigTags(definitions)
    }

    mutating func readHints(_ node: Node) {
        for (name, key, value) in entries(of: node, "hints") {
            if name == "hold_delay" {
                if value.tag == Yams.Tag(.bool), value.bool == false {
                    config.hints.holdDelay = nil
                } else if (value.tag == Yams.Tag(.int) || value.tag == Yams.Tag(.float)),
                          let delay = value.float, delay.isFinite, delay >= 0 {
                    config.hints.holdDelay = delay
                } else {
                    problem(at: value, "hints.hold_delay: expected nonnegative seconds or false")
                }
                continue
            }
            guard ["cards", "windows", "tabs", "terminal"].contains(name) else {
                problem(at: key, "unknown key \"hints.\(name)\"")
                continue
            }
            for (setting, settingKey, settingValue) in entries(of: value, "hints.\(name)") {
                guard setting == "hold" || (setting == "always" && name != "terminal") else {
                    problem(at: settingKey, "unknown key \"hints.\(name).\(setting)\"")
                    continue
                }
                guard settingValue.tag == Yams.Tag(.bool), let enabled = settingValue.bool else {
                    problem(at: settingValue, "hints.\(name).\(setting): expected a boolean")
                    continue
                }
                switch (name, setting) {
                case ("cards", "always"): config.hints.cards.always = enabled
                case ("cards", _): config.hints.cards.hold = enabled
                case ("windows", "always"): config.hints.windows.always = enabled
                case ("windows", _): config.hints.windows.hold = enabled
                case ("tabs", "always"): config.hints.tabs.always = enabled
                case ("tabs", _): config.hints.tabs.hold = enabled
                default: config.hints.terminal.hold = enabled
                }
            }
        }
    }

    public mutating func readNotifications(_ node: Node) {
        for (name, key, value) in entries(of: node, "notifications") {
            guard ["manual_read", "done_enabled", "failed_enabled", "blocked_enabled"].contains(name) else {
                problem(at: key, "unknown key \"notifications.\(name)\"")
                continue
            }
            guard value.tag == Yams.Tag(.bool), let enabled = value.bool else {
                problem(at: value, "notifications.\(name): expected a boolean")
                continue
            }
            switch name {
            case "manual_read": config.notifications.manualRead = enabled
            case "done_enabled": config.notifications.doneEnabled = enabled
            case "failed_enabled": config.notifications.failedEnabled = enabled
            default: config.notifications.blockedEnabled = enabled
            }
        }
    }

    mutating func readGitView(_ node: Node) {
        for (name, key, value) in entries(of: node, "git_view") {
            switch name {
            case "display":
                guard let display = string(value).flatMap({ GitViewConfig.Display(rawValue: $0.trimmingCharacters(in: .whitespaces).lowercased()) }) else {
                    problem(at: value, "git_view.display: expected popup or fullscreen")
                    continue
                }
                config.gitView.display = display
            case "width", "height":
                guard let share = string(value).flatMap(GitViewConfig.share) else {
                    problem(at: value, "git_view.\(name): expected a percentage from 10% to 100%")
                    continue
                }
                if name == "width" { config.gitView.width = share } else { config.gitView.height = share }
            case "editor":
                guard let editor = string(value), GitViewConfig.isEditor(editor) else {
                    problem(at: value, "git_view.editor: expected a command with {file}, and {line} if it takes one")
                    continue
                }
                config.gitView.editor = editor
            case "editor_in_window":
                guard value.tag == Yams.Tag(.bool), let inWindow = value.bool else {
                    problem(at: value, "git_view.editor_in_window: expected a boolean")
                    continue
                }
                config.gitView.editorInWindow = inWindow
            case "services":
                config.gitView.services = []
                for (host, _, entry) in entries(of: value, "git_view.services") {
                    guard let text = string(entry) else {
                        problem(at: entry, "git_view.services.\(host): expected <provider>:<web domain>")
                        continue
                    }
                    switch GitHosting.service(host: host, value: text) {
                    case .success(let service): config.gitView.services.append(service)
                    case .failure(let failure): problem(at: entry, failure.message)
                    }
                }
            default:
                problem(at: key, "unknown key \"git_view.\(name)\"")
            }
        }
    }

    mutating func readBrowser(_ node: Node) {
        for (name, key, value) in entries(of: node, "browser") {
            guard name == "vim_keys" else {
                problem(at: key, "unknown key \"browser.\(name)\"")
                continue
            }
            guard value.tag == Yams.Tag(.bool), let enabled = value.bool else {
                problem(at: value, "browser.\(name): expected a boolean")
                continue
            }
            config.browser.vimKeys = enabled
        }
    }

    mutating func readDiagnostics(_ node: Node) {
        for (name, key, value) in entries(of: node, "diagnostics") {
            guard name == "enabled" else {
                problem(at: key, "unknown key \"diagnostics.\(name)\"")
                continue
            }
            guard value.tag == Yams.Tag(.bool), let enabled = value.bool else {
                problem(at: value, "diagnostics.enabled: expected a boolean")
                continue
            }
            config.diagnostics = enabled
        }
    }

    public mutating func readSidebar(_ node: Node) {
        for (name, key, value) in entries(of: node, "sidebar") {
            switch name {
            case "topics", "sessions", "animate_switching", "panes":
                guard value.tag == Yams.Tag(.bool), let enabled = value.bool else {
                    problem(at: value, "sidebar.\(name): expected a boolean")
                    continue
                }
                switch name {
                case "topics": config.sidebar.topics = enabled
                case "sessions": config.sidebar.sessions = enabled
                case "animate_switching": config.sidebar.animateSwitching = enabled
                default: config.sidebar.panes = enabled
                }
            case "agents":
                config.sidebar.agents = perMode(value, "sidebar.agents", config.sidebar.agents, expected: "a boolean") {
                    guard $0.tag == Yams.Tag(.bool), let enabled = $0.bool else { return Bool??.none }
                    return enabled
                }
            case "formats":
                readSidebarFormats(value)
            case "titles":
                for (part, key, value) in entries(of: value, "sidebar.titles") {
                    guard part == "wrap" else {
                        problem(at: key, "unknown key \"sidebar.titles.\(part)\"")
                        continue
                    }
                    guard value.tag == Yams.Tag(.bool), let wraps = value.bool else {
                        problem(at: value, "sidebar.titles.wrap: expected a boolean")
                        continue
                    }
                    config.sidebar.wrapsTitles = wraps
                }
            case "window_tooltips":
                // YAML also tags the unquoted word off as a boolean; use the scalar's spelling.
                guard let tooltips = value.scalar.flatMap({ Config.Sidebar.WindowTooltips(rawValue: $0.string) }) else {
                    problem(at: value, "sidebar.window_tooltips: expected off, truncated or always")
                    continue
                }
                config.sidebar.windowTooltips = tooltips
            case "tag_placement":
                guard value.tag == Yams.Tag(.str), let placement = value.string.flatMap(Config.Sidebar.TagPlacement.init(rawValue:)) else {
                    problem(at: value, "sidebar.tag_placement: expected none, corner, title or line")
                    continue
                }
                config.sidebar.tagPlacement = placement
            case "agents_scope":
                config.sidebar.agentsScope = perMode(value, "sidebar.agents_scope", config.sidebar.agentsScope,
                                                     expected: "active, window or all") { node in
                    node.null == nil ? node.scalar.flatMap { Config.Sidebar.AgentsScope(rawValue: $0.string) } : nil
                }
            default:
                problem(at: key, "unknown key \"sidebar.\(name)\"")
            }
        }
    }

    private mutating func readSidebarFormats(_ node: Node) {
        for (name, key, value) in entries(of: node, "sidebar.formats") {
            guard let object = SidebarFormats.Object(rawValue: name) else {
                problem(at: key, "unknown key \"sidebar.formats.\(name)\"")
                continue
            }
            for (part, key, value) in entries(of: value, "sidebar.formats.\(name)") {
                let place = "sidebar.formats.\(name).\(part)"
                if object == .window, part == "left" || part == "right" {
                    let current = part == "left" ? config.sidebar.formats.windowParts.left : config.sidebar.formats.windowParts.right
                    let parsed = perMode(value, place, current, expected: "a Format string or null") { node -> SidebarPartFormat?? in
                        if node.null != nil { return .some(nil) }
                        guard node.tag == Yams.Tag(.str), let source = node.string else { return nil }
                        let format = try SidebarPartFormat(source)
                        for name in format.symbolNames {
                            guard NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil else {
                                throw SidebarFormat.Failure(description: "unknown SF Symbol \"\(name)\"")
                            }
                        }
                        return .some(format)
                    }
                    if part == "left" { config.sidebar.formats.windowParts.left = parsed }
                    else { config.sidebar.formats.windowParts.right = parsed }
                    continue
                }
                if object == .topic, part == "tags" {
                    config.sidebar.formats.topicTags = perMode(value, place, SidebarFormats.defaults.topicTags,
                                                               expected: "a Format string or null") { node in
                        if node.null != nil { return SidebarFormats.defaults.topicTags.topics }
                        guard node.tag == Yams.Tag(.str), let source = node.string else { return nil }
                        return try SidebarTagsFormat(source)
                    }
                    continue
                }
                guard part == "title" || part == "summary" else {
                    problem(at: key, "unknown key \"\(place)\"")
                    continue
                }
                let defaults = SidebarFormats.defaults[object]
                let fallback = part == "title" ? defaults.title : defaults.summary
                let parsed = perMode(value, place, fallback, expected: "a Format string") { node in
                    guard node.tag == Yams.Tag(.str), let source = node.string else { return nil }
                    return try SidebarFormat(source)
                }
                if part == "title" { config.sidebar.formats[object].title = parsed }
                else { config.sidebar.formats[object].summary = parsed }
            }
        }
    }

    public mutating func readGhostty(_ node: Node) {
        for (name, key, value) in entries(of: node, "ghostty") {
            switch name {
            case "config_file":
                guard let path = string(value) else {
                    problem(at: value, "ghostty.config_file: expected a path")
                    continue
                }
                let file = ConfigFileSet.resolve(path, relativeTo: (self.path as NSString).deletingLastPathComponent)
                // Kept although missing, so the watcher sees the file appear.
                config.ghosttyConfigFile = file
                if read(file) == nil { problem(at: value, "ghostty.config_file \(file): not found") }
            default:
                problem(at: key, "unknown key \"ghostty.\(name)\"")
            }
        }
    }

    public mutating func readRemoteEnvironments(_ node: Node) {
        guard let sequence = node.sequence else {
            problem(at: node, "remote_environments: expected a list")
            return
        }
        var names: Set<String> = ["Local"]
        for item in sequence {
            let problemCount = config.problems.count
            let fields = entries(of: item, "a Remote Environment")
            var values: [String: Node] = [:]
            for (name, key, value) in fields {
                guard ["name", "host", "username", "port", "identity_file", "forward_agent"].contains(name) else {
                    problem(at: key, "unknown Remote Environment key \"\(name)\"")
                    continue
                }
                values[name] = value
            }
            func required(_ key: String) -> String? {
                values[key].flatMap(string)?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let name = required("name")
            let host = required("host")
            let username = required("username")
            for (key, value) in [("name", name), ("host", host), ("username", username)] {
                if value?.isEmpty != false {
                    problem(at: values[key] ?? item, "Remote Environment \(key): expected a nonempty string")
                }
            }
            if let name, name.rangeOfCharacter(from: .controlCharacters) != nil {
                problem(at: values["name"] ?? item, "Remote Environment name: control characters are not allowed")
            }
            for (key, value) in [("host", host), ("username", username)] {
                if let value, !value.isEmpty,
                   value.hasPrefix("-") || value.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) != nil {
                    problem(at: values[key] ?? item, "Remote Environment \(key): expected a host or username without whitespace or a leading '-'")
                }
            }
            var port: Int?
            if let value = values["port"], value.null == nil {
                if let number = value.int, (1...65535).contains(number) {
                    port = number
                } else {
                    problem(at: value, "Remote Environment port: expected an integer from 1 to 65535")
                }
            }
            var identityFile: String?
            if let value = values["identity_file"], value.null == nil {
                if let path = string(value), !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   path.rangeOfCharacter(from: .controlCharacters) == nil {
                    identityFile = ConfigFileSet.resolve(path, relativeTo: (self.path as NSString).deletingLastPathComponent)
                } else {
                    problem(at: value, "Remote Environment identity_file: expected a local path")
                }
            }
            var forwardAgent = true
            if let value = values["forward_agent"], value.null == nil {
                if let enabled = value.bool {
                    forwardAgent = enabled
                } else {
                    problem(at: value, "Remote Environment forward_agent: expected true or false")
                }
            }
            if let name, names.contains(name) {
                problem(at: values["name"] ?? item, "Remote Environment name \"\(name)\" is already used (Local is reserved)")
            }
            guard config.problems.count == problemCount, let name, let host, let username else { continue }
            names.insert(name)
            config.remoteEnvironments.append(RemoteEnvironment(
                name: name, host: host, username: username, port: port, identityFile: identityFile,
                forwardAgent: forwardAgent
            ))
        }
    }

    public mutating func readUI(_ node: Node) {
        for (name, key, value) in entries(of: node, "ui") {
            switch name {
            case "header_height":
                guard let height = value.float, height.isFinite, height >= 24 else {
                    problem(at: value, "ui.header_height: expected a finite number of at least 24 points")
                    continue
                }
                config.headerHeight = height
            case "status_line":
                readUIStatusLine(value)
            case "pulse":
                guard value.tag == Yams.Tag(.bool), let pulse = value.bool else {
                    problem(at: value, "ui.pulse: expected a boolean")
                    continue
                }
                config.pulse = pulse
            case "focus_marker":
                guard value.tag == Yams.Tag(.bool), let enabled = value.bool else {
                    problem(at: value, "ui.focus_marker: expected a boolean")
                    continue
                }
                config.focusMarker = enabled
            case "focus_marker_color":
                if value.tag == Yams.Tag(.str), string(value)?.lowercased() == "accent" {
                    config.focusMarkerColor = nil
                } else if let color = markColor(value, "ui.focus_marker_color") {
                    config.focusMarkerColor = color
                }
            case "focus_marker_opacity":
                if let opacity = appearanceOpacity(value, "ui.focus_marker_opacity") { config.focusMarkerOpacity = opacity }
            case "sidebar":
                readUISidebar(value)
            case "agent_colors":
                readAgentColors(value)
            case "find_colors":
                readFindColors(value)
            default:
                problem(at: key, "unknown key \"ui.\(name)\"")
            }
        }
    }

    mutating func readUIStatusLine(_ node: Node) {
        for (name, key, value) in entries(of: node, "ui.status_line") {
            switch name {
            case "enabled":
                guard value.tag == Yams.Tag(.bool), let enabled = value.bool else {
                    problem(at: value, "ui.status_line.enabled: expected a boolean")
                    continue
                }
                config.statusLine.enabled = enabled
            case "session":
                for (part, key, value) in entries(of: value, "ui.status_line.session") {
                    guard part == "wrap" else {
                        problem(at: key, "unknown key \"ui.status_line.session.\(part)\"")
                        continue
                    }
                    guard value.tag == Yams.Tag(.bool), let wraps = value.bool else {
                        problem(at: value, "ui.status_line.session.wrap: expected a boolean")
                        continue
                    }
                    config.statusLine.wrapsSession = wraps
                }
            default:
                problem(at: key, "unknown key \"ui.status_line.\(name)\"")
            }
        }
    }

    mutating func readAgentColors(_ node: Node) {
        for (name, key, value) in entries(of: node, "ui.agent_colors") {
            guard let mark = AgentMark(rawValue: name) else {
                problem(at: key, "unknown key \"ui.agent_colors.\(name)\"")
                continue
            }
            guard let color = markColor(value, "ui.agent_colors.\(name)") else { continue }
            config.agentColors[mark] = color
        }
    }

    mutating func readFindColors(_ node: Node) {
        for (name, key, value) in entries(of: node, "ui.find_colors") {
            switch name {
            case "match": if let color = singleColor(value, "ui.find_colors.match") { config.findColors.match = color }
            case "current": if let color = singleColor(value, "ui.find_colors.current") { config.findColors.current = color }
            default: problem(at: key, "unknown key \"ui.find_colors.\(name)\"")
            }
        }
    }

    mutating func readUISidebar(_ node: Node) {
        for (name, key, value) in entries(of: node, "ui.sidebar") {
            switch name {
            case "font_size":
                guard value.tag == Yams.Tag(.int) || value.tag == Yams.Tag(.float),
                      let size = value.float, size.isFinite, size > 0 else {
                    problem(at: value, "ui.sidebar.font_size: expected a finite number greater than zero points")
                    continue
                }
                config.sidebarTypography.fontSize = size
            case "font_family":
                guard value.tag == Yams.Tag(.str), let name = value.string,
                      !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      name.rangeOfCharacter(from: .controlCharacters) == nil else {
                    problem(at: value, "ui.sidebar.font_family: expected a nonempty font family name")
                    continue
                }
                guard let family = SidebarTypography.canonicalFamily(name, families: fontFamilies) else {
                    problem(at: value, "ui.sidebar.font_family: font family \"\(name.trimmingCharacters(in: .whitespacesAndNewlines))\" is not installed")
                    continue
                }
                config.sidebarTypography.fontFamily = family
            default:
                problem(at: key, "unknown key \"ui.sidebar.\(name)\"")
            }
        }
    }

    /// Old `keybindings` names and the actions that replaced them. A Config
    /// that names one gets a problem, so the old name never silently stops working.
    static let removedActions: [String: ConfigAction] = [
        "move_keyboard_to_terminal": .focusTerminal,
        "new_topic_from_pane": .movePane,
        "move_session_to_topic": .moveSession,
    ]

    /// The same for `keybindings.command_palette`. Its old move_* names are
    /// valid `keybindings` actions, so each scope keeps its own table.
    static let removedPaletteActions: [String: PaletteAction] = [
        "add_session": .addSessionToTopic,
        "settle": .settleTopic,
        "forget": .forgetTopic,
        "reopen": .reopenTopic,
        "start_fresh": .startTopicFresh,
        "pin": .pinTopic,
        "unpin": .unpinTopic,
        "copy_path": .copyFolder,
        "paste_path": .pasteFolder,
        "reveal": .revealFolder,
        "copy_target": .copyTmuxTarget,
        "move_pane": .choosePane,
        "move_window": .chooseWindow,
        "move_session": .chooseSession,
        "include_tab": .toggleIncludeTab,
        "new_worktree": .toggleNewWorktree,
    ]

    mutating func readKeybindings(_ node: Node) {
        for (name, key, value) in entries(of: node, "keybindings") {
            if name == "command_palette" {
                readPaletteKeybindings(value)
                continue
            }
            if name == "find" {
                readFindKeybindings(value)
                continue
            }
            if name == "open_switcher" {
                problem(at: key, "open_switcher is gone: the Go to… Command Palette replaces the Switcher; bind it in command_palettes")
                continue
            }
            if let renamed = Self.removedActions[name] {
                problem(at: key, "\(name) is gone: use \(renamed.rawValue)")
                continue
            }
            guard let action = ConfigAction(rawValue: name) else {
                problem(at: key, "unknown action \"\(name)\"")
                continue
            }
            guard let listed = triggers(in: value, of: name) else { continue }
            namedActions.append(action)
            claims += listed.map { Claim(owner: .action(action), trigger: $0.trigger, node: $0.node) }
        }
    }

    /// Only while a palette is open, so they never conflict with the others.
    mutating func readPaletteKeybindings(_ node: Node) {
        config.paletteKeybinds = scopedKeybindings(node, "keybindings.command_palette", kind: "Command Palette",
                                                   removed: Self.removedPaletteActions)
    }

    /// Only while a find field has Focus, so they never conflict with the others.
    mutating func readFindKeybindings(_ node: Node) {
        config.findKeybinds = scopedKeybindings(node, "keybindings.find", kind: "find", removed: [:])
    }

    /// The keybinds of a scope that acts on its own, with the overlay rules among themselves.
    private mutating func scopedKeybindings<Action: KeybindAction>(_ node: Node, _ place: String, kind: String,
                                                                   removed: [String: Action]) -> KeybindSet<Action> {
        var named: [Action] = []
        var claims: [Claim<Action>] = []
        for (name, key, value) in entries(of: node, place) {
            if let renamed = removed[name] {
                problem(at: key, "\(name) is gone: use \(renamed.rawValue)")
                continue
            }
            guard let action = Action(rawValue: name) else {
                problem(at: key, "unknown \(kind) action \"\(name)\"")
                continue
            }
            guard let listed = triggers(in: value, of: name) else { continue }
            named.append(action)
            claims += listed.map { Claim(owner: action, trigger: $0.trigger, node: $0.node) }
        }
        let kept = resolve(claims, describe: \.rawValue) { $0.canShareTrigger(with: $1) }
        let claimed = Set(kept.values.joined())
        return overlay(named: named, kept: kept) { _, trigger in claimed.contains(trigger) }
    }

    mutating func readCommandPalettes(_ node: Node) {
        guard let sequence = node.sequence else {
            problem(at: node, "command_palettes: expected a list")
            return
        }
        var palettes: [CommandPaletteConfig] = []
        for item in sequence {
            let problemCount = config.problems.count
            var values: [String: Node] = [:]
            for (name, key, value) in entries(of: item, "a Command Palette") {
                guard ["name", "keybinding", "sources", "order", "tiebreak", "show"].contains(name) else {
                    problem(at: key, "unknown Command Palette key \"\(name)\"")
                    continue
                }
                values[name] = value
            }
            let name = values["name"].flatMap(string)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if name?.isEmpty != false || name?.rangeOfCharacter(from: .controlCharacters) != nil {
                problem(at: values["name"] ?? item, "Command Palette name: expected a nonempty string")
            } else if let name, palettes.contains(where: { $0.name == name }) {
                problem(at: values["name"] ?? item, "Command Palette name \"\(name)\" is already used")
            }
            var sources: [PaletteSource] = []
            for value in values["sources"].map({ $0.sequence ?? [$0] }) ?? [] {
                guard let source = string(value).flatMap(PaletteSource.init(rawValue:)) else {
                    problem(at: value, "Command Palette sources: expected topics, sessions, windows, agents or commands")
                    continue
                }
                if !sources.contains(source) { sources.append(source) }
            }
            if sources.isEmpty, config.problems.count == problemCount {
                problem(at: values["sources"] ?? item, "Command Palette sources: expected a list of topics, sessions, windows, agents or commands")
            }
            var order = PaletteOrder.grouped
            if let value = values["order"] {
                if let parsed = string(value).flatMap(PaletteOrder.init(rawValue:)) { order = parsed } else {
                    problem(at: value, "Command Palette order: expected grouped or ranked")
                }
            }
            let rules = readPickRules(values, label: { "Command Palette " + $0 }, kinds: RowKind.all)
            guard config.problems.count == problemCount, let name, let rules else { continue }
            palettes.append(CommandPaletteConfig(name: name, triggers: [], sources: sources, order: order, rules: rules))
            // A bad trigger is skipped; the palette still applies.
            if let value = values["keybinding"], value.null == nil, let listed = triggers(in: value, of: "Command Palette keybinding") {
                claims += listed.map { Claim(owner: .palette(name), trigger: $0.trigger, node: $0.node) }
            }
        }
        self.palettes = palettes
    }

    /// A bad entry is left out with a problem, so its list keeps every kind and the standard tiebreak.
    mutating func readPickLists(_ node: Node) {
        for (name, key, value) in entries(of: node, "pick_lists") {
            guard let list = ActionList(rawValue: name) else {
                problem(at: key, "unknown pick list \"\(name)\": expected " + spelledOut(ActionList.allCases.map(\.rawValue)))
                continue
            }
            let problemCount = config.problems.count
            var values: [String: Node] = [:]
            for (keyName, key, value) in entries(of: value, "pick_lists.\(name)") {
                guard ["show", "tiebreak"].contains(keyName) else {
                    problem(at: key, "unknown key \"pick_lists.\(name).\(keyName)\"")
                    continue
                }
                values[keyName] = value
            }
            let rules = readPickRules(values, label: { "pick_lists.\(name).\($0)" }, kinds: list.kinds)
            guard config.problems.count == problemCount, let rules else { continue }
            config.pickLists[list] = rules
        }
    }

    /// The `show` and `tiebreak` keys of a Command Palette or a `pick_lists` entry, which `values` holds when they are
    /// set. Nil, with a problem, when `show` is empty or names a word outside `kinds`, or a tiebreak word is unknown.
    private mutating func readPickRules(_ values: [String: Node], label: (String) -> String, kinds: Set<RowKind>) -> PickRules? {
        var rules = PickRules.standard
        var valid = true
        let kindWords = spelledOut(RowKind.allCases.filter(kinds.contains).map(\.rawValue))
        if let node = values["show"] {
            var show: Set<RowKind> = []
            for value in node.sequence ?? [node] {
                guard let kind = string(value).flatMap(RowKind.init(rawValue:)), kinds.contains(kind) else {
                    problem(at: value, label("show") + ": expected " + kindWords)
                    valid = false
                    continue
                }
                show.insert(kind)
            }
            if show.isEmpty, valid {
                problem(at: node, label("show") + ": expected a list of " + kindWords)
                valid = false
            }
            rules.show = show
        }
        var tiebreak: [PaletteTiebreak] = []
        for value in values["tiebreak"].map({ $0.sequence ?? [$0] }) ?? [] {
            guard let rule = string(value).flatMap(PaletteTiebreak.init(rawValue:)) else {
                problem(at: value, label("tiebreak") + ": expected open, running, visit, activity or length")
                valid = false
                continue
            }
            if !tiebreak.contains(rule) { tiebreak.append(rule) }
        }
        if !tiebreak.isEmpty { rules.tiebreak = tiebreak }
        return valid ? rules : nil
    }

    /// The overlay rules across `keybindings` and `command_palettes`. An
    /// action the user named has only the triggers listed for it; so does a
    /// palette the Config defines. The default palettes keep their defaults
    /// minus any trigger listed for another; an action not named keeps the
    /// defaults no listed trigger takes from it (`takesDefault(_:from:)`).
    private mutating func resolveKeybindings() {
        let kept = resolve(claims, describe: \.description) { $0.canShareTrigger(with: $1) }
        let claimed = Set(kept.values.joined())
        var actions: [ConfigAction: [KeyTrigger]] = [:]
        for case let (.action(action), triggers) in kept { actions[action] = triggers }
        config.keybinds = overlay(named: namedActions, kept: actions) { action, trigger in
            kept.contains { claimant, triggers in triggers.contains(trigger) && claimant.takesDefault(trigger, from: action) }
        }
        if let palettes {
            config.commandPalettes = palettes.map { palette in
                var palette = palette
                palette.triggers = kept[.palette(palette.name)] ?? []
                return palette
            }
        } else {
            config.commandPalettes = CommandPaletteConfig.defaults.map { palette in
                var palette = palette
                palette.triggers.removeAll(where: claimed.contains)
                return palette
            }
        }
    }

    /// A trigger listed for two owners that cannot share it stays with the
    /// first.
    private mutating func resolve<Owner: Hashable>(_ claims: [Claim<Owner>], describe: (Owner) -> String,
                                                   canShare: (Owner, Owner) -> Bool) -> [Owner: [KeyTrigger]] {
        var owners: [KeyTrigger: [Owner]] = [:]
        var kept: [Owner: [KeyTrigger]] = [:]
        for claim in claims {
            let current = owners[claim.trigger, default: []]
            if current.contains(claim.owner) { continue }
            if let owner = current.first(where: { !canShare(claim.owner, $0) }) {
                problem(at: claim.node, "\(claim.node.string ?? "") is already bound to \(describe(owner))")
                continue
            }
            owners[claim.trigger, default: []].append(claim.owner)
            kept[claim.owner, default: []].append(claim.trigger)
        }
        return kept
    }

    private func overlay<Action: KeybindAction>(named: [Action], kept: [Action: [KeyTrigger]],
                                                takenFrom: (Action, KeyTrigger) -> Bool) -> KeybindSet<Action> {
        var triggers: [Action: [KeyTrigger]] = [:]
        for action in Action.allCases {
            triggers[action] = named.contains(action)
                ? kept[action] ?? []
                : Action.defaultTriggers[action, default: []].filter { !takenFrom(action, $0) }
        }
        return KeybindSet(triggers: triggers)
    }

    /// One trigger or a list of them. A bad item of a list is skipped; a bad
    /// single value skips the setting, so it keeps its defaults.
    private mutating func triggers(in node: Node, of setting: String) -> [(trigger: KeyTrigger, node: Node)]? {
        if let sequence = node.sequence {
            return sequence.compactMap { trigger(in: $0, of: setting) }
        }
        return trigger(in: node, of: setting).map { [$0] }
    }

    private mutating func trigger(in node: Node, of setting: String) -> (trigger: KeyTrigger, node: Node)? {
        guard let spelling = string(node) else {
            problem(at: node, "\(setting): expected a trigger or a list of triggers")
            return nil
        }
        do {
            return (try KeyTrigger(spelling), node)
        } catch {
            problem(at: node, "\(error)")
            return nil
        }
    }

    private mutating func entries(of node: Node, _ place: String) -> [(name: String, key: Node, value: Node)] {
        guard let mapping = node.mapping else {
            problem(at: node, "\(place): expected a mapping")
            return []
        }
        return mapping.map { ($0.key.string ?? "", $0.key, $0.value) }
    }

    /// One value for both Sidebar modes, or a mapping with a value for `topics`, `sessions` or both.
    /// A mode that the mapping leaves out keeps `current`.
    private mutating func perMode<Value>(_ node: Node, _ place: String, _ current: Config.Sidebar.PerMode<Value>,
                                         expected: String, parse: (Node) throws -> Value?) -> Config.Sidebar.PerMode<Value> {
        guard node.mapping != nil else {
            do {
                guard let value = try parse(node) else {
                    problem(at: node, "\(place): expected \(expected)")
                    return current
                }
                return Config.Sidebar.PerMode(value)
            } catch {
                problem(at: node, "\(place): \(error)")
                return current
            }
        }
        var result = current
        for (name, key, value) in entries(of: node, place) {
            let modes: [String: SidebarMode] = ["topics": .topics, "sessions": .sessions]
            guard let mode = modes[name] else {
                problem(at: key, "unknown key \"\(place).\(name)\"")
                continue
            }
            do {
                guard let parsed = try parse(value) else {
                    problem(at: value, "\(place).\(name): expected \(expected)")
                    continue
                }
                result[mode] = parsed
            } catch {
                problem(at: value, "\(place).\(name): \(error)")
            }
        }
        return result
    }

    /// One color, or a mapping with one color for `light` and one for `dark` appearance. Nil after a problem.
    private mutating func markColor(_ node: Node, _ place: String) -> MarkColor? {
        let expected = Self.expectedColor
        func single(_ node: Node) -> MarkColor.Single? { color(node) }
        guard node.mapping != nil else {
            guard let color = single(node) else {
                problem(at: node, "\(place): \(expected), or a mapping with light and dark")
                return nil
            }
            return .single(color)
        }
        let fields = entries(of: node, place)
        var colors: [String: MarkColor.Single] = [:]
        var valid = true
        for (name, key, value) in fields {
            guard ["light", "dark"].contains(name) else {
                problem(at: key, "unknown key \"\(place).\(name)\"")
                valid = false
                continue
            }
            guard let color = single(value) else {
                problem(at: value, "\(place).\(name): \(expected)")
                valid = false
                continue
            }
            colors[name] = color
        }
        let missing = ["light", "dark"].filter { side in !fields.contains { $0.name == side } }
        if !missing.isEmpty {
            problem(at: node, "\(place): missing \(missing.joined(separator: " and "))")
        }
        guard valid, let light = colors["light"], let dark = colors["dark"] else { return nil }
        return .pair(light: light, dark: dark)
    }

    /// One color, the same in light and dark appearance. Nil after a problem.
    private mutating func singleColor(_ node: Node, _ place: String) -> MarkColor.Single? {
        guard let color = color(node) else {
            problem(at: node, "\(place): \(Self.expectedColor)")
            return nil
        }
        return color
    }

    private static let expectedColor = "expected one of \(SystemColorName.allCases.map(\.rawValue).joined(separator: ", ")), or a quoted '#RRGGBB'"

    // An unquoted #RRGGBB is a YAML comment, so it arrives here as null.
    private func color(_ node: Node) -> MarkColor.Single? {
        guard node.tag == Yams.Tag(.str), let text = string(node) else { return nil }
        return MarkColor.Single(text)
    }

    /// One opacity, or a mapping with one for `light` and one for `dark` appearance. Nil after a problem.
    private mutating func appearanceOpacity(_ node: Node, _ place: String) -> AppearanceOpacity? {
        let expected = "expected a number above 0 and at most 1"
        func single(_ node: Node) -> Double? {
            guard node.mapping == nil, let value = node.float, value > 0, value <= 1 else { return nil }
            return value
        }
        guard node.mapping != nil else {
            guard let opacity = single(node) else {
                problem(at: node, "\(place): \(expected), or a mapping with light and dark")
                return nil
            }
            return AppearanceOpacity(light: opacity, dark: opacity)
        }
        let fields = entries(of: node, place)
        var opacities: [String: Double] = [:]
        var valid = true
        for (name, key, value) in fields {
            guard ["light", "dark"].contains(name) else {
                problem(at: key, "unknown key \"\(place).\(name)\"")
                valid = false
                continue
            }
            guard let opacity = single(value) else {
                problem(at: value, "\(place).\(name): \(expected)")
                valid = false
                continue
            }
            opacities[name] = opacity
        }
        let missing = ["light", "dark"].filter { side in !fields.contains { $0.name == side } }
        if !missing.isEmpty {
            problem(at: node, "\(place): missing \(missing.joined(separator: " and "))")
        }
        guard valid, let light = opacities["light"], let dark = opacities["dark"] else { return nil }
        return AppearanceOpacity(light: light, dark: dark)
    }

    /// A scalar other than null (empty, `~` or `null`).
    private func string(_ node: Node) -> String? {
        guard let scalar = node.scalar, node.null == nil else { return nil }
        return scalar.string
    }

    private mutating func problem(at node: Node, _ message: String) {
        config.problems.append(ConfigProblem(path: path, line: node.mark?.line ?? 1, message: message))
    }
}
