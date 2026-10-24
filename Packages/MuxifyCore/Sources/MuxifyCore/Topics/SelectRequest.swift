import Foundation

public enum SelectRequest: Equatable, Sendable {
    case session(String)
    case window(String)
    case topic(String)
}
