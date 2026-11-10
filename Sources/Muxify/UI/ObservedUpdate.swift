import Foundation
import Observation

/// The update of an AppKit view from the `@Observable` models it reads (ADR 0074). `run` updates the view now. After
/// that, a change to any state the update read runs it again, once in a turn of the run loop, whatever the number of
/// changes in that turn.
///
/// `withObservationTracking` reports a change before the new state is stored, as `ObservedCache` says. So the update
/// does not run when a change is reported: it waits for the next turn of the main queue, where it reads the new
/// state.
@MainActor final class ObservedUpdate {
    private let update: () -> Void
    /// The number of the latest run. An earlier run's tracking can still report a change, which that run's update
    /// already read or the latest run tracks.
    private var runs = 0

    init(_ update: @escaping () -> Void) {
        self.update = update
    }

    func run() {
        runs &+= 1
        let run = runs
        withObservationTracking(update) { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.runs == run else { return }
                self.run()
            }
        }
    }
}
