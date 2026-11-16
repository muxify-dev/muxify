import XCTest
@testable import MuxifyCLI
import MuxifyCore

final class SessionPathsInvocationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func command(_ arguments: [String]) throws -> CLICommand {
        try CLICommand(arguments: arguments, environment: ["HOME": "/home/me"], now: now)
    }

    func testSessionPathsNeedsNoTargetAndTakesAQuery() throws {
        guard case .sessionPaths(let list) = try command(["session-paths", "--json"]) else { return XCTFail("Wrong command") }
        XCTAssertEqual(list.action, .list(query: ""))
        XCTAssertEqual(list.output, .json)
        guard case .sessionPaths(let query) = try command(["session-paths", "--query", "mob app"]) else { return XCTFail("Wrong command") }
        XCTAssertEqual(query.action, .list(query: "mob app"))
        guard case .sessionPaths(let refresh) = try command(["session-paths", "refresh"]) else { return XCTFail("Wrong command") }
        XCTAssertEqual(refresh.action, .refresh)
        for arguments in [["session-paths", "extra"], ["session-paths", "--topic", "fix"], ["session-paths", "visit"],
                          ["session-paths", "visit", "/a", "/b"], ["session-paths", "refresh", "now"]] {
            XCTAssertThrowsError(try command(arguments), "\(arguments)") { XCTAssertEqual(($0 as? CLIError)?.exitCode, 2) }
        }
    }

    func testAVisitIsARequestThatASecondSendMayRunAgain() throws {
        let id = "3F2B8C1E-7A4D-4E9B-9C0A-5D6E7F8A9B0C"
        guard case .request(let visit) = try command(["session-paths", "visit", "/work/app", "--request", id]) else { return XCTFail("Wrong command") }
        XCTAssertEqual(visit.command, .visitSessionPath(directory: "/work/app", at: now))
        XCTAssertEqual(visit.command.requestPolicy, .rerun)
        XCTAssertEqual(visit.request?.id, RequestID(id))
        XCTAssertEqual(visit.request?.verb, "session-paths visit")
        XCTAssertNil(visit.target)
        XCTAssertThrowsError(try command(["session-paths", "--request", id])) { XCTAssertEqual(($0 as? CLIError)?.exitCode, 2) }
    }

    func testTheRowsPrintInRankOrderWithTheLastVisitInISO8601() throws {
        let rows = SessionPathRows.build(sessionPaths: [SessionPath(path: "/work/app", name: "app", alias: "App"), SessionPath(path: "/work/game", name: "game")],
                                         windows: [], records: [])
        let ranked = SessionPathRanking.rank(rows, query: "", visits: [.directory("/work/game"): now], tiebreak: PaletteTiebreak.standard, home: "/home/me")
        XCTAssertEqual(try SessionPathsInvocation.render(ranked, output: .json),
                       #"{"rows":[{"also_in":[],"directory":"/work/game","kind":"session_path","label":"game","last_visit":"2023-11-14T22:13:20Z","name":"game","worktree":null},"#
                       + #"{"also_in":[],"directory":"/work/app","kind":"session_path","label":"App","last_visit":null,"name":"app","worktree":null}]}"#)
        XCTAssertEqual(try SessionPathsInvocation.render(ranked, output: .text),
                       "game\tsession_path\t/work/game\t2023-11-14T22:13:20Z\napp\tsession_path\t/work/app\t")
    }
}
