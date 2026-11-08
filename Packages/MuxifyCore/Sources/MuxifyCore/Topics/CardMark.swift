import Foundation

/// The one mark that a card or a Session row shows, on every surface.
public enum CardMark: RawRepresentable, Codable, Hashable, Sendable {
    case unread
    case agent(AgentMark)

    /// A blocked or failed Agent first, then Unread, then the other Agent marks. Nil shows no mark.
    public init?(unread: Bool, agent: AgentMark?) {
        if let agent, agent == .blocked || agent == .failed { self = .agent(agent) }
        else if unread { self = .unread }
        else if let agent { self = .agent(agent) }
        else { return nil }
    }

    /// `unread`, or the name of the Agent mark.
    public var rawValue: String {
        switch self {
        case .unread: return "unread"
        case .agent(let mark): return mark.rawValue
        }
    }

    public init?(rawValue: String) {
        if rawValue == "unread" { self = .unread }
        else if let mark = AgentMark(rawValue: rawValue) { self = .agent(mark) }
        else { return nil }
    }
}
