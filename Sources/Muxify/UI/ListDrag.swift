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

    /// `slots` with `id` moved here. The fixed slots keep their places, and the items fill the others in their new order.
    func placing(_ id: ID, in slots: [StackSlot<ID>]) -> [StackSlot<ID>] {
        var items = placing(id, in: slots.compactMap(\.item)).makeIterator()
        return slots.compactMap { slot in slot.item == nil ? slot : items.next().map(StackSlot.item) }
    }
}

/// Where a lifted item would land, away from its own place.
enum DropLanding<ID: Hashable>: Equatable {
    /// On its own side of the list's divider, next to another item.
    case place(DropPlacement<ID>)
    /// Across the divider, on the item it trades places with; nil while it is over no item there.
    case across(trade: ID?)
}

/// A place in a list's stack: an item that a drag moves, or a fixed view between the items, such as a line. A fixed
/// view keeps the number of slots above it, so it slides only when the items above it change height.
enum StackSlot<ID: Hashable>: Hashable {
    case item(ID)
    case fixed(String)

    var item: ID? {
        if case .item(let id) = self { return id }
        return nil
    }
}

/// A list's slots stacked by their heights, with `spacing` between two slots, measured from the top of the first.
struct StackLayout<ID: Hashable> {
    var heights: [StackSlot<ID>: CGFloat]
    var spacing: CGFloat
    /// How far the slots after the list's last fixed slot stand above their stacked place: the scroll of the area they
    /// scroll in alone, such as the Bench under the line, while the slots up to the fixed ones stay. Zero in a list
    /// with one scroll, so every top, landing and bound is in the terms of the screen.
    var areaScroll: CGFloat = 0

    func top(of slot: StackSlot<ID>, in order: [StackSlot<ID>]) -> CGFloat {
        var top: CGFloat = 0
        for other in order {
            if other == slot { break }
            top += height(other) + spacing
        }
        guard areaScroll != 0, let index = order.firstIndex(of: slot),
              let lastFixed = order.lastIndex(where: { $0.item == nil }), index > lastFixed else { return top }
        return top - areaScroll
    }

    func height(_ slot: StackSlot<ID>) -> CGFloat { heights[slot] ?? 0 }

    /// Where `id` lands after it moved `translation` down from its place in `order`: before the first item above it
    /// whose middle its top edge passed, after the last item below it whose middle its bottom edge passed, or nil at
    /// its own place. Each edge leads the way it moves, so a tall item passes a short one as soon as it covers half of it.
    /// A fixed slot is no place to land, so the item passes it as it passes the gap between two items.
    /// Only the slots in `side` are places to land.
    func placement(of id: ID, movedBy translation: CGFloat, in order: [StackSlot<ID>],
                   side: Range<Int>? = nil) -> DropPlacement<ID>? {
        guard let index = order.firstIndex(of: .item(id)) else { return nil }
        let side = side ?? order.indices
        let top = top(of: .item(id), in: order) + translation
        let bottom = top + height(.item(id))
        let middle = { (slot: StackSlot<ID>) in self.top(of: slot, in: order) + self.height(slot) / 2 }
        if let passed = order[side.lowerBound..<index].first(where: { $0.item != nil && top < middle($0) })?.item {
            return .before(passed)
        }
        if let passed = order[(index + 1)..<side.upperBound].last(where: { $0.item != nil && bottom > middle($0) })?.item {
            return .after(passed)
        }
        return nil
    }

    /// Where `id` lands after it moved `translation` down, in a list that the fixed slot `divider` splits in two. On its
    /// own side, it lands as `placement` gives. The edge that faces the divider leads, as in `placement`: once it passes
    /// the divider's middle, the item is across, and there it lands on the farthest item whose middle that edge passed.
    /// So a tall item reaches a short item at the end of the list. Without the divider, as `placement`.
    func landing(of id: ID, movedBy translation: CGFloat, in order: [StackSlot<ID>], divider: String?) -> DropLanding<ID>? {
        guard let index = order.firstIndex(of: .item(id)) else { return nil }
        guard let line = divider.flatMap({ order.firstIndex(of: .fixed($0)) }) else {
            return placement(of: id, movedBy: translation, in: order).map(DropLanding.place)
        }
        let top = top(of: .item(id), in: order) + translation
        let lineMiddle = self.top(of: order[line], in: order) + height(order[line]) / 2
        let middle = { (slot: StackSlot<ID>) in self.top(of: slot, in: order) + self.height(slot) / 2 }
        if index < line {
            let bottom = top + height(.item(id))
            guard bottom > lineMiddle else {
                return placement(of: id, movedBy: translation, in: order, side: 0..<line).map(DropLanding.place)
            }
            return .across(trade: order[(line + 1)...].last { $0.item != nil && bottom > middle($0) }?.item)
        }
        guard top < lineMiddle else {
            return placement(of: id, movedBy: translation, in: order, side: (line + 1)..<order.count).map(DropLanding.place)
        }
        return .across(trade: order[..<line].first { $0.item != nil && top < middle($0) }?.item)
    }

    /// `translation` held so `id` stays within the list, from the top of its first item to the bottom of its last, and
    /// moves up no more than `headroom` and down no more than `footroom`. An item that is already past the headroom
    /// does not move up at all, and one past the footroom does not move down. With a `divider` in the list, its bottom
    /// can go down to the end of the last slot, so it can cross a divider that ends the list.
    func bounded(_ translation: CGFloat, of id: ID, in order: [StackSlot<ID>], headroom: CGFloat = .infinity,
                 footroom: CGFloat = .infinity, divider: String? = nil) -> CGFloat {
        guard let first = order.first(where: { $0.item != nil }), let last = order.last(where: { $0.item != nil }) else {
            return translation
        }
        let top = top(of: .item(id), in: order)
        let low = max(self.top(of: first, in: order) - top, -max(headroom, 0))
        var high = max(low, self.top(of: last, in: order) + height(last) - top - height(.item(id)))
        if let divider, order.contains(.fixed(divider)), let end = order.last {
            high = max(high, self.top(of: end, in: order) + height(end) - top - height(.item(id)))
        }
        high = max(low, min(high, max(footroom, 0)))
        return min(max(translation, low), high)
    }
}

/// The drag of a list's items. A press that moves a few points lifts the item at once, and a press that lets go before
/// that is a click. The lifted item follows the pointer, and the items it passes slide aside to leave a placeholder
/// where it would land. Let go, it glides into the placeholder and stays there until the list shows the new order, so
/// nothing jumps. A list with a divider, such as the Bench line, trades across it: the lifted item that crosses the
/// divider lands on an item there, and on the drop the two items pass each other to the other's place. A list holds one
/// for all its items, since only one item moves at a time.
@MainActor @Observable
final class ListDrag<ID: Hashable> {
    enum Phase: Equatable {
        case idle
        case pressing(ID)
        case lifted(ID)
        /// Let go: the item glides to where it lands and stays there until the list shows the new order.
        case settling(ID)
        /// Let go on `with` across the divider: the two items pass each other and stay in the other's place until the
        /// list shows them there.
        case trading(ID, with: ID)
    }

    /// How long a dropped item waits for the list to show the new order before the list goes back to the order it shows.
    private static var settleLimit: Duration { .seconds(3) }
    /// A lifted item grows by this much around this point.
    static var liftScale: CGFloat { 1.03 }
    static var liftAnchor: UnitPoint { UnitPoint(x: 0.5, y: 0.3) }
    static var tradeDuration: Double { 0.56 }

    private(set) var phase: Phase = .idle
    /// How far the lifted item follows the pointer. Only the lifted item reads it, so the others do not draw again as the
    /// pointer moves.
    private(set) var translation: CGFloat = 0
    /// Where the lifted item would land; nil at its own place.
    private(set) var landing: DropLanding<ID>?
    /// How far two traded items went on their paths, from 0 at the drop to 1 in the other's place.
    private(set) var tradeProgress: CGFloat = 0
    /// The items' heights when the item lifted, and of the items that came into its list since.
    private(set) var layout: StackLayout<ID>
    /// The fixed slot across which a drop trades. Without it, every drop places.
    let divider: String?
    @ObservationIgnored private var heights: [StackSlot<ID>: CGFloat] = [:]
    /// How far each item's top is below the top of the scroll view's visible part, or below a card header that sticks there.
    @ObservationIgnored private var visibleTops: [ID: CGFloat] = [:]
    /// How far the lifted item may move up before its top leaves the visible part of the scroll view.
    @ObservationIgnored private var headroom: CGFloat = .infinity
    /// Each item's list as its stack shows it now. One drag can serve several lists, such as the Pinned Topics and the others.
    @ObservationIgnored private var lists: [ID: [StackSlot<ID>]] = [:]
    /// The lifted item's list as its stack shows it.
    @ObservationIgnored private var order: [StackSlot<ID>] = []
    @ObservationIgnored private var timer: Task<Void, Never>?
    /// How far the pointer moved since the lift, before `bounded`.
    @ObservationIgnored private var rawTranslation: CGFloat = 0

    /// `spacing` is the room between two items in the list's stack, and `divider` the fixed slot across which a drop trades.
    init(spacing: CGFloat, tradesAcross divider: String? = nil) {
        layout = StackLayout(heights: [:], spacing: spacing)
        self.divider = divider
    }

    var dragged: ID? {
        switch phase {
        case .lifted(let id), .settling(let id), .trading(let id, _): return id
        default: return nil
        }
    }

    /// Where the lifted item lands next to another item; nil at its own place and across the divider.
    var placement: DropPlacement<ID>? {
        if case .place(let placement) = landing { return placement }
        return nil
    }

    var isAcross: Bool {
        if case .across = landing { return true }
        return false
    }

    var tradeTarget: ID? {
        if case .across(let target) = landing { return target }
        return nil
    }

    /// How far `slot` moves from its place in `shown`, its list as the stack shows it now, to its place in the order
    /// that the dragged item's placement makes. Zero once the stack shows that order.
    func shift(of slot: StackSlot<ID>, in shown: [StackSlot<ID>]) -> CGFloat {
        guard let dragged, let placement, shown.contains(.item(dragged)) else { return 0 }
        return layout.top(of: slot, in: placement.placing(dragged, in: shown)) - layout.top(of: slot, in: shown)
    }

    /// How far below its own place the trade target shows the item that would land in the lifted item's place.
    func tradeGhostOffset(of id: ID) -> CGFloat? {
        guard let dragged, phase == .lifted(dragged), tradeTarget == id else { return nil }
        return layout.top(of: .item(dragged), in: order) - layout.top(of: .item(id), in: order)
    }

    /// The path of a traded item: from where it was let go, down by `from`, to the other's place, down by `to`. `side`
    /// is how far it bows out on the way, so the two items pass each other on curves.
    func tradePath(of id: ID) -> (from: CGFloat, to: CGFloat, side: CGFloat)? {
        guard case .trading(let dragged, let target) = phase, id == dragged || id == target else { return nil }
        let distance = layout.top(of: .item(target), in: order) - layout.top(of: .item(dragged), in: order)
        return id == dragged ? (translation, distance, 26) : (0, -distance, -26)
    }

    /// An item or a fixed view reports its height, and its place in the scroll view, each time they change.
    func measure(_ slot: StackSlot<ID>, height: CGFloat, visibleTop: CGFloat) {
        heights[slot] = height
        if let id = slot.item { visibleTops[id] = visibleTop }
    }

    func show(_ shown: [StackSlot<ID>], at id: ID) {
        lists[id] = shown
        switch phase {
        case .lifted(id):
            order = shown
            updateLayout()
        case .settling(id):
            guard let placement, placement.placing(id, in: shown) == shown else { return }
            finish()
        case .trading(id, let target):
            guard shown.firstIndex(of: .item(id)) == order.firstIndex(of: .item(target)) else { return }
            finish()
        default:
            break
        }
    }

    private func finish() {
        timer?.cancel()
        withTransaction(Transaction(animation: nil)) {
            phase = .idle
            landing = nil
            tradeProgress = 0
        }
    }

    private func updateLayout() {
        let measured = Set(order)
        let heights = heights.filter { measured.contains($0.key) }
        if heights != layout.heights { layout.heights = heights }
    }

    func press(_ id: ID) {
        timer?.cancel()
        withTransaction(Transaction(animation: nil)) {
            landing = nil
            tradeProgress = 0
        }
        phase = .pressing(id)
    }

    /// The pressed item moved far enough to be a drag.
    func lift(_ id: ID) {
        guard phase == .pressing(id) else { return }
        order = lists[id] ?? [.item(id)]
        updateLayout()
        // Grown by the lift, its top stands a little higher than its place.
        headroom = (visibleTops[id] ?? .infinity) - (Self.liftScale - 1) * Self.liftAnchor.y * layout.height(.item(id))
        translation = 0
        withAnimation(.spring(duration: 0.25, bounce: 0.3)) { phase = .lifted(id) }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        NSCursor.closedHand.push()
    }

    func follow(_ id: ID, translation: CGFloat) {
        guard phase == .lifted(id) else { return }
        rawTranslation = translation
        updateLayout()
        self.translation = layout.bounded(translation, of: id, in: order, headroom: headroom, divider: divider)
        let landing = layout.landing(of: id, movedBy: self.translation, in: order, divider: divider)
        guard landing != self.landing else { return }
        withAnimation(.spring(duration: 0.3, bounce: 0.15)) { self.landing = landing }
        if landing != .across(trade: nil) {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    /// The area after the list's last fixed slot scrolled to `scroll`. The stack shows its items there, and a lifted
    /// item finds where it lands again, as the pointer did not move.
    func scrollArea(by scroll: CGFloat) {
        guard layout.areaScroll != scroll else { return }
        layout.areaScroll = scroll
        reland()
    }

    /// `follow` without a new event from the pointer: the places under it moved.
    private func reland() {
        guard case .lifted(let id) = phase else { return }
        follow(id, translation: rawTranslation)
    }

    /// The pointer moved on an item that cannot move: the press is neither a click nor a drag.
    func cancel() {
        timer?.cancel()
        withAnimation(.spring(duration: 0.25)) { phase = .idle }
    }

    /// The press on `id` ended: a click if the item did not lift. A lifted item glides to where it lands, and `onDrop`
    /// gets its placement once it is there; with no placement, or across the divider on no item, it glides back. On a
    /// trade target, the two items pass each other, and `onTrade` gets the target once they are in place.
    func end(_ id: ID, onTap: () -> Void, onDrop: @escaping (DropPlacement<ID>) -> Void, onTrade: @escaping (ID) -> Void) {
        timer?.cancel()
        switch phase {
        case .pressing(id):
            phase = .idle
            onTap()
        case .lifted(id):
            NSCursor.pop()
            if let target = tradeTarget {
                trade(id, with: target, onTrade: onTrade)
                return
            }
            let placement = placement
            if placement == nil { landing = nil }
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
                waitForTheList(of: id)
            }
        default:
            break
        }
    }

    private func trade(_ id: ID, with target: ID, onTrade: @escaping (ID) -> Void) {
        withTransaction(Transaction(animation: nil)) { tradeProgress = 0 }
        withAnimation(.spring(duration: 0.25)) {
            phase = .trading(id, with: target)
            landing = nil
        }
        withAnimation(.timingCurve(0.45, 0, 0.2, 1, duration: Self.tradeDuration)) {
            tradeProgress = 1
        } completion: { [weak self] in
            guard let self, phase == .trading(id, with: target) else { return }
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            onTrade(target)
            waitForTheList(of: id)
        }
    }

    private func waitForTheList(of id: ID) {
        timer = Task { [weak self] in
            try? await Task.sleep(for: Self.settleLimit)
            guard let self, !Task.isCancelled, dragged == id else { return }
            withAnimation(.spring(duration: 0.3)) {
                self.phase = .idle
                self.landing = nil
                self.tradeProgress = 0
            }
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
                landing = nil
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
    let onTrade: (ID) -> Void

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
        drag.end(id, onTap: onTap, onDrop: onDrop, onTrade: onTrade)
    }
}

private struct ListDragItem<ID: Hashable>: ViewModifier {
    let id: ID
    let drag: ListDrag<ID>
    let shown: [StackSlot<ID>]
    let cornerRadius: CGFloat
    @Environment(\.chromeTheme) private var chromeTheme
    @Environment(\.dragTopInset) private var topInset

    func body(content: Content) -> some View {
        let isLifted = drag.phase == .lifted(id)
        let path = drag.tradePath(of: id)
        let isRaised = isLifted || path != nil
        let isDragged = isRaised || drag.phase == .settling(id)
        let stepsAside = isLifted && drag.tradeTarget != nil
        let isTarget = drag.tradeTarget == id
        // Its own place in the new order for the dropped item, the placeholder's place for the lifted one, and for the
        // others the place they slide aside to.
        let shift = drag.shift(of: .item(id), in: shown)
        content
            .transformEnvironment(\.isLiftedByDrag) { if isLifted { $0 = true } }
            .background {
                if isRaised { plate.transition(.opacity) }
            }
            .overlay {
                if isTarget { TradeMark(cornerRadius: cornerRadius).transition(.opacity) }
            }
            .animation(.spring(duration: 0.2), value: isTarget)
            .scaleEffect(isLifted ? (stepsAside ? 0.94 : ListDrag<ID>.liftScale) : 1, anchor: ListDrag<ID>.liftAnchor)
            .opacity(stepsAside ? 0.9 : 1)
            .shadow(color: .black.opacity(isRaised ? 0.4 : 0), radius: isRaised ? 14 : 0, y: isRaised ? 10 : 0)
            .animation(.spring(duration: 0.25, bounce: 0.3), value: isLifted)
            .animation(.spring(duration: 0.25), value: stepsAside)
            .offset(x: stepsAside ? 34 : 0)
            .offset(y: isLifted ? drag.translation : shift)
            // The lifted item stays under the pointer while the others slide; let go, it glides.
            .transaction { if isLifted { $0.animation = nil } }
            .modifier(TradeArc(progress: path == nil ? 0 : drag.tradeProgress, path: path))
            .background(alignment: .top) {
                if isLifted { DropSlot(cornerRadius: cornerRadius, trades: stepsAside).offset(y: shift).transition(.opacity) }
            }
            .background(alignment: .top) {
                if let offset = drag.tradeGhostOffset(of: id) {
                    TradeGhost(cornerRadius: cornerRadius) { content }.offset(y: offset).transition(.opacity)
                }
            }
            // Its place without its own offset, in the visible part of the list's scroll view.
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .scrollView) } action: { frame in
                drag.measure(.item(id), height: frame.height, visibleTop: frame.minY - topInset)
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

/// A fixed view between a `ListDrag` list's items, such as a line: it slides as the items above it make room for the
/// lifted one, and it is no place to land.
private struct ListDragFixed<ID: Hashable>: ViewModifier {
    let key: String
    let drag: ListDrag<ID>
    let shown: [StackSlot<ID>]

    func body(content: Content) -> some View {
        content
            .offset(y: drag.shift(of: .fixed(key), in: shown))
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                drag.measure(.fixed(key), height: height, visibleTop: 0)
            }
    }
}

/// The place a lifted item would land: a slot of its size, outlined. In the trade colour while the lifted item is over
/// a trade target, as the target lands there.
private struct DropSlot: View {
    let cornerRadius: CGFloat
    let trades: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let color = trades ? Color.tradeMark : Color.accentColor
        shape.fill(color.opacity(0.08))
            .overlay { shape.strokeBorder(color.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])) }
            .allowsHitTesting(false)
    }
}

extension Color {
    static var tradeMark: Color { .orange }
}

private struct TradeMark: View {
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius + 2, style: .continuous)
        shape.fill(Color.tradeMark.opacity(0.1))
            .overlay { shape.strokeBorder(Color.tradeMark, style: StrokeStyle(lineWidth: 2, dash: [5, 4])) }
            .padding(-2)
            .overlay(alignment: .topTrailing) {
                Text("⇄ Trade")
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 1)
                    .background(Capsule().fill(Color.tradeMark))
                    .padding(.top, 6).padding(.trailing, 8)
            }
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel("Trade")
            .accessibilityIdentifier("list-drag-trade-target")
    }
}

private struct TradeGhost<Content: View>: View {
    let cornerRadius: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        content
            .opacity(0.45)
            .overlay(alignment: .bottomTrailing) {
                Text("lands here")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.tradeMark)
                    .padding(.bottom, 4).padding(.trailing, 8)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Moves a traded item along its path: down from `from` to `to` as `progress` goes from 0 to 1, and out to the side and
/// back on the way, so two traded items pass each other on curves and do not cover each other.
private struct TradeArc: GeometryEffect {
    var progress: CGFloat
    let path: (from: CGFloat, to: CGFloat, side: CGFloat)?

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        guard let path else { return ProjectionTransform() }
        let bow = sin(.pi * progress)
        return ProjectionTransform(CGAffineTransform(translationX: path.side * bow,
                                                     y: path.from + (path.to - path.from) * progress))
    }
}

extension View {
    /// Makes the view the handle of a `ListDrag` item: a click calls `onTap`, a press that moves lifts the item, and
    /// letting go of a lifted item calls `onDrop` with its placement once it glided there. While disabled, a press that
    /// moves does nothing and a click still works.
    /// In a list with a divider, letting go on a trade target calls `onTrade` with it once the two items passed each other.
    func listDrag<ID: Hashable>(_ id: ID, drag: ListDrag<ID>, isEnabled: Bool = true, onTap: @escaping () -> Void,
                                     onDrop: @escaping (DropPlacement<ID>) -> Void,
                                     onTrade: @escaping (ID) -> Void = { _ in }) -> some View {
        modifier(ListDragHandle(id: id, drag: drag, isEnabled: isEnabled, onTap: onTap, onDrop: onDrop, onTrade: onTrade))
    }

    /// Makes the view an item of a `ListDrag` list, whose handle may be the view or a part of it. `shown` is its
    /// list as the stack shows it now: the items it can reach in a drag. `cornerRadius` is the item's corners, for the
    /// plate it stands on while lifted and the placeholder where it would land.
    func listDragItem<ID: Hashable>(_ id: ID, drag: ListDrag<ID>, shown: [ID], cornerRadius: CGFloat) -> some View {
        listDragItem(id, drag: drag, shown: shown.map(StackSlot.item), cornerRadius: cornerRadius)
    }

    /// `listDragItem` in a list that also has fixed views, made with `listDragFixed`, between its items.
    func listDragItem<ID: Hashable>(_ id: ID, drag: ListDrag<ID>, shown: [StackSlot<ID>], cornerRadius: CGFloat) -> some View {
        modifier(ListDragItem(id: id, drag: drag, shown: shown, cornerRadius: cornerRadius))
    }

    /// Makes the view the fixed slot `key` of a `ListDrag` list: the items move past it, and it keeps its place among
    /// them. `shown` is the list as the stack shows it now.
    func listDragFixed<ID: Hashable>(_ key: String, drag: ListDrag<ID>, shown: [StackSlot<ID>]) -> some View {
        modifier(ListDragFixed(key: key, drag: drag, shown: shown))
    }

    /// A press in a window that is not key reaches this view's gestures, so a click or a drag works on the first click.
    @ViewBuilder
    func takesFirstClick() -> some View {
        if #available(macOS 15, *) { allowsWindowActivationEvents(true) } else { self }
    }
}
