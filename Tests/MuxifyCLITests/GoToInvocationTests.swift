import XCTest
@testable import MuxifyCLI
import MuxifyCore
import MuxifyTestSupport

final class GoToInvocationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func command(_ arguments: [String]) throws -> CLICommand {
        try CLICommand(arguments: arguments, environment: ["HOME": "/home/me"], now: now)
    }

    func testGoToNeedsNoTargetAndTakesAQueryTheCurrentSessionAndATag() throws {
        guard case .goTo(let plain) = try command(["go-to", "--json"]) else { return XCTFail("Wrong command") }
        XCTAssertEqual(plain.ask, GoToRequest())
        XCTAssertEqual(plain.output, .json)
        guard case .goTo(let asked) = try command(["go-to", "--query", "mob app", "--current-session", "api", "--tag", "#backend"]) else {
            return XCTFail("Wrong command")
        }
        XCTAssertEqual(asked.ask, GoToRequest(query: "mob app", currentSession: "api", tag: Tag(name: "backend")))
        for arguments in [["go-to", "extra"], ["go-to", "--topic", "fix"], ["go-to", "--tag", "Not A Tag"], ["go-to", "visit"],
                          ["go-to", "visit", "a", "b"], ["go-to", "--request", "3F2B8C1E-7A4D-4E9B-9C0A-5D6E7F8A9B0C"]] {
            XCTAssertThrowsError(try command(arguments), "\(arguments)") { XCTAssertEqual(($0 as? CLIError)?.exitCode, 2) }
        }
    }

    func testAVisitIsARequestThatASecondSendMayRunAgain() throws {
        let id = "3F2B8C1E-7A4D-4E9B-9C0A-5D6E7F8A9B0C"
        guard case .request(let visit) = try command(["go-to", "visit", "api", "--request", id]) else { return XCTFail("Wrong command") }
        XCTAssertEqual(visit.command, .visitSession(name: "api", at: now))
        XCTAssertEqual(visit.command.requestPolicy, .rerun)
        XCTAssertEqual(visit.request?.id, RequestID(id))
        XCTAssertEqual(visit.request?.verb, "go-to visit")
        XCTAssertNil(visit.target)
    }

    func testTheRowsPrintInListOrderWithTheirTargets() throws {
        let window = TmuxWindow.fixture(id: "@1", sessionID: "$1", sessionName: "api", path: "/code/api", sessionPath: "/code/api")
        let input = GoToInput(board: nil, records: [], windows: [window], sessionPaths: [SessionPath(path: "/code/web", name: "web")],
                              sessionMarks: [:], tags: nil, visits: [.session(name: "api"): now.addingTimeInterval(-7200)], current: nil,
                              home: "/code", now: now)
        let answer = GoToAnswer(input.list([.topics, .sessions], query: "", rules: .standard, order: .ranked, payload: { $0 }))
        XCTAssertEqual(try GoToInvocation.render(answer, output: .json),
                       #"{"sections":[{"id":"results","rows":["#
                       + #"{"detail":{"marks":[],"text":"1 window · ~/api"},"id":"session:$1","kind":"session","mark":null,"tags":[],"#
                       + #""target":{"session":{"id":"$1","name":"api"}},"title":{"marks":[],"text":"api"},"trailing":"2h"},"#
                       + #"{"detail":{"marks":[],"text":"~/web"},"id":"session-path:/code/web","kind":"session-path","mark":null,"tags":[],"#
                       + #""target":{"session_path":{"directory":"/code/web","name":"web"}},"title":{"marks":[],"text":"web"},"trailing":"↩ open"}],"#
                       + #""title":null}]}"#)
        XCTAssertEqual(try GoToInvocation.render(answer, output: .text), "session\tapi\t1 window · ~/api\t2h\nsession-path\tweb\t~/web\t↩ open")
    }
}
