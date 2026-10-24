import Foundation

extension Process {
    /// Runs the process and returns the wait for its exit, which ends as soon as the process exits.
    ///
    /// `waitUntilExit()` spins the run loop and sees the exit only about 60 ms late. Every tmux and git command
    /// waits for its process, so a 10 ms command cost about 70 ms.
    public func start() throws -> ProcessExit {
        let exited = DispatchSemaphore(value: 0)
        terminationHandler = { _ in exited.signal() }
        try run()
        return ProcessExit(exited: exited)
    }
}

/// The exit of a process that `Process.start()` ran. Wait for it once.
public struct ProcessExit {
    fileprivate let exited: DispatchSemaphore

    public func wait() { exited.wait() }
}
