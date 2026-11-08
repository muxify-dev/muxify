import SwiftUI
import MuxifyCore

extension CardMark {
    func color(_ colors: AgentColors) -> Color {
        switch self {
        case .unread: return .accentColor
        case .agent(let mark): return colors[mark].color
        }
    }
}

struct RowMarkView: View {
    let mark: CardMark
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
    let mark: CardMark

    var body: some View {
        switch mark {
        case .unread: RoundedRectangle(cornerRadius: 2).fill(Color.accentColor)
        case .agent(let mark): AgentMarkSpine(mark: mark)
        }
    }
}
