import AppKit
import SwiftUI

/// Where an item dragged in a list lands: before or after another item of the list.
enum DropPlacement<ID: Hashable>: Equatable {
    case before(ID)
    case after(ID)

    var anchor: ID {
        switch self {
        case .before(let id), .after(let id): return id
        }
    }

    /// `list` with `id` moved here; `list` itself when the anchor is not in it.
    func placing(_ id: ID, in list: [ID]) -> [ID] {
        var rest = list.filter { $0 != id }
        guard let index = rest.firstIndex(of: anchor) else { return list }
        switch self {
        case .before: rest.insert(id, at: index)
        case .after: rest.insert(id, at: index + 1)
        }
        return rest
    }
}

/// A list's items stacked by their heights, with `spacing` between two items, measured from the top of the first.
struct StackLayout<ID: Hashable> {
    var heights: [ID: CGFloat]
    var spacing: CGFloat

    func top(of id: ID, in order: [ID]) -> CGFloat {
        var top: CGFloat = 0
        for item in order {
            if item == id { break }
            top += height(item) + spacing
        }
        return top
    }

    func height(_ id: ID) -> CGFloat { heights[id] ?? 0 }

    /// Where `id` lands after it moved `translation` down from its place in `order`: before the first item above it
    /// whose middle its top edge passed, after the last item below it whose middle its bottom edge passed, or nil at
    /// its own place. Each edge leads the way it moves, so a tall item passes a short one as soon as it covers half of it.
    func placement(of id: ID, movedBy translation: CGFloat, in order: [ID]) -> DropPlacement<ID>? {
        guard let index = order.firstIndex(of: id) else { return nil }
        let top = top(of: id, in: order) + translation
        let bottom = top + height(id)
        let middle = { (item: ID) in self.top(of: item, in: order) + self.height(item) / 2 }
        if let passed = order[..<index].first(where: { top < middle($0) }) { return .before(passed) }
        if let passed = order[(index + 1)...].last(where: { bottom > middle($0) }) { return .after(passed) }
        return nil
    }

    /// `translation` held so `id` stays within the list, from the top of its first item to the bottom of its last, and
    /// moves up no more than `headroom`. An item that is already past the headroom does not move up at all.
    func bounded(_ translation: CGFloat, of id: ID, in order: [ID], headroom: CGFloat = .infinity) -> CGFloat {
        guard let last = order.last else { return translation }
        let top = top(of: id, in: order)
        let low = max(-top, -max(headroom, 0))
        let high = max(low, self.top(of: last, in: order) + height(last) - top - height(id))
        return min(max(translation, low), high)
    }
}

/// The drag of a list's items. A press that moves a few points lifts the item at once, and a press that lets go before
/// that is a click. The lifted item follows the pointer, and the items it passes slide aside to leave a placeholder
/// where it would land. Let go, it glides into the placeholder and stays there until the list shows the
/// new order, so nothing jumps. A list holds one for all its items, since only one item moves at a time.
@MainActor @Observable
final class ListDrag<ID: Hashable> {
    enum Phase: Equatable {
        case idle
        case pressing(ID)
        case lifted(ID)
        /// Let go: the item glides to where it lands and stays there until the list shows the new order.
        case settling(ID)
    }

    /// How long a dropped item waits for the list to show the new order before the list goes back to the order it shows.
    private static var settleLimit: Duration { .seconds(3) }
    /// A lifted item grows by this much around this point.
    static var liftScale: CGFloat { 1.03 }
    static var liftAnchor: UnitPoint { UnitPoint(x: 0.5, y: 0.3) }

    private(set) var phase: Phase = .idle
    /// How far the lifted item follows the pointer. Only the lifted item reads it, so the others do not draw again as the
    /// pointer moves.
    private(set) var translation: CGFloat = 0
    /// Where the lifted item would land; nil at its own place.
    private(set) var placement: DropPlacement<ID>?
    /// The items' heights when the item lifted.
    private(set) var layout: StackLayout<ID>
    @ObservationIgnored private var heights: [ID: CGFloat] = [:]
    /// How far each item's top is below the top of the scroll view's visible part, or below a card header that sticks there.
    @ObservationIgnored private var visibleTops: [ID: CGFloat] = [:]
    /// How far the lifted item may move up before its top leaves the visible part of the scroll view.
    @ObservationIgnored private var headroom: CGFloat = .infinity
    /// Each item's list as its stack shows it now. One drag can serve several lists, such as the Pinned Topics and the others.
    @ObservationIgnored private var lists: [ID: [ID]] = [:]
    /// The lifted item's list when it lifted.
    @ObservationIgnored private var order: [ID] = []
    @ObservationIgnored private var timer: Task<Void, Never>?

    /// `spacing` is the room between two items in the list's stack.
    init(spacing: CGFloat) {
        layout = StackLayout(heights: [:], spacing: spacing)
    }

    /// The lifted or settling item.
    var dragged: ID? {
        switch phase {
        case .lifted(let id), .settling(let id): return id
        default: return nil
        }
    }

    /// How far `id` moves from its place in `shown`, its list as the stack shows it now, to its place in the order
    /// that the dragged item's placement makes. Zero once the stack shows that order.
    func shift(of id: ID, in shown: [ID]) -> CGFloat {
        guard let dragged, let placement, shown.contains(dragged) else { return 0 }
        return layout.top(of: id, in: placement.placing(dragged, in: shown)) - layout.top(of: id, in: shown)
    }

    /// An item reports its height, its place in the scroll view and its list each time they change.
    func measure(_ id: ID, height: CGFloat, visibleTop: CGFloat) {
        heights[id] = height
        visibleTops[id] = visibleTop
    }

    func show(_ shown: [ID], at id: ID) {
        lists[id] = shown
        guard phase == .settling(id), let placement, placement.placing(id, in: shown) == shown else { return }
        // The stack lays the items out where they were drawn, so the drag ends without moving anything.
        timer?.cancel()
        withTransaction(Transaction(animation: nil)) {
            phase = .idle
            self.placement = nil
        }
    }

    func press(_ id: ID) {
        timer?.cancel()
        withTransaction(Transaction(animation: nil)) { placement = nil }
        phase = .pressing(id)
    }

    /// The pressed item moved far enough to be a drag.
    func lift(_ id: ID) {
        guard phase == .pressing(id) else { return }
        order = lists[id] ?? [id]
        layout.heights = heights.filter { order.contains($0.key) }
        // Grown by the lift, its top stands a little higher than its place.
        headroom = (visibleTops[id] ?? .infinity) - (Self.liftScale - 1) * Self.liftAnchor.y * layout.height(id)
        translation = 0
        withAnimation(.spring(duration: 0.25, bounce: 0.3)) { phase = .lifted(id) }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        NSCursor.closedHand.push()
    }

    func follow(_ id: ID, translation: CGFloat) {
        guard phase == .lifted(id) else { return }
        self.translation = layout.bounded(translation, of: id, in: order, headroom: headroom)
        let placement = layout.placement(of: id, movedBy: self.translation, in: order)
        guard placement != self.placement else { return }
        withAnimation(.spring(duration: 0.3, bounce: 0.15)) { self.placement = placement }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    /// The pointer moved on an item that cannot move: the press is neither a click nor a drag.
    func cancel() {
        timer?.cancel()
        withAnimation(.spring(duration: 0.25)) { phase = .idle }
    }

    /// The press on `id` ended: a click if the item did not lift. A lifted item glides to where it lands, and `onDrop`
    /// gets its placement once it is there; with no placement it glides back.
    func end(_ id: ID, onTap: () -> Void, onDrop: @escaping (DropPlacement<ID>) -> Void) {
        timer?.cancel()
        switch phase {
        case .pressing(id):
            phase = .idle
            onTap()
        case .lifted(id):
            NSCursor.pop()
            let placement = placement
            withAnimation(.spring(duration: 0.3, bounce: 0.15)) {
                phase = .settling(id)
            } completion: { [weak self] in
                guard let self, phase == .settling(id) else { return }
                guard let placement else {
                    phase = .idle
                    return
                }
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                // The list shows the new order at once or after tmux answers; `show` then ends the drag.
                onDrop(placement)
                timer = Task { [weak self] in
                    try? await Task.sleep(for: Self.settleLimit)
                    guard let self, !Task.isCancelled, phase == .settling(id) else { return }
                    withAnimation(.spring(duration: 0.3)) {
                        self.phase = .idle
                        self.placement = nil
                    }
                }
            }
        default:
            break
        }
    }

    /// The press on `id` stopped without an end, as when its view went away: a lifted item glides back.
    func abandon(_ id: ID) {
        switch phase {
        case .pressing(id):
            cancel()
        case .lifted(id):
            NSCursor.pop()
            withAnimation(.spring(duration: 0.3)) {
                phase = .idle
                placement = nil
            }
        default:
            break
        }
    }
}

private struct ListDragHandle<ID: Hashable>: ViewModifier {
    let id: ID
    let drag: ListDrag<ID>
    let isEnabled: Bool
    let onTap: () -> Void
    let onDrop: (DropPlacement<ID>) -> Void

    /// The pointer moved on an item that cannot move: the press is neither a click nor a drag.
    @State private var cancelled = false
    @GestureState private var isPressed = false

    /// How far the pointer moves before the press is a drag; a press that moves less is still a click.
    private static var slop: CGFloat { 4 }

    func body(content: Content) -> some View {
        // Before the gestures inside, such as a Window row's Button, which then keeps only its accessibility press.
        content.highPriorityGesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .updating($isPressed) { _, pressed, _ in pressed = true }
            .onChanged(changed)
            .onEnded(ended))
            .takesFirstClick()
            .onChange(of: isPressed) { _, pressed in
                if !pressed { drag.abandon(id) }
            }
    }

    private func changed(_ value: DragGesture.Value) {
        guard !cancelled else { return }
        switch drag.phase {
        case .lifted(id):
            drag.follow(id, translation: value.translation.height)
        case .pressing(id):
            guard hypot(value.translation.width, value.translation.height) > Self.slop else { return }
            if isEnabled {
                drag.lift(id)
                drag.follow(id, translation: value.translation.height)
            } else {
                cancelled = true
                drag.cancel()
            }
        default:
            drag.press(id)
        }
    }

    private func ended(_ value: DragGesture.Value) {
        guard !cancelled else {
            cancelled = false
            return
        }
        drag.end(id, onTap: onTap, onDrop: onDrop)
    }
}

private struct ListDragItem<ID: Hashable>: ViewModifier {
    let id: ID
    let drag: ListDrag<ID>
    let shown: [ID]
    let cornerRadius: CGFloat
    @Environment(\.chromeTheme) private var chromeTheme
    @Environment(\.dragTopInset) private var topInset

    func body(content: Content) -> some View {
        let isLifted = drag.phase == .lifted(id)
        let isDragged = isLifted || drag.phase == .settling(id)
        // Its own place in the new order for the dropped item, the placeholder's place for the lifted one, and for the
        // others the place they slide aside to.
        let shift = drag.shift(of: id, in: shown)
        content
            .transformEnvironment(\.isLiftedByDrag) { if isLifted { $0 = true } }
            .background {
                if isLifted { plate.transition(.opacity) }
            }
            .scaleEffect(isLifted ? ListDrag<ID>.liftScale : 1, anchor: ListDrag<ID>.liftAnchor)
            .shadow(color: .black.opacity(isLifted ? 0.4 : 0), radius: isLifted ? 14 : 0, y: isLifted ? 10 : 0)
            .animation(.spring(duration: 0.25, bounce: 0.3), value: isLifted)
            .offset(y: isLifted ? drag.translation : shift)
            // The lifted item stays under the pointer while the others slide; let go, it glides.
            .transaction { if isLifted { $0.animation = nil } }
            .background(alignment: .top) {
                if isLifted { DropSlot(cornerRadius: cornerRadius).offset(y: shift).transition(.opacity) }
            }
            // Its place without its own offset, in the visible part of the list's scroll view.
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .scrollView) } action: { frame in
                drag.measure(id, height: frame.height, visibleTop: frame.minY - topInset)
            }
            .onChange(of: shown, initial: true) { _, shown in drag.show(shown, at: id) }
            // The Window or Session it stands for went away while it was lifted.
            .onDisappear { drag.abandon(id) }
            // Last, so the stack around the item sees it.
            .zIndex(isDragged ? 30 : 0)
    }

    /// What the lifted item stands on, so the items it passes over do not show through it.
    private var plate: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return ZStack {
            Color.clear.chrome(theme: chromeTheme, material: .sidebar)
            Color.primary.opacity(0.1)
        }
        .clipShape(shape)
        .overlay { shape.strokeBorder(Color.primary.opacity(0.14), lineWidth: 1) }
    }
}

private struct LiftedByDragKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// The view is in an item that a `ListDrag` lifted: it follows the pointer, not its place in the list.
    var isLiftedByDrag: Bool {
        get { self[LiftedByDragKey.self] }
        set { self[LiftedByDragKey.self] = newValue }
    }
}

private struct DragTopInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// How far below the top of the scroll view a lifted item stops: the bottom of a card header that sticks there.
    var dragTopInset: CGFloat {
        get { self[DragTopInsetKey.self] }
        set { self[DragTopInsetKey.self] = newValue }
    }
}

/// The place a lifted item would land: a slot of its size, outlined.
private struct DropSlot: View {
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape.fill(Color.accentColor.opacity(0.08))
            .overlay { shape.strokeBorder(Color.accentColor.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])) }
            .allowsHitTesting(false)
    }
}

extension View {
    /// Makes the view the handle of a `ListDrag` item: a click calls `onTap`, a press that moves lifts the item, and
    /// letting go of a lifted item calls `onDrop` with its placement once it glided there. While disabled, a press that
    /// moves does nothing and a click still works.
    func listDrag<ID: Hashable>(_ id: ID, drag: ListDrag<ID>, isEnabled: Bool = true, onTap: @escaping () -> Void,
                                     onDrop: @escaping (DropPlacement<ID>) -> Void) -> some View {
        modifier(ListDragHandle(id: id, drag: drag, isEnabled: isEnabled, onTap: onTap, onDrop: onDrop))
    }

    /// Makes the view an item of a `ListDrag` list, whose handle may be the view or a part of it. `shown` is its
    /// list as the stack shows it now, and `cornerRadius` the item's corners, for the plate it stands on while lifted
    /// and the placeholder where it would land.
    func listDragItem<ID: Hashable>(_ id: ID, drag: ListDrag<ID>, shown: [ID], cornerRadius: CGFloat) -> some View {
        modifier(ListDragItem(id: id, drag: drag, shown: shown, cornerRadius: cornerRadius))
    }

    /// A press in a window that is not key reaches this view's gestures, so a click or a drag works on the first click.
    @ViewBuilder
    func takesFirstClick() -> some View {
        if #available(macOS 15, *) { allowsWindowActivationEvents(true) } else { self }
    }
}
