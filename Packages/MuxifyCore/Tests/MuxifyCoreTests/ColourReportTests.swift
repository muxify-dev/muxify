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

    func testMuxifysClientsAreTheNormalClientsThatAMarkerNames() {
        let clients = [
            TmuxClient(tty: "/dev/ttys001", sessionID: "$1", windowID: "@1", pid: 10),
            TmuxClient(tty: "/dev/ttys002", sessionID: "$2", windowID: "@2", pid: 20),
            TmuxClient(tty: "/dev/ttys003", sessionID: "$3", windowID: "@3", pid: 30, isControl: true),
            // A marker whose pid now belongs to another Client at another tty.
            TmuxClient(tty: "/dev/ttys004", sessionID: "$4", windowID: "@4", pid: 40),
        ]
        let options = """
            @muxify_browser_socket /tmp/b.sock
            @muxify_client_a "10␟/dev/ttys001␟/Users/me␟My Mac␟local"
            @muxify_client_b 30␟/dev/ttys003␟/h␟h␟local
            @muxify_client_c 40␟/dev/ttys009␟/h␟h␟local
            @muxify_last_window @1
            """
        XCTAssertEqual(ColourReport.shownSessions(clients: clients, serverOptions: options), ["$1"])
    }

    func testEverySwitchClientOfAnInvocationNamesItsTarget() {
        XCTAssertEqual(ColourReport.switchTargets(in: ["switch-client", "-Z", "-c", "/dev/ttys001", "-t", "$1:@2"]), ["$1:@2"])
        XCTAssertEqual(ColourReport.switchTargets(in: ["kill-window", "-t", "@1", ";", "switch-client", "-c", "/dev/x", "-t", "$2:@3"]),
                       ["$2:@3"])
        XCTAssertEqual(ColourReport.switchTargets(in: ["send-keys", "-t", "%1", "switch-client", "-t", "x"]), [])
        XCTAssertEqual(ColourReport.switchTargets(in: ["switch-client", "-c", "/dev/x"]), [])
    }

    func testAReadReportsOnlyTheSessionsThatAreNewlyShownAndAForcedReadReportsAll() {
        var state = ColourReportState()
        XCTAssertEqual(state.sessionsToReport(shown: ["$1"], all: false), ["$1"])
        XCTAssertEqual(state.sessionsToReport(shown: ["$1"], all: false), [], "nothing changed")
        XCTAssertEqual(state.sessionsToReport(shown: ["$1", "$2"], all: false), ["$2"])
        XCTAssertEqual(state.sessionsToReport(shown: ["$2"], all: false), [], "a Session that is no longer shown")
        XCTAssertEqual(state.sessionsToReport(shown: ["$1", "$2"], all: true), ["$1", "$2"])
    }
}
