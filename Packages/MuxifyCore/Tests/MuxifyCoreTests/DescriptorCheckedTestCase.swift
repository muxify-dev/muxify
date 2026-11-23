import XCTest
import MuxifyTestSupport

/// A test class that starts a real tmux server. It fails when it ends with more open file descriptors than it started
/// with, after its own cleanup: see `DescriptorCheck`.
class DescriptorCheckedTestCase: XCTestCase {
    override class func setUp() {
        super.setUp()
        DescriptorCheck.classStarted(self)
    }

    override func invokeTest() {
        super.invokeTest()
        DescriptorCheck.testEnded(Self.self)
    }
}
