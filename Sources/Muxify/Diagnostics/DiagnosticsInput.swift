import AppKit
import MuxifyCore
import os

/// Counts the user's input for the `minute` record: key presses, clicks and scroll events from a local event monitor
/// (the app's own events, so no permission), and the Sidebar mode switches and Command Palette opens those events
/// make. It keeps counts only, never which key, text, a title or a URL.
enum DiagnosticsInput {
    private static let counts = OSAllocatedUnfairLock(initialState: InputCounts())
    private static var monitor: Any?
    private static let userEvents: Set<NSEvent.EventType> = [
        .keyDown, .keyUp, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
        .scrollWheel, .swipe, .gesture,
    ]

    /// On the main thread.
    static func start() {
        guard monitor == nil else { return }
        _ = take()
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { event in
            switch event.type {
            case .keyDown where !event.isARepeat: count(\.keys)
            case .leftMouseDown, .rightMouseDown, .otherMouseDown: count(\.clicks)
            case .scrollWheel: count(\.scrolls)
            default: break
            }
            return event
        }
    }

    /// On the main thread.
    static func stop() {
        monitor.map(NSEvent.removeMonitor)
        monitor = nil
    }

    /// Counts while Diagnostics is off too; `start` forgets them.
    private static func count(_ kind: WritableKeyPath<InputCounts, Int>) {
        counts.withLock { $0[keyPath: kind] += 1 }
    }

    /// Counts a Sidebar mode switch or a Command Palette open that the user's key press, click or scroll makes, not
    /// one the app makes by itself, such as Start a Session… at launch. On the main thread.
    static func countUserAction(_ kind: WritableKeyPath<InputCounts, Int>) {
        guard let type = NSApp.currentEvent?.type, userEvents.contains(type) else { return }
        count(kind)
    }

    /// The counts since the last take, and starts again from zero. Any thread.
    static func take() -> InputCounts {
        counts.withLock { counts in
            defer { counts = InputCounts() }
            return counts
        }
    }
}
