import Foundation
import MuxifyCore

/// A row of the History graph, as lazygit draws `git log --graph`: a lane
/// per line of history, a dot for the commit, and curves where history
/// forks and merges.
struct GitGraphRow: Equatable {
    struct Edge: Equatable {
        enum Kind: Equatable {
            /// Down the whole row, past the commit.
            case through
            /// From the row's top in `lane` into the commit.
            case into
            /// From the commit to the row's bottom in `lane`.
            case out
        }

        let kind: Kind
        let lane: Int
        /// Which of the graph's colors; a lane keeps its color.
        let color: Int
    }

    /// The commit's lane and color.
    let lane: Int
    let color: Int
    var edges: [Edge] = []

    /// How many lanes the row draws in.
    var width: Int { (edges.map(\.lane) + [lane]).max()! + 1 }

    /// Commits newest first, children before their parents
    /// (`git log --topo-order`).
    static func layout(_ commits: [GitCommit]) -> [GitGraphRow] {
        // The commit each lane leads down to next.
        var lanes: [(sha: String, color: Int)?] = []
        var colors = 0
        func newColor() -> Int {
            defer { colors += 1 }
            return colors
        }
        func freeLane() -> Int {
            if let free = lanes.firstIndex(where: { $0 == nil }) { return free }
            lanes.append(nil)
            return lanes.count - 1
        }
        return commits.map { commit in
            // The leftmost lane leading here; a branch's tip starts a lane.
            let expected = lanes.firstIndex { $0?.sha == commit.sha }
            let lane = expected ?? freeLane()
            let color = expected.flatMap { lanes[$0]?.color } ?? newColor()
            var row = GitGraphRow(lane: lane, color: color)
            for (index, entry) in lanes.enumerated() {
                guard let entry else { continue }
                if entry.sha == commit.sha {
                    row.edges.append(Edge(kind: .into, lane: index, color: entry.color))
                    lanes[index] = nil
                } else {
                    row.edges.append(Edge(kind: .through, lane: index, color: entry.color))
                }
            }
            for (number, parent) in commit.parents.enumerated() {
                // A parent another lane leads to already: join that lane,
                // unless it's to the right; then that lane folds into this
                // one at the parent, as `|/` in `git log --graph`.
                if let existing = lanes.firstIndex(where: { $0?.sha == parent }), let entry = lanes[existing],
                   number > 0 || existing < lane {
                    row.edges.append(Edge(kind: .out, lane: existing, color: entry.color))
                    continue
                }
                // The first parent goes on in the commit's lane and color.
                let target = number == 0 && lanes[lane] == nil ? lane : freeLane()
                let laneColor = number == 0 ? color : newColor()
                lanes[target] = (parent, laneColor)
                row.edges.append(Edge(kind: .out, lane: target, color: laneColor))
            }
            while let last = lanes.last, last == nil { lanes.removeLast() }
            return row
        }
    }
}
