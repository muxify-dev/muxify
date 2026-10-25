import XCTest
@testable import MuxifyCore

final class PaletteTagsTests: XCTestCase {
    private func tag(_ name: String) -> Tag { Tag(name: name)! }
    private func defined(_ name: String) -> SearchField { .tag(TagDefinition(tag: tag(name))) }

    func testAHashWordMatchesOnlyTagsAndAnotherWordNeverMatchesATag() throws {
        let fields: [SearchField] = [.title("Fix reward drop"), .typeWord("topic"), defined("backend"), defined("release")]
        let hash = try XCTUnwrap(FieldsMatch.best(FuzzyQuery("#ba"), in: fields))
        XCTAssertEqual(hash.positions, [2: [0, 1, 2]])
        XCTAssertNil(FieldsMatch.best(FuzzyQuery("#fix"), in: fields), "# does not match words in the title")
        XCTAssertNil(FieldsMatch.best(FuzzyQuery("backend"), in: fields), "a word without # does not match a Tag")
        XCTAssertNil(FieldsMatch.best(FuzzyQuery("#ba"), in: [.title("#backend notes")]))
        let tagged = FuzzyRanker.list([PickSectionInput(id: "s", rule: .ranked(showsWhenEmpty: true), candidates: [
            PickCandidate(id: "t", title: "Fix reward drop", fields: [defined("backend")], pick: .available("t")),
            PickCandidate(id: "u", title: "Docs pass", pick: .available("u")),
            PickCandidate(id: "tag", title: "#backend", pick: .available("tag"), titlePlace: .tag),
        ])], query: FuzzyQuery("#ba"))
        XCTAssertEqual(tagged.rows.map(\.id), ["tag", "t"], "on a tie the shorter title goes first")
        XCTAssertEqual(tagged.rows[1].tags.map(\.text), [Highlighted(text: "#backend", marks: [0, 1, 2])], "the matched Tag shows after the title")
        XCTAssertEqual(tagged.rows[1].detail.text, "", "a Tag is not in the detail line")
        XCTAssertEqual(tagged.rows[0].title, Highlighted(text: "#backend", marks: [0, 1, 2]))
        XCTAssertEqual(tagged.rows[0].tags, [], "a Tag row's title is not repeated as a chip")
        let unmatched = FuzzyRanker.list([PickSectionInput(id: "s", rule: .ranked(showsWhenEmpty: true), candidates: [
            PickCandidate(id: "t", title: "Fix reward drop", fields: [defined("backend"), defined("release")], pick: .available("t")),
        ])], query: FuzzyQuery(""))
        XCTAssertEqual(unmatched.rows[0].tags.map(\.text), [.plain("#backend"), .plain("#release")], "a Topic's Tags show with no query")
    }

    private let defined = ConfigTags(["release", "backend", "ops", "qa"].map { TagDefinition(tag: Tag(name: $0)!) })

    func testNewTopicTextKeepsTagWordsOutOfTheTitleAndRefusesAHashWordThatNoTagMatches() {
        let field = TagField(mode: .newTopic, defined: defined, chips: [tag("release")])
        let text = field.text("Fix #Backend reward #1 drop # #re")
        XCTAssertEqual(text.draft, "#re")
        XCTAssertEqual(text.title, "Fix reward drop #", "a lone # is title text")
        XCTAssertEqual(text.tags, [tag("release"), tag("backend")])
        XCTAssertEqual(text.refusedWords, ["#1", "#re"], "↩ does nothing while a # word names no Tag of the Config")
        XCTAssertEqual(text.withoutDraft, "Fix #Backend reward #1 drop # ")
        XCTAssertNil(field.text("Fix #re ").draft, "a space after the word ends the draft")
        XCTAssertNil(field.text("Fix drop").draft)
        XCTAssertEqual(field.text("Fix #").draft, "#", "a lone # shows every Tag")
        XCTAssertEqual(field.text("#backend").title, "")
    }

    func testWithTagsOffHashIsPlainTitleText() {
        let field = TagField(mode: .newTopic, defined: nil)
        let text = field.text("Fix #123 in #backend")
        XCTAssertEqual(text.title, "Fix #123 in #backend")
        XCTAssertEqual(text.tags, [])
        XCTAssertEqual(text.refusedWords, [])
        XCTAssertNil(field.text("Fix #").draft, "no Tag rows while Tags are off")
    }

    func testEditTagsTextTakesWordsWithoutHashAndRefusesTheWordsThatAreNotConfigTags() {
        let field = TagField(mode: .editTags(TopicRecord(id: "t")), defined: defined, chips: [tag("ops")])
        let text = field.text("release #ops ba")
        XCTAssertEqual(text.draft, "#ba")
        XCTAssertEqual(text.tags, [tag("ops"), tag("release")])
        XCTAssertEqual(text.withoutDraft, "release #ops ")
        XCTAssertEqual(field.text("qa a_b #c.d bazel").refusedWords, ["a_b", "#c.d", "bazel"])
        XCTAssertEqual(TagField(mode: .editTags(TopicRecord(id: "t")), defined: defined).text("").tags, [])
    }

    @MainActor
    func testASpaceAfterAWordThatNamesAConfigTagMakesAChipThatBackspaceRemovesWhole() {
        let space = KeyTrigger(modifiers: [], key: .character(" "))
        let palette = CommandPalette()
        palette.begin(.text(.tags(TagField(mode: .newTopic, defined: defined))), text: "Fix #Backend")
        XCTAssertTrue(palette.handleFlow(space))
        XCTAssertEqual(palette.flow?.tagField?.chipField.chips, [tag("backend")])
        XCTAssertEqual(palette.query, "Fix ", "the chip takes the Tag word out of the field")
        for typed in ["Fix #back", "Fix #a.b", "Fix #bazel", "Fix #", "Fix ", "Fix drop"] {
            palette.query = typed
            XCTAssertFalse(palette.handleFlow(space), "\(typed): the space goes into the field")
            XCTAssertEqual(palette.flow?.tagField?.chipField.chips, [tag("backend")], typed)
        }

        palette.begin(.text(.tags(TagField(mode: .editTags(TopicRecord(id: "t")), defined: defined, chips: [tag("ops")]))), text: "QA")
        XCTAssertTrue(palette.handleFlow(space), "Edit Tags takes a word without #")
        XCTAssertEqual(palette.flow?.tagField?.chipField.chips, [tag("ops"), tag("qa")])
        XCTAssertEqual(palette.query, "")
        palette.back()
        XCTAssertEqual(palette.flow?.tagField?.chipField.chips, [tag("ops")], "⌫ in the empty field removes the new chip whole")
    }

    func testATopicRowShowsItsConfigTagsAsChipsInTheirConfigColour() throws {
        let pair = MarkColor.pair(light: .rgb(red: 0x5e, green: 0x8c, blue: 0x6a), dark: .rgb(red: 0x7f, green: 0xa8, blue: 0x8a))
        let shown = [ShownTag(tag: tag("be"), definition: TagDefinition(tag: tag("be"), color: pair)),
                     ShownTag(tag: tag("ops"), definition: TagDefinition(tag: tag("ops"), color: .single(.system(.teal)))),
                     ShownTag(tag: tag("old"), definition: nil)]
        let rows = { (query: String) in
            FuzzyRanker.list([PickSectionInput(id: "s", rule: .ranked(showsWhenEmpty: true), candidates: [
                PickCandidate(id: "topic", title: "Fix drop", fields: SearchField.tags(shown), pick: .available("topic")),
            ])], query: FuzzyQuery(query)).rows
        }
        XCTAssertEqual(rows("#be").map(\.id), ["topic"], "the name finds the Tag")
        XCTAssertEqual(rows("").first?.tags, [RowTag(text: .plain("#be"), color: pair), RowTag(text: .plain("#ops"), color: .single(.system(.teal)))],
                       "each chip shows the name in the Tag's Config colour, and not a Tag the Config no longer defines")
        XCTAssertEqual(rows("#old").map(\.id), [], "a Tag the Config no longer defines is not searched")
    }

    @MainActor
    func testTheTagChipsOfNewTopicAndEditTagsHaveTheirConfigColour() {
        let colored = ConfigTags([TagDefinition(tag: tag("work"), color: .pair(light: .system(.blue), dark: .rgb(red: 1, green: 2, blue: 3))),
                                  TagDefinition(tag: tag("ops"), color: .single(.system(.red)))])
        let palette = CommandPalette()
        palette.begin(.text(.tags(TagField(mode: .newTopic, defined: colored, chips: [tag("ops"), tag("work")]))))
        XCTAssertEqual(palette.fieldChips.map(\.title), ["#ops", "#work"], "a chip shows the Tag's name")
        XCTAssertEqual(palette.fieldChips.map(\.color), [.single(.system(.red)), .pair(light: .system(.blue), dark: .rgb(red: 1, green: 2, blue: 3))])
        palette.begin(.text(.tags(TagField(mode: .editTags(TopicRecord(id: "t")), defined: colored, chips: [tag("work"), tag("gone")]))))
        XCTAssertEqual(palette.fieldChips.map(\.color), [.pair(light: .system(.blue), dark: .rgb(red: 1, green: 2, blue: 3)), nil],
                       "a Tag the Config no longer defines has no colour, so the chip keeps the palette's colour")
    }
}
