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
        run(under: root, motion: .curve(duration: duration, timing: timing), change: change)
    }

    /// `run` with the layers moving by `motion`, such as a spring.
    static func run(under root: CALayer, motion: LayerMotion, change: () -> Void) {
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
                let animation = motion.animation(move.key)
                animation.fromValue = move.from
                layer.add(animation, forKey: "glide-" + move.key)
            }
        }
    }

    /// Sets the layer's `keyPath` to `value`. With `motion`, it moves there from where it shows now, which is the
    /// middle of an earlier move when one still runs; without, it stands there at once.
    static func set(_ keyPath: String, of layer: CALayer, to value: Any, motion: LayerMotion?) {
        if let current = layer.value(forKeyPath: keyPath) as? NSObject, current.isEqual(value) { return }
        let shown = (layer.presentation() ?? layer).value(forKeyPath: keyPath)
        withoutActions { layer.setValue(value, forKeyPath: keyPath) }
        guard let motion else { return layer.removeAnimation(forKey: "set-" + keyPath) }
        let animation = motion.animation(keyPath)
        animation.fromValue = shown
        layer.add(animation, forKey: "set-" + keyPath)
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

/// How a layer of the AppKit Sessions list moves to a new value (ADR 0074): along a timing curve, or on a spring as
/// SwiftUI's `spring(duration:bounce:)` names it.
enum LayerMotion: Equatable {
    case curve(duration: CFTimeInterval, timing: CAMediaTimingFunction)
    case spring(duration: CFTimeInterval, bounce: CGFloat)

    static func easeOut(_ duration: CFTimeInterval) -> LayerMotion {
        .curve(duration: duration, timing: CAMediaTimingFunction(name: .easeOut))
    }

    /// The animation of `keyPath` that ends at the layer's value. A spring runs until it comes to rest.
    func animation(_ keyPath: String) -> CABasicAnimation {
        switch self {
        case .curve(let duration, let timing):
            let animation = CABasicAnimation(keyPath: keyPath)
            animation.duration = duration
            animation.timingFunction = timing
            return animation
        case .spring(let duration, let bounce):
            let spring = CASpringAnimation(perceptualDuration: duration, bounce: bounce)
            spring.keyPath = keyPath
            spring.duration = spring.settlingDuration
            return spring
        }
    }
}
