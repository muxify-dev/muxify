import XCTest
@testable import MuxifyCLI
import MuxifyCore

final class EnvironmentSnapshotTextTests: XCTestCase {
    func testTheTextFormHasASectionForEachPartWithLinesAndNamesTheSessions() throws {
        let json = #"""
        {"tags":[],
         "sessions":[{"id":"$1","name":"game/fix","activity":10,"mark":"blocked","topic":"a","windows":[]},
                     {"id":"$2","name":"notes","activity":20,"mark":null,"topic":null,"windows":[]},
                     {"id":"$3","name":"tools","activity":30,"mark":"working","topic":null,"windows":[]}],
         "pinned":[{"kind":"topic","mark":null,"sessions":[],
                    "topic":{"id":"p","label":"Pinned","note":null,"tags":[],"state":"dormant"}}],
         "unpinned":{"kind":"in_play","limit":2,
                     "places":[{"kind":"topic","mark":"blocked","sessions":["$1"],
                                "topic":{"id":"a","label":"Fix\tit","note":"why","tags":["backend","release"],"state":"live"}},
                               {"kind":"open_place","id":"gap","sessions":[]}],
                     "guests":[{"kind":"session","mark":"working","sessions":["$3"]}],
                     "bench":[{"kind":"topic","mark":"unread","sessions":[],
                               "topic":{"id":"b","label":"Untitled 1","note":null,"tags":[],"state":"empty"}}]},
         "no_topic":["$2"]}
        """#
        let snapshot = try JSONDecoder().decode(EnvironmentSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.text, """
            Sessions
            $1\tgame/fix\tblocked\tFix it
            $2\tnotes\t\t
            $3\ttools\tworking\t
            Pinned
            topic\tp\tPinned\tdormant\t\t\t
            In Play (2)
            1\ttopic\ta\tFix it\tlive\tblocked\t#backend #release\tgame/fix
            2\topen place\tgap
            Guests
            session\t$3\ttools\tworking
            Bench
            topic\tb\tUntitled 1\tempty\tunread\t\t
            No Topic
            $2\tnotes

            """)
    }

    func testTheTextFormHasNoEmptySection() throws {
        let json = #"""
        {"tags":[],"sessions":[],"pinned":[],"no_topic":[],
         "unpinned":{"kind":"in_play","limit":5,"guests":[],"bench":[],
                     "places":[{"kind":"topic","mark":null,"sessions":[],
                                "topic":{"id":"a","label":"Fix","note":null,"tags":[],"state":"empty"}}]}}
        """#
        let snapshot = try JSONDecoder().decode(EnvironmentSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.text, "In Play (5)\n1\ttopic\ta\tFix\tempty\t\t\t\n")
    }
}
