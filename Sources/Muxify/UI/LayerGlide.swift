import AppKit
import QuartzCore

/// The glide of the AppKit Sessions list when a change moves its views, such as a card that opens (ADR 0074).
/// The views lay out by frames, so a change puts every layer in its new place at once. `run` then moves each layer
/// that the change moved from where it showed to its new place with Core Animation: its position, its size and its
/// opacity.
enum LayerGlide {
    /// Where a layer is, and where it shows: the two differ while an animation moves the layer.
    private struct Place {
        let layer: (position: CGPoint, bounds: CGRect, opacity: Float)
        let shown: (position: CGPoint, bounds: CGRect, opacity: Float)
    }

    /// Makes `change`, and glides the layers under `root` to where it puts them. A layer that the change adds stands
    /// in its place at once, and a layer that the change leaves alone keeps the animations it has.
    static func run(under root: CALayer, duration: CFTimeInterval, timing: CAMediaTimingFunction, change: () -> Void) {
        var before: [ObjectIdentifier: Place] = [:]
        visit(root) { layer in
            let shown = layer.presentation() ?? layer
            before[ObjectIdentifier(layer)] = Place(layer: (layer.position, layer.bounds, layer.opacity),
                                                    shown: (shown.position, shown.bounds, shown.opacity))
        }
        withoutActions(change)
        visit(root) { layer in
            guard let old = before[ObjectIdentifier(layer)] else { return }
            let moves: [(key: String, from: Any, moved: Bool)] = [
                ("position", old.shown.position, old.layer.position != layer.position),
                ("bounds", old.shown.bounds, old.layer.bounds != layer.bounds),
                ("opacity", old.shown.opacity, old.layer.opacity != layer.opacity),
            ]
            for move in moves where move.moved {
                // From where the layer showed, which is the middle of an earlier glide when one still ran.
                let animation = CABasicAnimation(keyPath: move.key)
                animation.fromValue = move.from
                animation.duration = duration
                animation.timingFunction = timing
                layer.add(animation, forKey: "glide-" + move.key)
            }
        }
    }

    /// Makes a change to layers with no animation of Core Animation's own.
    static func withoutActions(_ change: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        change()
        CATransaction.commit()
    }

    private static func visit(_ layer: CALayer, _ body: (CALayer) -> Void) {
        body(layer)
        layer.mask.map { visit($0, body) }
        for sublayer in layer.sublayers ?? [] { visit(sublayer, body) }
    }
}
