import XCTest
@testable import MuxifyCore

final class ColourReportTests: XCTestCase {
    private let light = TerminalColours(background: TerminalColour(red: 0xfb, green: 0xf1, blue: 0xc7),
                                        foreground: TerminalColour(red: 0x3c, green: 0x38, blue: 0x36))

    func testEachPaneGetsABackgroundAndAForegroundReplyAsAControlModeLine() {
        XCTAssertEqual(ColourReport.commands(panes: ["%5", "%12"], colours: light), [
            #"refresh-client -r "%5:\033]11;rgb:fbfb/f1f1/c7c7\033\\""#,
            #"refresh-client -r "%5:\033]10;rgb:3c3c/3838/3636\033\\""#,
            #"refresh-client -r "%12:\033]11;rgb:fbfb/f1f1/c7c7\033\\""#,
            #"refresh-client -r "%12:\033]10;rgb:3c3c/3838/3636\033\\""#,
        ])
    }

    func testAPaneIDThatTmuxDidNotWriteGetsNoLine() {
        XCTAssertEqual(ColourReport.commands(panes: ["%1\" ; kill-server", "", "@2"], colours: light), [])
    }

    func testADetachNamesItsClientAsTmuxNamesIt() {
        XCTAssertEqual(EnvironmentPublisher.detachedClient(in: "%client-detached client-4012"), "client-4012")
        XCTAssertEqual(EnvironmentPublisher.detachedClient(in: "%client-detached /dev/ttys007"), "/dev/ttys007")
        XCTAssertNil(EnvironmentPublisher.detachedClient(in: "%client-detached "))
        XCTAssertNil(EnvironmentPublisher.detachedClient(in: "%client-session-changed /dev/ttys007 $1 work"))
        XCTAssertEqual(TmuxClient(tty: "", sessionID: "$1", windowID: "@1", pid: 4012, isControl: true).name, "client-4012")
        XCTAssertEqual(TmuxClient(tty: "/dev/ttys007", sessionID: "$1", windowID: "@1", pid: 4012).name, "/dev/ttys007")
    }

    func testTheSnapshotTellsAListenerFromAScreenByIgnoreSize() {
        let s = Tmux.separator
        let snapshot = Tmux.parseSnapshot([
            ["C", "", "$1", "@1", "10", "1", "attached,focused,control-mode,ignore-size,no-output,UTF-8"],
            ["C", "", "$1", "@1", "20", "1", "attached,focused,control-mode,UTF-8"],
            ["C", "/dev/ttys001", "$1", "@1", "30", "0"],
        ].map { $0.joined(separator: s) }.joined(separator: "\n"))
        XCTAssertEqual(snapshot.clients.map(\.ignoresSize), [true, false, false])
    }
}
