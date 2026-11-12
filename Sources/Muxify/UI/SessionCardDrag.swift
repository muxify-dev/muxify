import AppKit
import MuxifyCore

/// The drag of the Window rows of an open card in the AppKit Sessions list (ADR 0074): `ListDrag` with its handle in
/// the SwiftUI list. A press on a Window row sinks the row, and a press that lets go before it moves `ListLift.slop`
/// points is a click, which goes to the Window. A press that moves lifts the row with the Pane rows under it at once:
/// the unit grows and gets its shadow, and follows the pointer up and down. The units it passes slide aside to leave a
/// placeholder where it would land. Let go, it glides into the placeholder, the card's `onMoveWindow` moves the Window
/// as the SwiftUI list moves it, and the unit stays there until the card shows the new order, so nothing jumps. If the
/// card does not show it within `ListLift.settleLimit`, the units go back.
///
/// Where a unit lands and how far it may move come from `StackLayout` and `DropPlacement`, which the SwiftUI drag uses
/// too. A row of a card with one Window does not lift, and no row lifts while the store turns the drag off.
@MainActor final class SessionCardDrag {
    private enum Phase: Equatable {
        case idle
        case pressing(String)
        case lifted(String)
        /// Let go: the unit glides to where it lands and stays there until the card shows the new order.
        case settling(String)
    }

    /// The card whose Window units the drag moves.
    private unowned let card: SessionCardView
    private var phase = Phase.idle
    /// How far the lifted unit stands below its place.
    private var translation: CGFloat = 0
    /// Where the lifted unit would land; nil at its own place.
    private var placement: DropPlacement<String>?
    /// The Window units' heights, with `CardSpacing.row` between two, as the card stacks them.
    private var layout = StackLayout<String>(heights: [:], spacing: CardSpacing.row)
    /// The Window units as the card shows them now: the places a lifted unit can reach.
    private var order: [StackSlot<String>] = []
    /// How far the lifted unit may move up before its top leaves the visible part of the list, or passes under the
    /// card's header that sticks there, and down before its bottom leaves it.
    private var headroom = CGFloat.infinity
    private var footroom = CGFloat.infinity
    /// Where the press went down, in the window.
    private var start = NSPoint.zero
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

    init(card: SessionCardView) {
        self.card = card
    }

    /// The unit that follows the pointer.
    var liftedID: String? {
        if case .lifted(let id) = phase { return id }
        return nil
    }

    /// The unit that stands above the others: lifted, or gliding to where it lands.
    var draggedID: String? {
        switch phase {
        case .lifted(let id), .settling(let id): return id
        default: return nil
        }
    }

    /// How far the unit `id` stands below its place: the lifted unit where it follows the pointer, the dropped one at
    /// its place in the new order, and the others where they slide aside to.
    func offset(of id: String) -> CGFloat {
        if liftedID == id { return translation }
        return draggedID.map { shift(of: id, moving: $0) } ?? 0
    }

    /// How far below the lifted unit's place the placeholder stands: at the unit's place in the new order. Nil when no
    /// unit is lifted.
    var slotOffset: CGFloat? { liftedID.map { shift(of: $0, moving: $0) } }

    private func shift(of id: String, moving dragged: String) -> CGFloat {
        guard let placement, order.contains(.item(dragged)), order.contains(.item(id)) else { return 0 }
        return layout.shift(of: .item(id), moving: dragged, to: placement, in: order)
    }

    // MARK: The press

    /// The mouse went down on the Window row `id` at `point` in the window.
    func press(_ id: String, at point: NSPoint) {
        timer?.cancel()
        cancelled = false
        start = point
        let wasDragged = draggedID != nil
        placement = nil
        phase = .pressing(id)
        if wasDragged { card.placeUnits(motion: nil) }
        card.showLook(.pressed, of: id, motion: .easeOut(ListLift.pressDuration))
    }

    /// The pointer moved to `point` in the window while it presses the Window row `id`.
    func drag(_ id: String, to point: NSPoint) {
        guard !cancelled else { return }
        switch phase {
        case .lifted(id):
            follow(id, to: point)
        case .pressing(id):
            guard hypot(point.x - start.x, point.y - start.y) > ListLift.slop else { return }
            if card.movesWindows {
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

    /// The mouse came up on the Window row `id`: a click when the row did not lift, which `onTap` makes. A lifted unit
    /// glides to where it lands, and the card moves its Window once it is there; with no placement it glides back.
    func release(_ id: String, onTap: () -> Void) {
        guard !cancelled else {
            cancelled = false
            return
        }
        timer?.cancel()
        switch phase {
        case .pressing(id):
            phase = .idle
            card.showLook(.resting, of: id, motion: .easeOut(ListLift.pressDuration))
            onTap()
        case .lifted(id):
            NSCursor.pop()
            let placement = placement
            phase = .settling(id)
            // The unit shrinks and loses its shadow on the lift's spring, as SwiftUI animates the end of the lift, and
            // glides into the placeholder on the landing's.
            card.showLook(.resting, of: id, motion: ListLift.lift.motion)
            card.placeUnits(motion: ListLift.land.motion)
            timer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(ListLift.land.duration))
                guard let self, !Task.isCancelled, phase == .settling(id) else { return }
                guard let placement else { return finish() }
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                // The card shows the new order at once or after tmux answers; `show` then ends the drag.
                card.moveWindow(id, placement)
                waitForTheCard(of: id)
            }
        default:
            break
        }
    }

    /// The pressed unit moved far enough to be a drag.
    private func lift(_ id: String) {
        guard phase == .pressing(id), let unit = card.unit(id) else { return }
        measure()
        placeShift = 0
        moved = 0
        grab = min(max(unit.convert(start, from: nil).y, 0), unit.bounds.height)
        let place = card.visiblePlace(of: unit)
        visibleTop = place?.visibleTop
        fitRoom(place, of: unit)
        translation = 0
        phase = .lifted(id)
        card.showLook(.lifted, of: id, motion: ListLift.lift.motion)
        card.placeUnits(motion: nil)
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        NSCursor.closedHand.push()
    }

    /// Grown by the lift, the unit's top stands a little higher than its place and its bottom a little lower. With
    /// Reduce Motion it does not grow.
    private func fitRoom(_ place: (visibleTop: CGFloat, footroom: CGFloat)?, of unit: WindowUnitView) {
        (headroom, footroom) = ListLift.room(visibleTop: place?.visibleTop ?? .infinity, footroom: place?.footroom ?? .infinity,
                                             height: unit.bounds.height, scale: card.reducesMotion ? 1 : ListLift.scale)
    }

    /// The lifted unit follows the pointer, which is at `point` in the window.
    private func follow(_ id: String, to point: NSPoint) {
        // Window points count upward.
        moved = start.y - point.y
        land(id)
    }

    private func land(_ id: String) {
        let (translation, landing) = layout.follow(id, moved: moved + placeShift, grab: grab, in: order,
                                                   headroom: headroom, footroom: footroom)
        self.translation = translation
        let placement: DropPlacement<String>? = if case .place(let placement) = landing { placement } else { nil }
        guard placement != self.placement else { return card.placeUnits(motion: nil) }
        self.placement = placement
        card.placeUnits(motion: ListLift.land.motion)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    /// The pointer moved on a unit that cannot move: the press is neither a click nor a drag.
    private func cancel(_ id: String) {
        timer?.cancel()
        phase = .idle
        card.showLook(.resting, of: id, motion: ListLift.cancel.motion)
    }

    // MARK: The card

    /// The card shows its rows anew: the Window units, from the top. A dropped unit's drag ends once they are in the
    /// new order, and a drag whose unit went away ends.
    func show(_ ids: [String]) {
        guard let id = phaseID else { return }
        guard ids.contains(id) else { return abandon(id) }
        measure()
        if case .settling = phase, let placement, placement.placing(id, in: ids) == ids { finish() }
    }

    /// The card's place in the list moved, as when the list scrolled under a lifted unit: the unit keeps its place
    /// under the pointer, and finds where it lands again.
    func placeMoved() {
        guard let id = liftedID, let unit = card.unit(id), let place = card.visiblePlace(of: unit) else { return }
        defer { visibleTop = place.visibleTop }
        guard let before = visibleTop, before != place.visibleTop else { return }
        placeShift += before - place.visibleTop
        fitRoom(place, of: unit)
        land(id)
    }

    /// The card closed, or its rows went away: a lifted unit goes back.
    func abandon() {
        if let id = phaseID { abandon(id) }
    }

    private var phaseID: String? {
        switch phase {
        case .idle: return nil
        case .pressing(let id), .lifted(let id), .settling(let id): return id
        }
    }

    private func abandon(_ id: String) {
        timer?.cancel()
        switch phase {
        case .pressing(id):
            cancel(id)
        case .lifted(id):
            NSCursor.pop()
            phase = .idle
            placement = nil
            card.showLook(.resting, of: id, motion: ListLift.lift.motion)
            card.placeUnits(motion: ListLift.back.motion)
        case .settling(id):
            finish()
        default:
            break
        }
    }

    /// The order and the heights of the Window units as the card shows them.
    private func measure() {
        let units = card.windowUnits, width = card.rowsWidth
        order = units.map { .item($0.id) }
        layout.heights = Dictionary(units.map { (.item($0.id), $0.height(width: width)) }, uniquingKeysWith: { first, _ in first })
    }

    /// The card shows the new order: the units stand at their places, where they already show.
    private func finish() {
        timer?.cancel()
        phase = .idle
        placement = nil
        translation = 0
        measure()
        card.placeUnits(motion: nil)
    }

    private func waitForTheCard(of id: String) {
        timer = Task { [weak self] in
            try? await Task.sleep(for: ListLift.settleLimit)
            guard let self, !Task.isCancelled, phase == .settling(id) else { return }
            phase = .idle
            placement = nil
            card.placeUnits(motion: ListLift.back.motion)
        }
    }
}

extension ListLift.Spring {
    /// The spring for Core Animation.
    var motion: LayerMotion { .spring(duration: duration, bounce: bounce) }
}

/// A Window row and the Pane rows under it, which a drag lifts as one; or a Pane row in place of its Session's only
/// Window row, which does not move. It stands on a plate while it is pressed or lifted. It takes no click of its own:
/// a click between its rows goes to the card, as before the rows had a unit.
final class WindowUnitView: NSView {
    enum Look {
        case resting
        /// Pressed, the unit sinks and stands on its plate, so the press shows before the pointer moves.
        case pressed
        /// Lifted, it grows and gets its shadow.
        case lifted
    }

    /// The Window ID, or the Pane ID of a Pane row in place of the only Window row.
    let id: String
    /// The Window of a Window row; nil for a Pane row in place of the only Window row.
    var tmuxWindow: TmuxWindow?
    /// Its top in the card's rows, without the drag's offset.
    var place: CGFloat = 0
    private let plate = LiftPlateView()
    private var look = Look.resting

    /// The rows from the top.
    var rows: [CardRowView] = [] {
        didSet {
            let views = [plate] + rows.map { $0 as NSView }
            if subviews != views { subviews = views }
        }
    }

    init(id: String) {
        self.id = id
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

    /// The height of the rows in a unit `width` wide, with `CardSpacing.row` between two rows.
    func height(width: CGFloat) -> CGFloat {
        rows.map { $0.height(width: width) }.reduce(0, +) + CardSpacing.row * CGFloat(max(0, rows.count - 1))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layOut()
    }

    /// Stacks the rows from the top, and puts the plate under them.
    func layOut() {
        plate.frame = bounds
        var top: CGFloat = 0
        for row in rows {
            row.frame = NSRect(x: 0, y: top, width: bounds.width, height: row.height(width: bounds.width))
            top = row.frame.maxY + CardSpacing.row
        }
        // The scale's point stays with the unit's size.
        LayerGlide.withoutActions { layer?.sublayerTransform = transform(scale: scale(look, reducesMotion: reducesMotion)) }
    }

    private var reducesMotion = false

    /// Shows the look, moving to it by `motion`. With Reduce Motion the unit does not sink or grow.
    func show(_ look: Look, reducesMotion: Bool, motion: LayerMotion) {
        self.look = look
        self.reducesMotion = reducesMotion
        if let layer {
            LayerGlide.set("sublayerTransform", of: layer, to: NSValue(caTransform3D: transform(scale: scale(look, reducesMotion: reducesMotion))),
                           motion: motion)
        }
        plate.show(look == .resting ? .none : look == .pressed ? .plate : .shadow, motion: motion)
    }

    private func scale(_ look: Look, reducesMotion: Bool) -> CGFloat {
        guard !reducesMotion else { return 1 }
        switch look {
        case .resting: return 1
        case .pressed: return ListLift.pressScale
        case .lifted: return ListLift.scale
        }
    }

    /// `scale` around `ListLift.anchor` of the unit's size. A flipped view's layer counts from its top left corner.
    private func transform(scale: CGFloat) -> CATransform3D {
        let x = bounds.width * ListLift.anchor.x, y = bounds.height * ListLift.anchor.y
        return CATransform3DTranslate(CATransform3DScale(CATransform3DMakeTranslation(x, y, 0), scale, scale, 1), -x, -y, 0)
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
    private let shade = LiftShadowView()
    private let material = NSVisualEffectView()
    private let face = LiftFaceView()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        material.material = .sidebar
        material.blendingMode = .behindWindow
        material.state = .followsWindowActiveState
        material.wantsLayer = true
        material.layer?.cornerRadius = WindowRowMetrics.cornerRadius
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

    func show(_ shows: Shows, motion: LayerMotion) {
        if let layer { LayerGlide.set("opacity", of: layer, to: Float(shows == .none ? 0 : 1), motion: motion) }
        shade.show(shows == .shadow, motion: motion)
    }
}

/// The shadow of a lifted unit, in the unit's rounded shape. The shadow is a layer under the view's own, because AppKit
/// takes the shadow off the layer of a view.
private final class LiftShadowView: NSView {
    private let shape = CALayer()

    init() {
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
            shape.shadowPath = CGPath(roundedRect: bounds, cornerWidth: WindowRowMetrics.cornerRadius,
                                      cornerHeight: WindowRowMetrics.cornerRadius, transform: nil)
        }
    }

    func show(_ shows: Bool, motion: LayerMotion) {
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

    init() {
        super.init(frame: .zero)
        layer = CALayer()
        wantsLayer = true
        for shape in [under, fill] {
            shape.cornerRadius = WindowRowMetrics.cornerRadius
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

/// The place where a lifted unit would land: a slot of its size, in the accent colour, with a dashed border. `DropSlot`
/// in SwiftUI.
final class DropSlotView: LayerColoredView {
    private let fill = CALayer()
    private let border = CAShapeLayer()

    init() {
        super.init(frame: .zero)
        layer = CALayer()
        wantsLayer = true
        fill.cornerRadius = WindowRowMetrics.cornerRadius
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
            let radius = max(0, WindowRowMetrics.cornerRadius - ListLift.slotBorderWidth / 2)
            border.path = inset.width > 0 && inset.height > 0
                ? CGPath(roundedRect: inset, cornerWidth: radius, cornerHeight: radius, transform: nil) : nil
        }
    }

    override func colorLayers() {
        fill.backgroundColor = NSColor.controlAccentColor.faded(ListLift.slotFillOpacity).cgColor
        border.strokeColor = NSColor.controlAccentColor.faded(ListLift.slotBorderOpacity).cgColor
    }

    /// The slot shows, or not, moving to it by `motion`.
    func show(_ shows: Bool, motion: LayerMotion?) {
        guard let layer else { return }
        LayerGlide.set("opacity", of: layer, to: Float(shows ? 1 : 0), motion: motion)
    }

    var shows: Bool { (layer?.opacity ?? 0) > 0 }
}
