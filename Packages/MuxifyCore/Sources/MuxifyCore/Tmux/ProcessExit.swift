#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

extension Process {
    /// Runs the process and returns the wait for its exit, which ends as soon as the process exits.
    ///
    /// `waitUntilExit()` spins the run loop and sees the exit only about 60 ms late. Every tmux and git command
    /// waits for its process, so a 10 ms command cost about 70 ms.
    public func start() throws -> ProcessExit {
        let exited = DispatchSemaphore(value: 0)
        terminationHandler = { _ in exited.signal() }
        #if os(Linux)
        // A child starts with the signal mask of the thread that starts it, and Dispatch's threads block nearly every
        // signal. The child would then ignore SIGTERM, and a `wait` in dash would never see its jobs end.
        var unblocked = sigset_t(), previous = sigset_t()
        sigemptyset(&unblocked)
        pthread_sigmask(SIG_SETMASK, &unblocked, &previous)
        defer { pthread_sigmask(SIG_SETMASK, &previous, nil) }
        #endif
        try run()
        #if os(Linux)
        // Foundation on Linux sees an exit only when a socket that the child inherits closes, so it waits for every
        // process that the child left behind, such as the tmux server that a tmux command starts. waitid sees the
        // child's own exit, and WNOWAIT leaves the child for Foundation to reap.
        let ended = ProcessExit.Ended()
        let pid = id_t(processIdentifier)
        Thread.detachNewThread { [self] in
            var info = siginfo_t()
            var result: Int32
            repeat { result = waitid(P_PID, pid, &info, WEXITED | WNOWAIT) } while result == -1 && errno == EINTR
            if result == 0 {
                ended.set(ProcessTermination(info))
            } else {
                // Foundation reaped the child first, and its handler follows.
                exited.wait()
                ended.set(ProcessTermination(status: terminationStatus, reason: terminationReason))
            }
        }
        return ProcessExit(ended: ended)
        #else
        return ProcessExit(process: self, exited: exited)
        #endif
    }
}

/// How a process ended: its exit status, or the signal that ended it.
public struct ProcessTermination: Equatable {
    public let status: Int32
    public let reason: Process.TerminationReason

    public init(status: Int32, reason: Process.TerminationReason) {
        self.status = status
        self.reason = reason
    }

    #if os(Linux)
    fileprivate init(_ info: siginfo_t) {
        #if canImport(Musl)
        let status = info.__si_fields.__si_common.__second.__sigchld.si_status
        #else
        let status = info._sifields._sigchld.si_status
        #endif
        let exited = info.si_code == Int32(CLD_EXITED)
        self.init(status: status, reason: exited ? .exit : .uncaughtSignal)
    }
    #endif
}

/// The exit of a process that `Process.start()` ran. Wait for it once.
public struct ProcessExit {
    #if os(Linux)
    fileprivate let ended: Ended

    @discardableResult
    public func wait() -> ProcessTermination { ended.wait() }

    fileprivate final class Ended: @unchecked Sendable {
        private let signal = DispatchSemaphore(value: 0)
        private var termination: ProcessTermination?

        func set(_ termination: ProcessTermination) {
            self.termination = termination
            signal.signal()
        }

        func wait() -> ProcessTermination {
            signal.wait()
            return termination!
        }
    }
    #else
    fileprivate let process: Process
    fileprivate let exited: DispatchSemaphore

    @discardableResult
    public func wait() -> ProcessTermination {
        exited.wait()
        return ProcessTermination(status: process.terminationStatus, reason: process.terminationReason)
    }
    #endif
}
