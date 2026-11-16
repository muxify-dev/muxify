import XCTest
@testable import MuxifyCore

/// The expected scores are fzf's own, from src/algo/algo_test.go at v0.74.4 (TestFuzzyMatch, forward).
/// fzf lowercases a case-insensitive pattern before matching; here the word is given lowercase, and smart case does the rest.
final class FuzzyMatcherTests: XCTestCase {
    private typealias M = FuzzyMatcher

    private func assertMatch(_ text: String, _ word: String, _ start: Int, _ end: Int, _ score: Int,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard let match = M.match(word, in: text) else {
            XCTFail("no match for \(word) in \(text)", file: file, line: line)
            return
        }
        XCTAssertEqual(match.positions.first, start, "start of \(word) in \(text)", file: file, line: line)
        XCTAssertEqual(match.positions.last.map { $0 + 1 }, end, "end of \(word) in \(text)", file: file, line: line)
        XCTAssertEqual(match.score, score, "score of \(word) in \(text)", file: file, line: line)
        XCTAssertEqual(match.positions.count, word.count, "one position per pattern character", file: file, line: line)
        XCTAssertEqual(match.positions, match.positions.sorted(), file: file, line: line)
    }

    func testScoresAndSpansMatchFzfCaseInsensitive() {
        assertMatch("fooBarbaz1", "obz", 2, 9, M.scoreMatch * 3 + M.bonusCamel123 + M.scoreGapStart + M.scoreGapExtension * 3)
        assertMatch("foo bar baz", "fbb", 0, 9, M.scoreMatch * 3 + M.bonusBoundaryWhite * M.bonusFirstCharMultiplier
                    + M.bonusBoundaryWhite * 2 + 2 * M.scoreGapStart + 4 * M.scoreGapExtension)
        assertMatch("/AutomatorDocument.icns", "rdoc", 9, 13, M.scoreMatch * 4 + M.bonusCamel123 + M.bonusConsecutive * 2)
        assertMatch("/man1/zshcompctl.1", "zshc", 6, 10,
                    M.scoreMatch * 4 + M.bonusBoundaryDelimiter * M.bonusFirstCharMultiplier + M.bonusBoundaryDelimiter * 3)
        assertMatch("/.oh-my-zsh/cache", "zshc", 8, 13, M.scoreMatch * 4 + M.bonusBoundary * M.bonusFirstCharMultiplier
                    + M.bonusBoundary * 2 + M.scoreGapStart + M.bonusBoundaryDelimiter)
        assertMatch(".vimrc", ".vimrc", 0, 6, M.scoreMatch * 6 + M.bonusBoundaryWhite * (M.bonusFirstCharMultiplier + 5))
        assertMatch("/.vimrc", ".vimrc", 1, 7, M.scoreMatch * 6 + M.bonusBoundaryDelimiter * (M.bonusFirstCharMultiplier + 5))
        assertMatch("a.vimrc", ".vimrc", 1, 7, M.scoreMatch * 6 + M.bonusBoundary * (M.bonusFirstCharMultiplier + 5))
        assertMatch("ab0123 456", "12356", 3, 10, M.scoreMatch * 5 + M.bonusConsecutive * 3 + M.scoreGapStart + M.scoreGapExtension)
        assertMatch("abc123 456", "12356", 3, 10, M.scoreMatch * 5 + M.bonusCamel123 * M.bonusFirstCharMultiplier
                    + M.bonusCamel123 * 2 + M.bonusConsecutive + M.scoreGapStart + M.scoreGapExtension)
        assertMatch("foo/bar/baz", "fbb", 0, 9, M.scoreMatch * 3 + M.bonusBoundaryWhite * M.bonusFirstCharMultiplier
                    + M.bonusBoundaryDelimiter * 2 + 2 * M.scoreGapStart + 4 * M.scoreGapExtension)
        assertMatch("fooBarBaz", "fbb", 0, 7, M.scoreMatch * 3 + M.bonusBoundaryWhite * M.bonusFirstCharMultiplier
                    + M.bonusCamel123 * 2 + 2 * M.scoreGapStart + 2 * M.scoreGapExtension)
        assertMatch("foo barbaz", "fbb", 0, 8, M.scoreMatch * 3 + M.bonusBoundaryWhite * M.bonusFirstCharMultiplier
                    + M.bonusBoundaryWhite + M.scoreGapStart * 2 + M.scoreGapExtension * 3)
        assertMatch("fooBar Baz", "foob", 0, 4, M.scoreMatch * 4 + M.bonusBoundaryWhite * M.bonusFirstCharMultiplier + M.bonusBoundaryWhite * 3)
        assertMatch("xFoo-Bar Baz", "foo-b", 1, 6, M.scoreMatch * 5 + M.bonusCamel123 * M.bonusFirstCharMultiplier
                    + M.bonusCamel123 * 2 + M.bonusNonWord + M.bonusBoundary)
    }

    func testScoresMatchFzfCaseSensitiveWhenTheWordHasAnUppercaseLetter() {
        assertMatch("fooBarbaz", "oBz", 2, 9, M.scoreMatch * 3 + M.bonusCamel123 + M.scoreGapStart + M.scoreGapExtension * 3)
        assertMatch("Foo/Bar/Baz", "FBB", 0, 9, M.scoreMatch * 3 + M.bonusBoundaryWhite * M.bonusFirstCharMultiplier
                    + M.bonusBoundaryDelimiter * 2 + M.scoreGapStart * 2 + M.scoreGapExtension * 4)
        assertMatch("FooBarBaz", "FBB", 0, 7, M.scoreMatch * 3 + M.bonusBoundaryWhite * M.bonusFirstCharMultiplier
                    + M.bonusCamel123 * 2 + M.scoreGapStart * 2 + M.scoreGapExtension * 2)
        assertMatch("FooBar Baz", "FooB", 0, 4, M.scoreMatch * 4 + M.bonusBoundaryWhite * M.bonusFirstCharMultiplier
                    + M.bonusBoundaryWhite * 2 + max(M.bonusCamel123, M.bonusBoundaryWhite))
        assertMatch("foo-bar", "o-ba", 2, 6, M.scoreMatch * 4 + M.bonusBoundary * 3)
        XCTAssertNil(M.match("oBZ", in: "fooBarbaz"), "an uppercase letter makes the word case-sensitive")
        XCTAssertNil(M.match("fooBarbazz", in: "fooBarbaz"))
        XCTAssertNotNil(M.match("fbb", in: "Foo Bar Baz"), "a lowercase word ignores case")
    }

    func testPositionsAreCharacterOffsetsOfTheBestAlignment() {
        XCTAssertEqual(M.match("fbb", in: "foo bar baz")?.positions, [0, 4, 8])
        XCTAssertEqual(M.match("rdoc", in: "/AutomatorDocument.icns")?.positions, [9, 10, 11, 12])
        XCTAssertEqual(M.match("ab", in: "xa ab")?.positions, [3, 4], "the whole-word match beats the earlier scattered one")
        XCTAssertEqual(M.match("é", in: "café")?.positions, [3])
        XCTAssertEqual(M.match("", in: "anything"), FuzzyMatch(score: 0, positions: []))
        XCTAssertNil(M.match("abc", in: "ab"))
    }

    func testQuerySplitsOnWhitespaceAndDropsEmptyWords() {
        XCTAssertEqual(FuzzyQuery("  sett   gs \n").words, ["sett", "gs"])
        XCTAssertTrue(FuzzyQuery("   ").isEmpty)
        XCTAssertTrue(FuzzyQuery("").isEmpty)
    }
}
