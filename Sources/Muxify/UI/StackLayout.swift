import CoreGraphics

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

    /// Where `id` lands with the pointer at `probe`, a y in the stack: before the first item above it whose middle the
    /// probe passed, after the last item below it whose middle the probe passed, or nil at its own place. The probe is
    /// the pointer, not an edge of the item, so a tall item and a short one land at the same pointer position.
    /// A fixed slot is no place to land, so the item passes it as it passes the gap between two items.
    /// Only the slots in `side` are places to land.
    func placement(of id: ID, at probe: CGFloat, in order: [StackSlot<ID>], side: Range<Int>? = nil) -> DropPlacement<ID>? {
        guard let index = order.firstIndex(of: .item(id)) else { return nil }
        let side = side ?? order.indices
        let middle = { (slot: StackSlot<ID>) in self.top(of: slot, in: order) + self.height(slot) / 2 }
        if let passed = order[side.lowerBound..<index].first(where: { $0.item != nil && probe < middle($0) })?.item {
            return .before(passed)
        }
        if let passed = order[(index + 1)..<side.upperBound].last(where: { $0.item != nil && probe > middle($0) })?.item {
            return .after(passed)
        }
        return nil
    }

    /// Where `id` lands with the pointer at `probe`, in a list that the fixed slots `dividers` split into sections. In
    /// its own section, it lands as `placement` gives. Once the probe passes the middle of the next divider, the item is
    /// across, and there it trades with the item under the probe, in any section past that divider. In a gap, or past
    /// the last item, it trades with the nearest item the probe reached; before it reaches one, with none.
    /// Without dividers, as `placement`.
    func landing(of id: ID, at probe: CGFloat, in order: [StackSlot<ID>], dividers: [String]) -> DropLanding<ID>? {
        guard let index = order.firstIndex(of: .item(id)) else { return nil }
        let lines = dividers.compactMap { order.firstIndex(of: .fixed($0)) }.sorted()
        guard !lines.isEmpty else { return placement(of: id, at: probe, in: order).map(DropLanding.place) }
        let above = lines.last { $0 < index }, below = lines.first { $0 > index }
        let top = { (slot: StackSlot<ID>) in self.top(of: slot, in: order) }
        let middle = { (slot: StackSlot<ID>) in top(slot) + self.height(slot) / 2 }
        if let below, probe > middle(order[below]) {
            return .across(trade: order[(below + 1)...].last { $0.item != nil && top($0) <= probe }?.item)
        }
        if let above, probe < middle(order[above]) {
            return .across(trade: order[..<above].first { $0.item != nil && top($0) + self.height($0) >= probe }?.item)
        }
        let side = (above.map { $0 + 1 } ?? 0)..<(below ?? order.count)
        return placement(of: id, at: probe, in: order, side: side).map(DropLanding.place)
    }

    /// `translation` held so `id` stays within the list, from the top of its first item to the bottom of its last, and
    /// moves up no more than `headroom` and down no more than `footroom`. An item that is already past the headroom
    /// does not move up at all, and one past the footroom does not move down. With a divider in the list, it can go
    /// down to the bottom of the view, past a divider that ends the list: the pointer, not the item's bottom edge,
    /// decides when it crosses. Without a known footroom, its bottom stops at the end of the last slot.
    func bounded(_ translation: CGFloat, of id: ID, in order: [StackSlot<ID>], headroom: CGFloat = .infinity,
                 footroom: CGFloat = .infinity, dividers: [String] = []) -> CGFloat {
        guard let first = order.first(where: { $0.item != nil }), let last = order.last(where: { $0.item != nil }) else {
            return translation
        }
        let top = top(of: .item(id), in: order)
        let low = max(self.top(of: first, in: order) - top, -max(headroom, 0))
        var high = max(low, self.top(of: last, in: order) + height(last) - top - height(.item(id)))
        if dividers.contains(where: { order.contains(.fixed($0)) }), let end = order.last {
            high = max(high, footroom.isFinite ? footroom : self.top(of: end, in: order) + height(end) - top - height(.item(id)))
        }
        high = max(low, min(high, max(footroom, 0)))
        return min(max(translation, low), high)
    }

    /// Where the lifted `id` shows and where it lands, with the pointer `moved` down from where it pressed the item,
    /// `grab` below the item's top: `bounded` holds how far the item moves, and the pointer, kept on the item where
    /// `bounded` stops it, gives the landing. So the item reaches no item out of view, and still crosses a divider
    /// that ends the list.
    func follow(_ id: ID, moved: CGFloat, grab: CGFloat, in order: [StackSlot<ID>], headroom: CGFloat = .infinity,
                footroom: CGFloat = .infinity, dividers: [String] = []) -> (translation: CGFloat, landing: DropLanding<ID>?) {
        let translation = bounded(moved, of: id, in: order, headroom: headroom, footroom: footroom, dividers: dividers)
        let place = top(of: .item(id), in: order), drawn = place + translation
        let probe = min(max(place + grab + moved, drawn), drawn + height(.item(id)))
        return (translation, landing(of: id, at: probe, in: order, dividers: dividers))
    }

    /// How far `slot` moves from its place in `shown` to its place once `id` moves to `placement`.
    func shift(of slot: StackSlot<ID>, moving id: ID, to placement: DropPlacement<ID>, in shown: [StackSlot<ID>]) -> CGFloat {
        top(of: slot, in: placement.placing(id, in: shown)) - top(of: slot, in: shown)
    }
}

/// Where an item stands in its scroll view: its height, how far its top is below the visible top (or below a header
/// that sticks there), how far its bottom is above the visible bottom, and its top in the window.
struct ItemPlace: Equatable {
    var height: CGFloat
    var visibleTop: CGFloat
    var footroom: CGFloat
    var windowTop: CGFloat
}
