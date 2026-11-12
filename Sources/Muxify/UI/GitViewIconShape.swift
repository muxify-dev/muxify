import CoreGraphics

/// The outline of the Git View's symbol, for `GitViewIcon` and for the Window row of the AppKit Sessions list
/// (ADR 0074). It counts down from the top of `rect`, as SwiftUI and a flipped view do.
enum GitViewIconShape {
    /// The width of the stroke in a square `side` points wide.
    static func lineWidth(side: CGFloat) -> CGFloat { side * 1.5 / 16 }

    static func path(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        for center in [CGPoint(x: 4.5, y: 3.5), CGPoint(x: 11.5, y: 3.5), CGPoint(x: 4.5, y: 12.5)] {
            path.addEllipse(in: CGRect(x: center.x - 1.75, y: center.y - 1.75, width: 3.5, height: 3.5))
        }
        path.move(to: CGPoint(x: 5.25, y: 8.25))
        path.addCurve(to: CGPoint(x: 11.25, y: 5.75), control1: CGPoint(x: 8.25, y: 8.25), control2: CGPoint(x: 11.25, y: 8.75))
        path.move(to: CGPoint(x: 4.75, y: 10.25))
        path.addLine(to: CGPoint(x: 4.75, y: 5.75))
        let scale = min(rect.width, rect.height) / 16
        var transform = CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: scale, y: scale)
        return path.copy(using: &transform) ?? path
    }
}
