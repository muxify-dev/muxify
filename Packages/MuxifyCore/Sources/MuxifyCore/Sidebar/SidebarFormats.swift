import Foundation

public struct SidebarFormats: Equatable {
    public enum Object: String, CaseIterable { case topic, session, window, pane, agent }

    public struct Lines: Equatable {
        public var title: Config.Sidebar.PerMode<SidebarFormat>
        public var summary: Config.Sidebar.PerMode<SidebarFormat>

        fileprivate init(title: String, summary: String = "") {
            self.title = .init(try! SidebarFormat(title))
            self.summary = .init(try! SidebarFormat(summary))
        }
    }

    public struct WindowParts: Equatable {
        public var left = Config.Sidebar.PerMode<SidebarPartFormat?>(nil)
        public var right = Config.Sidebar.PerMode<SidebarPartFormat?>(nil)
    }

    public struct WindowRowContent: Equatable {
        public let text: Text
        public let left: [SidebarPart]?
        public let right: [SidebarPart]?
    }

    public struct Text: Equatable {
        public let title: String
        public let summary: String
    }

    private static let windowCount = "#{window_count} #{?#{==:#{window_count},1},Window,Windows}"
    public static let defaults = SidebarFormats()
    public var topic = Lines(title: "#{topic_title}", summary: "#{?session_count,#{S:#{session_base_name}#{?loop_last_flag,, · }} · " + windowCount + ",No Sessions}")
    public var session = Lines(title: "#{session_name}", summary: windowCount)
    public var window = Lines(title: "#{window_title}")
    public var windowParts = WindowParts()
    public var pane = Lines(title: "#{pane_label}")
    public var agent = Lines(title: "#{pane_label}", summary: "#{agent_group}")
    /// The Tags of a Topic card. Topic cards show only in Topics mode, so the `sessions` value has no card to show on.
    public var topicTags = Config.Sidebar.PerMode(try! SidebarTagsFormat("#{T:#{tag}}"))

    public init() {}

    public subscript(object: Object) -> Lines {
        get {
            switch object {
            case .topic: return topic
            case .session: return session
            case .window: return window
            case .pane: return pane
            case .agent: return agent
            }
        }
        set {
            switch object {
            case .topic: topic = newValue
            case .session: session = newValue
            case .window: window = newValue
            case .pane: pane = newValue
            case .agent: agent = newValue
            }
        }
    }

    public func windowRow(in context: SidebarFormat.Context, mode: SidebarMode) -> WindowRowContent {
        WindowRowContent(text: text(for: .window, in: context, mode: mode),
                         left: windowParts.left[mode]?.expand(in: context),
                         right: windowParts.right[mode]?.expand(in: context))
    }

    public func text(for object: Object, in context: SidebarFormat.Context, mode: SidebarMode) -> Text {
        let lines = self[object]
        let title = lines.title[mode].expand(in: context)
        return Text(title: title.isEmpty ? Self.defaults[object].title[mode].expand(in: context) : title,
                    summary: lines.summary[mode].expand(in: context))
    }
}
