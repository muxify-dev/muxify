import Foundation
import MuxifyCore

/// Exact-named Session to open, or start in this folder. Folder ownership is not Session identity.
struct OpenDirectory: Hashable {
    let directory: Folder
    let name: String
}
