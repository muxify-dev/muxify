import AppKit
import MuxifyCore

/// The view whose slots a `StackDrag` moves: the units that it lifts, and the fixed views between them, which a lifted
/// unit passes but never lands on. The Topics list (`TopicsListView`) moves its Topic cards and Locked cards among its
/// lines, its Open Places and the No Topic card; an open card's view moves its Window units or Session blocks
/// (`StackDragHost`).
@MainActor protocol StackDragList<ID>: NSView {
    associatedtype ID: Hashable
    /// The slots that the unit `id` can reach, from the top, as the host shows them now: the units among which it moves,
    /// and the fixed views between them. Without the unit, the host no longer shows it.
    func dragSlots(around id: ID) -> [StackSlot<ID>]
    /// The height of a slot as the host stacks it.
    func dragHeight(of slot: StackSlot<ID>) -> CGFloat
    /// The view of the unit `id`, which sinks, lifts and follows the pointer; nil for a unit that only makes room for the
    /// lifted one, such as an Open Place.
    func dragView(_ id: ID) -> DragUnitView?
    /// A press that moves on a unit lifts it. While this is false, a press that moves is neither a click nor a drag.
    var liftsUnits: Bool { get }
    var reducesMotion: Bool { get }
    /// The top of the visible part of the list for the units, in `clip`: the bottom of the card's header while it
    /// sticks there, or else the clip view's top. A lifted unit stops there, not under the header.
    func visibleTop(in clip: NSClipView) -> CGFloat
    /// Puts the slots at their places, each moved by the drag's offset (`StackDrag.offset`), with what goes with them.
    func layOutUnits()
    /// The drag is about to place the units, with `lifted` the unit that follows the pointer: what stands on it, such as
    /// its Hints, follows it at once, and what shows only while no unit is dragged starts to fade.
    func dragWillPlaceUnits(lifted: DragUnitView?)
    /// The unit `id` was let go at `placement`, and glided there.
    func drop(_ id: ID, at placement: DropPlacement<ID>)
    /// The unit `id` was let go on `other` across a divider, and the two passed each other to the other's place.
    func trade(_ id: ID, with other: ID)
    /// The drag's phase, its landing or its pointer changed: the host shows what goes with them, such as the Bench that a
    /// card across the line opens, or the list's scroll at its edges.
    func dragDidChange()
}

extension StackDragList {
    func dragWillPlaceUnits(lifted: DragUnitView?) {}

    func trade(_ id: ID, with other: ID) {}

    func dragDidChange() {}
}

/// The view whose units a `StackDrag` moves in an open card of an AppKit list, with no fixed view between them: the
/// card's Window units in the Sessions list and the No Topic card (`SessionCardView`), a Session block's Window units
/// (`SessionBlockView`), or an open Topic card's Session blocks (`TopicCardRowsView`). It stacks the units by their
/// IDs, and keeps the drag's placeholder among them.
@MainActor protocol StackDragHost: StackDragList where ID == String {
    /// The units that a lifted unit can pass, from the top, as the host shows them.
    var dragUnits: [DragUnitView] { get }
    /// The width of the units.
    var unitsWidth: CGFloat { get }
}

extension StackDragHost {
    func dragSlots(around id: String) -> [StackSlot<String>] { dragUnits.map { .item($0.id) } }

    func dragHeight(of slot: StackSlot<String>) -> CGFloat {
        slot.item.flatMap(dragView).map { $0.height(width: unitsWidth) } ?? 0
    }

    func dragView(_ id: String) -> DragUnitView? { dragUnits.first { $0.id == id } }
}

/// What a press on the handle of a unit tells the unit's `StackDrag`, whatever the drag's IDs: a view is the handle of
/// a unit through `SidebarPressView.drag`.
@MainActor struct StackDragHandle {
    /// The mouse went down on the handle at a point in the window.
    let press: (NSPoint) -> Void
    /// The mouse moved to a point in the window while it presses the handle.
    let move: (NSPoint) -> Void
    /// The mouse came up: a click, which the closure makes, when the unit did not lift.
    let release: (_ onTap: () -> Void) -> Void
}

/// The drag of the units of a stack in the AppKit lists: `ListDrag` with its handle in the SwiftUI lists (ADR 0074,
/// docs/adr/0075-muxify-leaves-swiftui-entirely-one-area-at-a-time.md). It moves a Window row with its Pane rows among
/// the Windows of its Session, in the Sessions list and in the Topics list, a Session block among the Sessions of its
/// open Topic card, and a Topic card or a Locked card among the cards of the Topics list. A view is the handle of a
/// unit through `SidebarPressView.drag` (`handle`).
///
/// A press on a handle sinks its unit, and a press that lets go before it moves `ListLift.slop` points is a click, which
/// goes to the handle's `onPress`. A press that moves lifts the unit at once: the unit grows and gets its shadow, and
/// follows the pointer up and down. The units it passes slide aside to leave a placeholder where it would land, and the
/// fixed views slide with them. Let go, it glides into the placeholder, the host's `drop` moves it as the SwiftUI list
/// moves it, and the unit stays there until the host shows the new order, so nothing jumps. If the host does not show
/// it within `ListLift.settleLimit`, the units go back.
///
/// A stack with dividers, such as the Topics list with its Guests line and Bench line, trades across them: a lifted
/// unit whose pointer passes the middle of a divider is across, where it steps aside over the unit under the pointer,
/// which the host marks as the trade target. Let go there, the two units pass each other on curves to the other's
/// place, and the host's `trade` moves them as the SwiftUI list trades them. Let go across on no unit, the lifted one
/// glides back.
///
/// Where a unit lands, how far it may move and what it trades with come from `StackLayout` and `DropPlacement`, which
/// the SwiftUI drag uses too. No unit lifts while the host's `liftsUnits` is false, such as in a card with one Window or
/// while the store turns the drag off.
@MainActor final class StackDrag<ID: Hashable> {
    enum Phase: Equatable {
        case idle
        case pressing(ID)
        case lifted(ID)
        /// Let go: the unit glides to where it lands and stays there until the host shows the new order.
        case settling(ID)
        /// Let go on `with` across a divider: the two units pass each other and stay in the other's place until the host
        /// shows them there.
        case trading(ID, with: ID)
    }

    /// The view whose units the drag moves.
    private unowned let host: any StackDragList<ID>
    /// The place where a lifted unit would land. The host keeps it among the units, behind them.
    let slot: DropSlotView
    private(set) var phase = Phase.idle
    /// How far the lifted unit stands below its place.
    private var translation: CGFloat = 0
    /// Where the lifted unit would land; nil at its own place.
    private(set) var landing: DropLanding<ID>?
    /// The fixed slots across which a drop trades. Without them, every drop places.
    private let dividers: [String]
    /// The slots' heights, with the stack's spacing between two, as the host stacks them.
    private var layout: StackLayout<ID>
    /// The slots as the host shows them for the lifted unit: the places it can reach.
    private var order: [StackSlot<ID>] = []
    /// How far the lifted unit may move up before its top leaves the visible part of the list, or passes under the
    /// card's header that sticks there, and down before its bottom leaves it.
    private var headroom = CGFloat.infinity
    private var footroom = CGFloat.infinity
    /// Where the press went down, in the window.
    private var start = NSPoint.zero
    /// The pointer in the window while a unit is lifted, nil otherwise. The host reads it to scroll at its edges.
    private(set) var pointer: NSPoint?
    /// How far below the lifted unit's top the pointer pressed it.
    private var grab: CGFloat = 0
    /// How far the pointer moved down since the press.
    private var moved: CGFloat = 0
    /// How far the lifted unit's place moved up since the lift, as when the list scrolled under it. The unit moves
    /// down as far, so it stays under the pointer.
    private var placeShift: CGFloat = 0
    /// The lifted unit's top below the visible top of the list, when the drag last measured it.
    private var visibleTop: CGFloat?
    /// The press moved on a unit that cannot move: it is neither a click nor a drag.
    private var cancelled = false
    private var timer: Task<Void, Never>?

    /// `spacing` is the room between two slots in the host's stack, `cornerRadius` the units' corners, for the
    /// placeholder, and `dividers` the fixed slots across which a drop trades.
    init(host: any StackDragList<ID>, spacing: CGFloat, cornerRadius: CGFloat, tradesAcross dividers: [String] = []) {
        self.host = host
        self.dividers = dividers
        layout = StackLayout(heights: [:], spacing: spacing)
        slot = DropSlotView(cornerRadius: cornerRadius)
    }

    /// The handle of the unit `id`, for the view that a press on the unit presses.
    func handle(_ id: ID) -> StackDragHandle {
        StackDragHandle(press: { [weak self] point in self?.press(id, at: point) },
                        move: { [weak self] point in self?.drag(id, to: point) },
                        release: { [weak self] onTap in self?.release(id, onTap: onTap) })
    }

    /// The unit that follows the pointer.
    var liftedID: ID? {
        if case .lifted(let id) = phase { return id }
        return nil
    }

    /// The unit that stands above the others: lifted, gliding to where it lands, or passing the unit it trades with.
    var draggedID: ID? {
        switch phase {
        case .lifted(let id), .settling(let id), .trading(let id, _): return id
        default: return nil
        }
    }

    /// Where the lifted unit lands next to another unit; nil at its own place and across a divider.
    var placement: DropPlacement<ID>? {
        if case .place(let placement) = landing { return placement }
        return nil
    }

    /// The lifted unit is across a divider.
    var isAcross: Bool {
        if case .across = landing { return true }
        return false
    }

    /// The unit across a divider that the lifted unit would trade with.
    var tradeTarget: ID? {
        if case .across(let target) = landing { return target }
        return nil
    }

    /// The lifted unit is over a trade target, and steps aside.
    private var stepsAside: Bool { liftedID != nil && tradeTarget != nil }

    /// The slot stands above the others: the dragged unit, and the unit it passes in a trade.
    func raises(_ slot: StackSlot<ID>) -> Bool {
        guard let id = slot.item else { return false }
        if case .trading(let dragged, let target) = phase { return id == dragged || id == target }
        return draggedID == id
    }

    /// How far the slot stands below its place: the lifted unit where it follows the pointer, two traded units at the
    /// other's place, the dropped one at its place in the new order, and the others where they slide aside to.
    func offset(of slot: StackSlot<ID>) -> CGFloat {
        if let id = slot.item {
            if liftedID == id { return translation }
            if let path = tradePath(of: id) { return path.to }
        }
        guard let dragged = draggedID, let placement, order.contains(.item(dragged)), order.contains(slot) else { return 0 }
        return layout.shift(of: slot, moving: dragged, to: placement, in: order)
    }

    func offset(of id: ID) -> CGFloat { offset(of: .item(id)) }

    /// How far below the lifted unit's place the placeholder stands: at the unit's place in the new order. Nil when no
    /// unit is lifted.
    private var slotOffset: CGFloat? {
        guard let id = liftedID else { return nil }
        guard let placement, order.contains(.item(id)) else { return 0 }
        return layout.shift(of: .item(id), moving: id, to: placement, in: order)
    }

    /// How far below the trade target's own place the host shows the target's ghost: where the lifted unit stood, where
    /// the target lands. Nil for any other unit, and once no unit is lifted.
    func tradeGhostOffset(of id: ID) -> CGFloat? {
        guard let dragged = liftedID, tradeTarget == id else { return nil }
        return layout.top(of: .item(dragged), in: order) - layout.top(of: .item(id), in: order)
    }

    /// The path of a traded unit: from where it was let go, down by `from`, to the other's place, down by `to`. `bow`
    /// is how far it bows out on the way, so the two units pass each other on curves.
    private func tradePath(of id: ID) -> (from: CGFloat, to: CGFloat, bow: CGFloat)? {
        guard case .trading(let dragged, let target) = phase, id == dragged || id == target else { return nil }
        let distance = layout.top(of: .item(target), in: order) - layout.top(of: .item(dragged), in: order)
        return id == dragged ? (translation, distance, ListLift.tradeBow) : (0, -distance, -ListLift.tradeBow)
    }

    private func unit(_ id: ID) -> DragUnitView? { host.dragView(id) }

    private func showLook(_ look: DragUnitView.Look, of id: ID, motion: LayerMotion?) {
        unit(id)?.show(look, reducesMotion: host.reducesMotion, motion: motion)
    }

    // MARK: The press

    /// The mouse went down on the handle of the unit `id` at `point` in the window.
    func press(_ id: ID, at point: NSPoint) {
        timer?.cancel()
        cancelled = false
        start = point
        let wasDragged = draggedID != nil
        if case .trading(let dragged, let target) = phase {
            showLook(.resting, of: dragged, motion: nil)
            showLook(.resting, of: target, motion: nil)
        }
        landing = nil
        pointer = nil
        phase = .pressing(id)
        if wasDragged { placeUnits(motion: nil) }
        showLook(.pressed, of: id, motion: .easeOut(ListLift.pressDuration))
        host.dragDidChange()
    }

    /// The pointer moved to `point` in the window while it presses the handle of the unit `id`.
    func drag(_ id: ID, to point: NSPoint) {
        guard !cancelled else { return }
        switch phase {
        case .lifted(id):
            follow(id, to: point)
        case .pressing(id):
            guard hypot(point.x - start.x, point.y - start.y) > ListLift.slop else { return }
            if host.liftsUnits {
                lift(id)
                follow(id, to: point)
            } else {
                cancelled = true
                cancel(id)
            }
        default:
            press(id, at: point)
        }
    }

    /// The mouse came up on the handle of the unit `id`: a click when the unit did not lift, which `onTap` makes. A
    /// lifted unit glides to where it lands, and the host moves it once it is there; with no placement it glides back.
    /// On a trade target, the two units pass each other, and the host trades them once they are in place.
    func release(_ id: ID, onTap: () -> Void) {
        guard !cancelled else {
            cancelled = false
            return
        }
        timer?.cancel()
        switch phase {
        case .pressing(id):
            phase = .idle
            showLook(.resting, of: id, motion: .easeOut(ListLift.pressDuration))
            host.dragDidChange()
            onTap()
        case .lifted(id):
            NSCursor.pop()
            pointer = nil
            if let target = tradeTarget { return trade(id, with: target) }
            let placement = placement
            if placement == nil { landing = nil }
            phase = .settling(id)
            // The unit shrinks and loses its shadow on the lift's spring, as SwiftUI animates the end of the lift, and
            // glides into the placeholder on the landing's.
            showLook(.resting, of: id, motion: ListLift.lift.motion)
            placeUnits(motion: ListLift.land.motion)
            host.dragDidChange()
            timer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(ListLift.land.duration))
                guard let self, !Task.isCancelled, phase == .settling(id) else { return }
                guard let placement else { return finish() }
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                // The host shows the new order at once or after tmux answers; `show` then ends the drag.
                host.drop(id, at: placement)
                waitForTheHost(of: id)
            }
        default:
            break
        }
    }

    /// Let go on the trade target: the two units stand on their plates at their size, and pass each other on curves to
    /// the other's place. Once they are there, the host trades them.
    private func trade(_ id: ID, with target: ID) {
        phase = .trading(id, with: target)
        landing = nil
        let path = { (unit: ID) in self.tradePath(of: unit) }
        for unit in [id, target] { showLook(.passing, of: unit, motion: ListLift.stepAside.motion) }
        slot.show(false, trades: true, motion: ListLift.stepAside.motion)
        let curve = ListLift.tradeCurve
        let timing = CAMediaTimingFunction(controlPoints: Float(curve.x1), Float(curve.y1), Float(curve.x2), Float(curve.y2))
        if let layer = host.layer {
            LayerGlide.run(under: layer, motion: .curve(duration: ListLift.tradeDuration, timing: timing), change: host.layOutUnits)
        } else {
            LayerGlide.withoutActions(host.layOutUnits)
        }
        for unit in [id, target] {
            if let bow = path(unit)?.bow, let layer = self.unit(unit)?.layer { Self.bow(layer, by: bow, timing: timing) }
        }
        host.dragDidChange()
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(ListLift.tradeDuration))
            guard let self, !Task.isCancelled, phase == .trading(id, with: target) else { return }
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            // The host shows the two in their new places at once or after tmux answers; `show` then ends the drag.
            host.trade(id, with: target)
            waitForTheHost(of: id)
        }
    }

    /// Bows the layer `bow` points out to the side and back on the way of a trade, as SwiftUI's `TradeArc` does: the
    /// farthest at the middle of the way, along the trade's timing curve.
    private static func bow(_ layer: CALayer, by bow: CGFloat, timing: CAMediaTimingFunction) {
        let steps = 16
        let animation = CAKeyframeAnimation(keyPath: "position.x")
        animation.values = (0...steps).map { NSNumber(value: Double(bow * sin(.pi * CGFloat($0) / CGFloat(steps)))) }
        animation.keyTimes = (0...steps).map { NSNumber(value: Double($0) / Double(steps)) }
        animation.timingFunction = timing
        animation.duration = ListLift.tradeDuration
        animation.isAdditive = true
        layer.add(animation, forKey: "trade-bow")
    }

    /// The pressed unit moved far enough to be a drag.
    private func lift(_ id: ID) {
        guard phase == .pressing(id), let unit = unit(id) else { return }
        measure(host.dragSlots(around: id))
        placeShift = 0
        moved = 0
        grab = min(max(unit.convert(start, from: nil).y, 0), unit.bounds.height)
        let place = visiblePlace(of: unit)
        visibleTop = place?.visibleTop
        fitRoom(place, of: unit)
        translation = 0
        phase = .lifted(id)
        showLook(.lifted, of: id, motion: ListLift.lift.motion)
        placeUnits(motion: nil)
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        NSCursor.closedHand.push()
    }

    /// Grown by the lift, the unit's top stands a little higher than its place and its bottom a little lower. With
    /// Reduce Motion it does not grow.
    private func fitRoom(_ place: (visibleTop: CGFloat, footroom: CGFloat)?, of unit: DragUnitView) {
        (headroom, footroom) = ListLift.room(visibleTop: place?.visibleTop ?? .infinity, footroom: place?.footroom ?? .infinity,
                                             height: unit.bounds.height, scale: host.reducesMotion ? 1 : ListLift.scale)
    }

    /// How far the unit's top stands below the visible top of the list (`StackDragList.visibleTop`), and its bottom
    /// above the visible bottom, without the drag's offset. Nil outside a list.
    private func visiblePlace(of unit: DragUnitView) -> (visibleTop: CGFloat, footroom: CGFloat)? {
        guard let stack = unit.superview, let clip = stack.enclosingScrollView?.contentView else { return nil }
        let frame = stack.convert(NSRect(x: unit.frame.minX, y: unit.place, width: unit.bounds.width, height: unit.bounds.height), to: clip)
        return (frame.minY - host.visibleTop(in: clip), clip.bounds.maxY - frame.maxY)
    }

    /// The lifted unit follows the pointer, which is at `point` in the window.
    private func follow(_ id: ID, to point: NSPoint) {
        // Window points count upward.
        moved = start.y - point.y
        pointer = point
        land(id)
        host.dragDidChange()
    }

    private func land(_ id: ID) {
        let (translation, landing) = layout.follow(id, moved: moved + placeShift, grab: grab, in: order,
                                                   headroom: headroom, footroom: footroom, dividers: dividers)
        self.translation = translation
        guard landing != self.landing else { return placeUnits(motion: nil) }
        let steppedAside = stepsAside
        self.landing = landing
        if stepsAside != steppedAside {
            showLook(stepsAside ? .steppingAside : .lifted, of: id, motion: ListLift.stepAside.motion)
        }
        placeUnits(motion: ListLift.land.motion)
        if landing != .across(trade: nil) {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        host.dragDidChange()
    }

    /// The pointer moved on a unit that cannot move: the press is neither a click nor a drag.
    private func cancel(_ id: ID) {
        timer?.cancel()
        phase = .idle
        showLook(.resting, of: id, motion: ListLift.cancel.motion)
        host.dragDidChange()
    }

    // MARK: The host

    /// The host shows its slots anew. A lifted unit finds its places among them again; a dropped unit's drag ends once
    /// the host shows the new order, and two traded units' once the host shows each in the other's place. A drag whose
    /// unit went away ends.
    func show() {
        guard let id = phaseID else { return }
        let shown = host.dragSlots(around: id)
        guard shown.contains(.item(id)) else { return abandon(id) }
        switch phase {
        case .lifted:
            measure(shown)
            land(id)
        case .settling:
            if let placement, placement.placing(id, in: shown) == shown { finish() }
        case .trading(_, let target):
            if shown.firstIndex(of: .item(id)) == order.firstIndex(of: .item(target)) { finish() }
        case .idle, .pressing:
            break
        }
    }

    /// The host's place in the list moved, as when the list scrolled under a lifted unit: the unit keeps its place
    /// under the pointer, and finds where it lands again.
    func placeMoved() {
        guard let id = liftedID, let unit = unit(id), let place = visiblePlace(of: unit) else { return }
        defer { visibleTop = place.visibleTop }
        guard let before = visibleTop, before != place.visibleTop else { return }
        placeShift += before - place.visibleTop
        fitRoom(place, of: unit)
        land(id)
    }

    /// The slots after the stack's last fixed slot scrolled `scroll` points up on their own, as the Bench under the line
    /// that sticks (`StackLayout.areaScroll`). A lifted unit finds where it lands again, as the pointer did not move.
    func scrollArea(by scroll: CGFloat) {
        guard layout.areaScroll != scroll else { return }
        layout.areaScroll = scroll
        if let id = liftedID { land(id) }
    }

    /// The card closed, or the host went away: a lifted unit goes back.
    func abandon() {
        if let id = phaseID { abandon(id) }
    }

    private var phaseID: ID? {
        switch phase {
        case .idle: return nil
        case .pressing(let id), .lifted(let id), .settling(let id), .trading(let id, _): return id
        }
    }

    private func abandon(_ id: ID) {
        timer?.cancel()
        switch phase {
        case .pressing(id):
            cancel(id)
        case .lifted(id):
            NSCursor.pop()
            phase = .idle
            landing = nil
            pointer = nil
            showLook(.resting, of: id, motion: ListLift.lift.motion)
            placeUnits(motion: ListLift.back.motion)
            host.dragDidChange()
        case .settling(id), .trading(id, _):
            finish()
        default:
            break
        }
    }

    /// The order and the heights of the slots that the lifted unit can reach, as the host shows them.
    private func measure(_ shown: [StackSlot<ID>]) {
        order = shown
        layout.heights = Dictionary(shown.map { ($0, host.dragHeight(of: $0)) }, uniquingKeysWith: { first, _ in first })
    }

    /// The host shows the new order: the units stand at their places, where they already show.
    private func finish() {
        timer?.cancel()
        if case .trading(let dragged, let target) = phase {
            showLook(.resting, of: dragged, motion: nil)
            showLook(.resting, of: target, motion: nil)
        }
        phase = .idle
        landing = nil
        pointer = nil
        translation = 0
        placeUnits(motion: nil)
        host.dragDidChange()
    }

    private func waitForTheHost(of id: ID) {
        timer = Task { [weak self] in
            try? await Task.sleep(for: ListLift.settleLimit)
            guard let self, !Task.isCancelled, draggedID == id else { return }
            if case .trading(let dragged, let target) = phase {
                showLook(.resting, of: dragged, motion: ListLift.back.motion)
                showLook(.resting, of: target, motion: ListLift.back.motion)
            }
            phase = .idle
            landing = nil
            placeUnits(motion: ListLift.back.motion)
            host.dragDidChange()
        }
    }

    // MARK: The stack

    /// Puts the placeholder where the lifted unit would land, behind the units.
    func placeSlot() {
        slot.layer?.zPosition = 1
        guard let id = liftedID, let offset = slotOffset, let unit = unit(id) else { return }
        slot.frame = NSRect(x: unit.frame.minX, y: unit.place + offset, width: unit.bounds.width, height: unit.bounds.height)
    }

    /// Puts the units at their places and the drag's offsets. With `motion`, the units that move glide there, with
    /// what goes with them and the placeholder; the lifted unit and what stands on it follow the pointer at once.
    private func placeUnits(motion: LayerMotion?) {
        let appears = liftedID != nil && !slot.shows
        let lifted = liftedID.flatMap(unit)
        LayerGlide.withoutActions {
            if let id = liftedID, let lifted {
                lifted.setFrameOrigin(NSPoint(x: lifted.frame.minX, y: lifted.place + offset(of: id)))
            }
            host.dragWillPlaceUnits(lifted: lifted)
            if appears { placeSlot() }
        }
        if let motion, let layer = host.layer {
            LayerGlide.run(under: layer, motion: motion, change: host.layOutUnits)
        } else {
            LayerGlide.withoutActions(host.layOutUnits)
        }
        slot.show(liftedID != nil, trades: stepsAside, motion: appears ? ListLift.lift.motion : motion)
    }
}

extension StackDrag where ID == String {
    /// Puts `unit` in the host's stack with its top at `top`, `width` wide, moved by the drag's offset: above the
    /// others and the placeholder while it is lifted and while it glides to where it lands. Returns its bottom at its
    /// place.
    @discardableResult
    func place(_ unit: DragUnitView, at top: CGFloat, width: CGFloat) -> CGFloat {
        unit.place = top
        unit.frame = NSRect(x: 0, y: top + offset(of: unit.id), width: width, height: unit.height(width: width))
        unit.layOut()
        unit.layer?.zPosition = draggedID == unit.id ? 2 : 0
        return top + unit.frame.height
    }
}

extension ListLift.Spring {
    /// The spring for Core Animation.
    var motion: LayerMotion { .spring(duration: duration, bounce: bounce) }
}

/// A unit that a `StackDrag` lifts as one: a Window row with the Pane rows under it (`WindowUnitView`), a Session block
/// of an open Topic card (`SessionBlockView`), or a card of the Topics list (`TopicCardView`). It stands on a plate
/// while it is pressed or lifted. It takes no click of its own: a click between its parts goes to the card.
class DragUnitView: NSView {
    enum Look {
        case resting
        /// Pressed, the unit sinks and stands on its plate, so the press shows before the pointer moves.
        case pressed
        /// Lifted, it grows and gets its shadow.
        case lifted
        /// Lifted over a trade target across a divider, it shrinks, moves to the right and fades a little, so the
        /// target shows beside it (`ListLift.stepAsideScale`).
        case steppingAside
        /// Passing the unit it trades with, it stands on its plate with its shadow, at its size.
        case passing
    }

    let id: String
    /// Its top in the host's stack, without the drag's offset.
    var place: CGFloat = 0
    private let plate: LiftPlateView
    private var look = Look.resting
    /// Reduce Motion is on: the unit's look keeps its size.
    private var keepsSize = false
    /// The unit's opacity is its own while it steps aside; at any other time it is the host's.
    private var fadedAside = false

    /// The views over the plate, from the back.
    var parts: [NSView] = [] {
        didSet {
            let views = [plate] + parts
            if subviews != views { subviews = views }
        }
    }

    /// `cornerRadius` is the unit's corners, for its plate and its shadow.
    init(id: String, cornerRadius: CGFloat) {
        self.id = id
        plate = LiftPlateView(cornerRadius: cornerRadius)
        super.init(frame: .zero)
        wantsLayer = true
        plate.alphaValue = 0
        subviews = [plate]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self || hit === plate ? nil : hit
    }

    var theme: TerminalTheme? {
        get { plate.theme }
        set { plate.theme = newValue }
    }

    /// The unit's height `width` wide.
    func height(width: CGFloat) -> CGFloat { 0 }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layOut()
    }

    /// Puts the plate under the parts and lays the parts out (`layOutParts`), at the scale of the unit's look.
    final func layOut() {
        plate.frame = bounds
        layOutParts()
        // The scale's point stays with the unit's size.
        LayerGlide.withoutActions { layer?.sublayerTransform = transform(of: look, reducesMotion: keepsSize) }
    }

    /// Stacks the parts from the top.
    func layOutParts() {}

    /// Shows the look, moving to it by `motion`, or at once without. With Reduce Motion the unit does not sink, grow or
    /// shrink.
    func show(_ look: Look, reducesMotion: Bool, motion: LayerMotion?) {
        self.look = look
        keepsSize = reducesMotion
        if let layer {
            LayerGlide.set("sublayerTransform", of: layer, to: NSValue(caTransform3D: transform(of: look, reducesMotion: reducesMotion)),
                           motion: motion)
            // Only a unit that stepped aside changes its own opacity, so the opacity its host gives it stays.
            if look == .steppingAside || fadedAside {
                fadedAside = look == .steppingAside
                LayerGlide.set("opacity", of: layer, to: Float(fadedAside ? ListLift.stepAsideOpacity : 1), motion: motion)
            }
        }
        plate.show(look == .resting ? .none : look == .pressed ? .plate : .shadow, motion: motion)
    }

    private func scale(_ look: Look, reducesMotion: Bool) -> CGFloat {
        guard !reducesMotion else { return 1 }
        switch look {
        case .resting, .passing: return 1
        case .pressed: return ListLift.pressScale
        case .lifted: return ListLift.scale
        case .steppingAside: return ListLift.stepAsideScale
        }
    }

    /// The look's scale around `ListLift.anchor` of the unit's size, moved to the right while the unit steps aside. A
    /// flipped view's layer counts from its top left corner.
    private func transform(of look: Look, reducesMotion: Bool) -> CATransform3D {
        let scale = scale(look, reducesMotion: reducesMotion)
        let x = bounds.width * ListLift.anchor.x, y = bounds.height * ListLift.anchor.y
        let aside = look == .steppingAside ? ListLift.stepAsideShift : 0
        return CATransform3DTranslate(CATransform3DScale(CATransform3DMakeTranslation(x + aside, y, 0), scale, scale, 1), -x, -y, 0)
    }
}

/// A Window row and the Pane rows under it, which a drag lifts as one; or a Pane row in place of its Session's only
/// Window row, which does not move. Its rows stand `CardSpacing.row` apart.
final class WindowUnitView: DragUnitView {
    /// The Window of a Window row; nil for a Pane row in place of the only Window row.
    var tmuxWindow: TmuxWindow?

    /// The rows from the top.
    var rows: [CardRowView] = [] {
        didSet { parts = rows }
    }

    /// `id` is the Window ID, or the Pane ID of a Pane row in place of the only Window row.
    init(id: String) {
        super.init(id: id, cornerRadius: WindowRowMetrics.cornerRadius)
    }

    /// The rows in their units, as `WindowUnit` groups them in the SwiftUI list: each Window row with the Pane rows under
    /// it, and each Pane row in place of the only Window row. A unit of `kept` keeps its view, so a lifted unit keeps the
    /// row the pointer presses.
    static func units(of rows: [(content: CardRowContent, view: CardRowView)], keeping kept: [WindowUnitView]) -> [WindowUnitView] {
        var kept = Dictionary(kept.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var grouped: [(id: String, window: TmuxWindow?, rows: [CardRowView])] = []
        for (content, view) in rows {
            switch content {
            case .window(let content):
                grouped.append((content.window.id, content.window, [view]))
            case .pane(let content) where content.isUnderWindowRow && grouped.last?.window?.id == content.windowID:
                grouped[grouped.count - 1].rows.append(view)
            case .pane(let content):
                grouped.append((content.paneID, nil, [view]))
            }
        }
        return grouped.map { group in
            let unit = kept.removeValue(forKey: group.id) ?? WindowUnitView(id: group.id)
            unit.tmuxWindow = group.window
            unit.rows = group.rows
            return unit
        }
    }

    /// The height of the rows in a unit `width` wide, with `CardSpacing.row` between two rows.
    override func height(width: CGFloat) -> CGFloat {
        rows.map { $0.height(width: width) }.reduce(0, +) + CardSpacing.row * CGFloat(max(0, rows.count - 1))
    }

    /// Stacks the rows from the top.
    override func layOutParts() {
        var top: CGFloat = 0
        for row in rows {
            row.frame = NSRect(x: 0, y: top, width: bounds.width, height: row.height(width: bounds.width))
            top = row.frame.maxY + CardSpacing.row
        }
    }
}

/// What a pressed or lifted unit stands on, so the rows it passes over do not show through it: the chrome's
/// background, as `chrome(theme:material:)` gives it to the Sidebar, under a faint fill of the text colour, in a thin
/// border, with the shadow of the lift under it. `ListDragItem`'s plate in SwiftUI.
private final class LiftPlateView: NSView {
    enum Shows { case none, plate, shadow }

    var theme: TerminalTheme? {
        didSet {
            guard theme != oldValue else { return }
            material.isHidden = theme != nil
            face.base = theme?.chrome
        }
    }
    private let shade: LiftShadowView
    private let material = NSVisualEffectView()
    private let face: LiftFaceView

    init(cornerRadius: CGFloat) {
        shade = LiftShadowView(cornerRadius: cornerRadius)
        face = LiftFaceView(cornerRadius: cornerRadius)
        super.init(frame: .zero)
        wantsLayer = true
        material.material = .sidebar
        material.blendingMode = .behindWindow
        material.state = .followsWindowActiveState
        material.wantsLayer = true
        material.layer?.cornerRadius = cornerRadius
        material.layer?.cornerCurve = .continuous
        material.layer?.masksToBounds = true
        subviews = [shade, material, face]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        for view in [shade, material, face] { view.frame = bounds }
    }

    func show(_ shows: Shows, motion: LayerMotion?) {
        if let layer { LayerGlide.set("opacity", of: layer, to: Float(shows == .none ? 0 : 1), motion: motion) }
        shade.show(shows == .shadow, motion: motion)
    }
}

/// The shadow of a lifted unit, in the unit's rounded shape. The shadow is a layer under the view's own, because AppKit
/// takes the shadow off the layer of a view.
private final class LiftShadowView: NSView {
    private let shape = CALayer()
    private let cornerRadius: CGFloat

    init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        layer = CALayer()
        wantsLayer = true
        shape.shadowColor = .black
        shape.shadowOpacity = 0
        shape.shadowRadius = ListLift.shadowRadius
        // A layer's shadow counts upward, also in a flipped view.
        shape.shadowOffset = CGSize(width: 0, height: -ListLift.shadowDrop)
        layer?.addSublayer(shape)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        LayerGlide.withoutActions {
            shape.frame = bounds
            shape.shadowPath = CGPath(roundedRect: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        }
    }

    func show(_ shows: Bool, motion: LayerMotion?) {
        LayerGlide.set("shadowOpacity", of: shape, to: Float(shows ? ListLift.shadowOpacity : 0), motion: motion)
    }
}

/// The face of the plate: the chrome's colour of a Ghostty theme, under the faint fill of the text colour, in a thin
/// border of it. The shapes are layers under the view's own, as `RowFillView`'s.
private final class LiftFaceView: LayerColoredView {
    var base: NSColor? {
        didSet { recolor() }
    }
    private let under = CALayer()
    private let fill = CALayer()

    init(cornerRadius: CGFloat) {
        super.init(frame: .zero)
        layer = CALayer()
        wantsLayer = true
        for shape in [under, fill] {
            shape.cornerRadius = cornerRadius
            shape.cornerCurve = .continuous
            layer?.addSublayer(shape)
        }
        fill.borderWidth = ListLift.plateBorderWidth
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        LayerGlide.withoutActions {
            under.frame = bounds
            fill.frame = bounds
        }
    }

    override func colorLayers() {
        under.backgroundColor = base?.cgColor
        fill.backgroundColor = NSColor.labelColor.faded(ListLift.plateFillOpacity).cgColor
        fill.borderColor = NSColor.labelColor.faded(ListLift.plateBorderOpacity).cgColor
    }
}

/// The place where a lifted unit would land: a slot of its size, in the accent colour, with a dashed border; in the
/// trade colour while the lifted unit is over a trade target, as the target lands there. `DropSlot` in SwiftUI.
final class DropSlotView: LayerColoredView {
    private let fill = CALayer()
    private let border = CAShapeLayer()
    private let cornerRadius: CGFloat
    private var trades = false {
        didSet {
            if trades != oldValue { colorLayers() }
        }
    }

    /// `cornerRadius` is the corners of the units that land in it.
    init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        layer = CALayer()
        wantsLayer = true
        fill.cornerRadius = cornerRadius
        fill.cornerCurve = .continuous
        border.fillColor = nil
        border.lineWidth = ListLift.slotBorderWidth
        border.lineDashPattern = ListLift.slotDash.map { NSNumber(value: Double($0)) }
        layer?.addSublayer(fill)
        layer?.addSublayer(border)
        layer?.opacity = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        LayerGlide.withoutActions {
            fill.frame = bounds
            // Inside the slot, as SwiftUI's `strokeBorder` draws.
            let inset = bounds.insetBy(dx: ListLift.slotBorderWidth / 2, dy: ListLift.slotBorderWidth / 2)
            let radius = max(0, cornerRadius - ListLift.slotBorderWidth / 2)
            border.path = inset.width > 0 && inset.height > 0
                ? CGPath(roundedRect: inset, cornerWidth: radius, cornerHeight: radius, transform: nil) : nil
        }
    }

    override func colorLayers() {
        let color = trades ? NSColor.tradeMark : .controlAccentColor
        fill.backgroundColor = color.faded(ListLift.slotFillOpacity).cgColor
        border.strokeColor = color.faded(ListLift.slotBorderOpacity).cgColor
    }

    /// The slot shows, or not, moving to it by `motion`; with `trades` in the trade colour.
    func show(_ shows: Bool, trades: Bool = false, motion: LayerMotion?) {
        guard let layer else { return }
        if shows { self.trades = trades }
        LayerGlide.set("opacity", of: layer, to: Float(shows ? 1 : 0), motion: motion)
    }

    var shows: Bool { (layer?.opacity ?? 0) > 0 }
}

extension NSColor {
    /// The colour of a trade across a divider of a list's drag, as SwiftUI's `Color.tradeMark`.
    static var tradeMark: NSColor { .systemOrange }
}

/// The mark of the unit that a lifted unit would trade with across a divider, over the unit's frame: `TradeMark` in
/// SwiftUI. It is filled with the trade colour and outlined in its dashes, with its word in a capsule of it at the
/// top-right corner (`TradeLook`). It takes no click. To accessibility it is one element, "Trade", while it shows.
final class TradeMarkView: LayerColoredView {
    private let fill = CALayer()
    private let border = CAShapeLayer()
    private let capsule = CALayer()
    private let word = SidebarLabel()
    private let cornerRadius: CGFloat
    /// The mark shows: it is over a trade target.
    private(set) var shows = false

    /// `cornerRadius` is the corners of the units it marks.
    init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        layer = CALayer()
        wantsLayer = true
        fill.cornerRadius = cornerRadius
        fill.cornerCurve = .continuous
        border.fillColor = nil
        border.lineWidth = TradeLook.borderWidth
        border.lineDashPattern = TradeLook.dash.map { NSNumber(value: Double($0)) }
        for shape in [fill, border, capsule] { layer?.addSublayer(shape) }
        layer?.opacity = 0
        word.text = TradeLook.word
        word.ink = .onTrade
        addSubview(word)
        setAccessibilityRole(.group)
        setAccessibilityLabel(TradeLook.label)
        setAccessibilityIdentifier(TradeLook.identifier)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func isAccessibilityElement() -> Bool { shows }

    override func accessibilityChildren() -> [Any]? { [] }

    /// The mark shows, or not, on the spring `TradeLook.shows`, with its word at the Interface font size.
    func show(_ shows: Bool, environment: SidebarListEnvironment) {
        self.shows = shows
        word.font = .systemFont(ofSize: environment.fontSize(TradeLook.fontSize), weight: .bold)
        word.scale = environment.displayScale
        layOutWord()
        if let layer { LayerGlide.set("opacity", of: layer, to: Float(shows ? 1 : 0), motion: TradeLook.shows.motion) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        LayerGlide.withoutActions {
            fill.frame = bounds
            // Inside the mark, as SwiftUI's `strokeBorder` draws.
            let inset = bounds.insetBy(dx: TradeLook.borderWidth / 2, dy: TradeLook.borderWidth / 2)
            let radius = max(0, cornerRadius - TradeLook.borderWidth / 2)
            border.path = inset.width > 0 && inset.height > 0
                ? CGPath(roundedRect: inset, cornerWidth: radius, cornerHeight: radius, transform: nil) : nil
        }
        layOutWord()
    }

    /// The word in its capsule, in the top-right corner.
    private func layOutWord() {
        let size = word.fit()
        let padding = TradeLook.wordPadding, inset = TradeLook.wordInset
        let box = NSRect(x: bounds.width - inset.trailing - size.width - 2 * padding.horizontal, y: inset.top,
                         width: size.width + 2 * padding.horizontal, height: size.height + 2 * padding.vertical)
        word.frame = NSRect(x: box.minX + padding.horizontal, y: box.minY + padding.vertical, width: size.width, height: size.height)
        LayerGlide.withoutActions {
            capsule.frame = box
            capsule.cornerRadius = box.height / 2
        }
    }

    override func colorLayers() {
        fill.backgroundColor = NSColor.tradeMark.faded(TradeLook.fillOpacity).cgColor
        border.strokeColor = NSColor.tradeMark.cgColor
        capsule.backgroundColor = NSColor.tradeMark.cgColor
    }
}

/// Where the trade target lands: the target's look where the lifted unit stood, faded, with its word in the
/// bottom-right corner: `TradeGhost` in SwiftUI. It takes no click, and accessibility does not see it.
final class TradeGhostView: NSView {
    private let word = SidebarLabel()
    private let cornerRadius: CGFloat
    private var picture: NSImage?

    /// `cornerRadius` is the corners of the units it shows.
    init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
        layer?.opacity = 0
        word.text = TradeLook.ghostWord
        word.ink = .trade
        addSubview(word)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func accessibilityChildren() -> [Any]? { [] }

    /// Shows the look of `target` as it shows now, or nothing for none, on the spring `TradeLook.shows`.
    func show(_ target: NSView?, environment: SidebarListEnvironment) {
        if let target { picture = Self.picture(of: target, scale: environment.displayScale) }
        word.font = .systemFont(ofSize: environment.fontSize(TradeLook.ghostFontSize), weight: .semibold)
        word.scale = environment.displayScale
        layOutWord()
        needsDisplay = true
        if let layer { LayerGlide.set("opacity", of: layer, to: Float(target == nil ? 0 : 1), motion: TradeLook.shows.motion) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layOutWord()
    }

    private func layOutWord() {
        let size = word.fit(), inset = TradeLook.ghostWordInset
        word.frame = NSRect(x: bounds.width - inset.trailing - size.width, y: bounds.height - inset.bottom - size.height,
                            width: size.width, height: size.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let picture else { return }
        NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).addClip()
        picture.draw(in: NSRect(origin: .zero, size: picture.size), from: .zero, operation: .sourceOver,
                     fraction: TradeLook.ghostOpacity, respectFlipped: true, hints: nil)
    }

    /// The look of `view` as its layers show it, at `scale` pixels to the point.
    private static func picture(of view: NSView, scale: CGFloat) -> NSImage? {
        guard let layer = view.layer else { return nil }
        let size = view.bounds.size
        let width = Int((size.width * scale).rounded(.up)), height = Int((size.height * scale).rounded(.up))
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // `CALayer.render` draws a layer's bottom at the top of a bitmap; flipped, the layer's top is there.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        layer.render(in: context)
        return context.makeImage().map { NSImage(cgImage: $0, size: size) }
    }
}
