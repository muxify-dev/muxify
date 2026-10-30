import XCTest

final class PTYCensusTests: XCTestCase {
    func testTheCensusCountsThePTYsThisProcessOpens() throws {
        let before = PTYCensus.take()
        let held = before.holders.first { $0.pid == getpid() }?.count ?? 0
        var opened: [(master: Int32, slave: Int32)] = []
        defer { opened.forEach { close($0.master); close($0.slave) } }
        for _ in 0..<3 {
            var master: Int32 = -1
            var slave: Int32 = -1
            XCTAssertEqual(openpty(&master, &slave, nil, nil, nil), 0, String(cString: strerror(errno)))
            opened.append((master, slave))
        }
        let after = PTYCensus.take()
        let mine = try XCTUnwrap(after.holders.first { $0.pid == getpid() }, after.summary)
        XCTAssertEqual(mine.count, held + 3, after.summary)
        XCTAssertGreaterThanOrEqual(after.inUse, mine.count)
        XCTAssertGreaterThan(after.limit, 0)
        XCTAssertEqual(after.holders.map(\.count), after.holders.map(\.count).sorted(by: >), "the most first")
        XCTAssertTrue(after.summary.hasPrefix("PTYs: \(after.inUse) of \(after.limit) in use."), after.summary)
    }

    func testAReportComesOnceEachTimeUseRisesIntoHighUse() {
        func census(_ inUse: Int) -> PTYCensus { PTYCensus(limit: 100, inUse: inUse, holders: []) }
        var crossing = PTYCrossing()
        let reports = [10, 79, 80, 95, 90, 70, 85, 85].map { crossing.rose(census($0)) }
        XCTAssertEqual(reports, [false, false, true, false, false, false, true, false])
    }

    func testTheUserSeesTheTopHolders() {
        let census = PTYCensus(limit: 511, inUse: 509, holders: [
            .init(name: "tmux", pid: 1083, count: 430), .init(name: "node", pid: 4411, count: 40),
            .init(name: "ssh", pid: 7, count: 30), .init(name: "zsh", pid: 8, count: 9),
        ])
        XCTAssertTrue(census.isHigh)
        XCTAssertEqual(census.summary, "PTYs: 509 of 511 in use. Most held by: tmux 1083 (430), node 4411 (40), ssh 7 (30), zsh 8 (9)")
        XCTAssertEqual(census.explanation, "The Mac has 509 of its 511 pseudo-terminals in use, most by tmux (430), node (40), ssh (30).")
    }
}
