import AppKit
import ObjectiveC

/// Part of Diagnostics: logs every AppKit animation that starts, with its display link and the state of its
/// window, and every link that keeps running after its animation let go of it.
///
/// Such links pile up behind a Sidebar list's scroll animations. On a Space switch AppKit updates each one,
/// so thousands of them freeze the app for seconds. The probe is for finding what leaves them behind; it
/// reads AppKit's private state, so remove it once that is known. It numbers the animations from launch, so
/// numbers go on after diagnostics is turned off and on.
enum DisplayLinkProbe {
    private final class Tracked {
        let number: Int
        let started: TimeInterval
        let duration: TimeInterval
        weak var link: NSObject?
        weak var animation: NSAnimation?
        var reportedStuck = false
        var reportedLeak = false

        init(number: Int, link: NSObject, animation: NSAnimation) {
            self.number = number
            started = ProcessInfo.processInfo.systemUptime
            duration = animation.duration
            self.link = link
            self.animation = animation
        }
    }

    /// A link this long past its start that no animation owns any more is a leak, not an asynchronous invalidate.
    private static let grace: TimeInterval = 3

    private static var tracked: [ObjectIdentifier: Tracked] = [:]
    private static var started = 0
    private static var leaked = 0
    private static var sweepTimer: Timer?

    private static let displayLinkIvar = class_getInstanceVariable(NSAnimation.self, "_displayLink")
    private static let scrollHelperClass: AnyClass? = NSClassFromString("NSScrollAnimationHelper")
    private static let appKitLinkClass: AnyClass? = NSClassFromString("_NSDisplayLink")
    /// Hooked on the first start and never unhooked: while the probe is off, the hook only calls AppKit's method.
    private static let hooked = displayLinkIvar != nil && hookStartAnimation()

    /// For other lines of the log: the leaked links the last sweep counted, once the probe runs.
    static var summary: String {
        sweepTimer == nil ? "" : ", \(leaked) leaked display links"
    }

    static func start() {
        guard sweepTimer == nil else { return }
        guard hooked else {
            Diagnostics.write("display links: NSAnimation has no _displayLink or startAnimation on this macOS, so the probe is off")
            return
        }
        let timer = Timer(timeInterval: 5, repeats: true) { _ in sweep() }
        RunLoop.main.add(timer, forMode: .common)
        sweepTimer = timer
    }

    static func stop() {
        sweepTimer?.invalidate()
        sweepTimer = nil
        tracked = [:]
        leaked = 0
    }

    private static func hookStartAnimation() -> Bool {
        let selector = NSSelectorFromString("startAnimation")
        guard let method = class_getInstanceMethod(NSAnimation.self, selector) else { return false }
        typealias Start = @convention(c) (NSAnimation, Selector) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Start.self)
        let hook: @convention(block) (NSAnimation) -> Void = { animation in
            guard Thread.isMainThread, sweepTimer != nil else { return original(animation, selector) }
            let old = link(of: animation)
            let wasAnimating = animation.isAnimating
            original(animation, selector)
            didStart(animation, old: old, wasAnimating: wasAnimating)
        }
        method_setImplementation(method, imp_implementationWithBlock(hook))
        return true
    }

    private static func didStart(_ animation: NSAnimation, old: NSObject?, wasAnimating: Bool) {
        started += 1
        let new = link(of: animation)
        // A link made after startAnimation returned shows up only as the old link of the next start.
        for candidate in [old, new].compactMap({ $0 }) where tracked[ObjectIdentifier(candidate)]?.link !== candidate {
            tracked[ObjectIdentifier(candidate)] = Tracked(number: started, link: candidate, animation: animation)
        }
        var line = "animation #\(started) \(type(of: animation)) \(Diagnostics.address(animation)) "
            + "duration \(Diagnostics.seconds(animation.duration)) link \(Diagnostics.address(old)) -> \(Diagnostics.address(new))"
        if let new { line += " via \(provider(of: new))" }
        if wasAnimating { line += " restarted" }
        if let old, old !== new, isRunning(old) { line += " old-link-still-running" }
        var window: NSWindow?
        if let scrollHelperClass, animation.isKind(of: scrollHelperClass) {
            let from = point(animation, "_startPoint"), to = point(animation, "_endPoint")
            line += " scroll \(text(from)) -> \(text(to))"
            if from == to { line += " zero-distance" }
            window = (ivar(animation, scrollHelperClass, "_delegate") as? NSView)?.window
        }
        Diagnostics.write(line + " | " + Diagnostics.describe(window))
    }

    /// Counts the links that still run with no animation that owns them, and logs each one once.
    private static func sweep() {
        let now = ProcessInfo.processInfo.systemUptime
        var running = 0, orphans = 0
        for (key, entry) in tracked {
            guard let link = entry.link else { tracked[key] = nil; continue }
            guard isRunning(link) else { continue }
            running += 1
            let animation = entry.animation
            let owned = animation.map { $0.isAnimating && self.link(of: $0) === link } ?? false
            guard !owned else {
                if !entry.reportedStuck, now - entry.started > entry.duration + grace {
                    entry.reportedStuck = true
                    Diagnostics.write("display link stuck: #\(entry.number) link \(Diagnostics.address(link)) still animating "
                        + "\(Diagnostics.seconds(now - entry.started)) after start, duration \(Diagnostics.seconds(entry.duration))")
                }
                continue
            }
            guard now - entry.started > grace else { continue }
            orphans += 1
            guard !entry.reportedLeak else { continue }
            entry.reportedLeak = true
            Diagnostics.write("display link LEAK: #\(entry.number) link \(Diagnostics.address(link)) via \(provider(of: link)) "
                + "still runs \(Diagnostics.seconds(now - entry.started)) after start; animation \(Diagnostics.address(animation)) "
                + (animation.map { "animating \($0.isAnimating) now holds \(Diagnostics.address(self.link(of: $0)))" } ?? "is gone"))
        }
        if orphans != leaked {
            leaked = orphans
            Diagnostics.write("display links: \(running) running, \(orphans) leaked, \(tracked.count) tracked")
        }
    }

    private static func link(of animation: NSAnimation) -> NSObject? {
        displayLinkIvar.flatMap { object_getIvar(animation, $0) as? NSObject }
    }

    /// An `_NSDisplayLink` holds itself in `_keepAliveSelf` until it is invalidated.
    private static func isRunning(_ link: NSObject) -> Bool {
        guard let appKitLinkClass, link.isKind(of: appKitLinkClass) else { return true }
        return ivar(link, appKitLinkClass, "_keepAliveSelf") != nil
    }

    private static func provider(of link: NSObject) -> String {
        guard let appKitLinkClass, link.isKind(of: appKitLinkClass) else { return String(describing: type(of: link)) }
        return ivar(link, appKitLinkClass, "_provider").map { String(describing: type(of: $0 as AnyObject)) } ?? "no provider"
    }

    private static func ivar(_ object: AnyObject, _ cls: AnyClass, _ name: String) -> Any? {
        class_getInstanceVariable(cls, name).flatMap { object_getIvar(object, $0) }
    }

    private static func point(_ object: AnyObject, _ name: String) -> CGPoint? {
        guard let ivar = class_getInstanceVariable(type(of: object), name) else { return nil }
        return Unmanaged.passUnretained(object).toOpaque().load(fromByteOffset: ivar_getOffset(ivar), as: CGPoint.self)
    }

    private static func text(_ point: CGPoint?) -> String {
        point.map { "(\($0.x + 0), \($0.y + 0))" } ?? "-"
    }
}
