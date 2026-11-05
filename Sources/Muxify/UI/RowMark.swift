import SwiftUI
import MuxifyCore

enum RowMark: Equatable {
    case unread
    case agent(AgentMark)

    init?(unread: Bool, agent: AgentMark?) {
        if let agent, agent == .blocked || agent == .failed { self = .agent(agent) }
        else if unread { self = .unread }
        else if let agent { self = .agent(agent) }
        else { return nil }
    }

    var rawValue: String {
        switch self {
        case .unread: return "unread"
        case .agent(let mark): return mark.rawValue
        }
    }

    func color(_ colors: AgentColors) -> Color {
        switch self {
        case .unread: return .accentColor
        case .agent(let mark): return colors[mark].color
        }
    }
}

struct RowMarkView: View {
    let mark: RowMark
    /// The dot's size; by default 7 at 12, grown with the Interface font size, as it sits beside a row's text.
    var dotSize: CGFloat? = nil
    @Environment(\.interfaceFontSize) private var fontSize

    var body: some View {
        let dotSize = dotSize ?? fontSize(AgentMarkView.designDotSize)
        switch mark {
        case .unread: Circle().fill(Color.accentColor).frame(width: dotSize, height: dotSize)
        case .agent(let mark): AgentMarkView(mark: mark, dotSize: dotSize)
        }
    }
}

struct RowMarkSpine: View {
    let mark: RowMark

    var body: some View {
        switch mark {
        case .unread: RoundedRectangle(cornerRadius: 2).fill(Color.accentColor)
        case .agent(let mark): AgentMarkSpine(mark: mark)
        }
    }
}
