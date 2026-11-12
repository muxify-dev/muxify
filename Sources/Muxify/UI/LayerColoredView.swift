import AppKit

/// A view of an AppKit area that colours its own layers (ADR 0074): the one owner of how it does so. A layer keeps the
/// colour it got, and a colour such as the text colour differs between the light and the dark appearance. So the view
/// colours its layers in its own effective appearance, with no animation of Core Animation's own, and again when it
/// joins a window and when its appearance changes. A view whose colours also follow an input of its own calls
/// `recolor()` when that input changes, so they still resolve in its appearance.
class LayerColoredView: NSView {
    /// Sets the colours of the view's layers. A subclass overrides it, and only `recolor()` runs it: in the view's
    /// effective appearance, with no implicit animation.
    func colorLayers() {}

    /// Colours the layers again in the view's effective appearance, with no implicit animation.
    final func recolor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            LayerGlide.withoutActions(colorLayers)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        recolor()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        recolor()
    }
}
