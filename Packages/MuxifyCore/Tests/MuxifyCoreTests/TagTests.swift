import XCTest
@testable import MuxifyCore

final class TagTests: XCTestCase {
    private var root: URL!
    private var paths: MuxifyPaths!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("muxify-tags-" + UUID().uuidString)
        paths = MuxifyPaths(environment: ["XDG_STATE_HOME": root.path], home: "/nonexistent")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func tags(_ names: String...) -> Set<Tag> { Set(names.map { Tag(name: $0)! }) }

    func testATagIsLowerCaseLettersDigitsAndDashAndTypedTextIsLowerCased() {
        XCTAssertEqual(Tag(typed: "#Backend")?.name, "backend")
        XCTAssertEqual(Tag(typed: "release-2")?.name, "release-2", "the # is optional")
        XCTAssertEqual(Tag(typed: "#Backend")?.description, "#backend")
        for typed in ["", "#", "##a", "back end", "back_end", "café", "a.b", "#a#b"] {
            XCTAssertNil(Tag(typed: typed), typed)
        }
        XCTAssertNil(Tag(name: "Backend"), "a record stores only the lower case form")
        XCTAssertNil(Tag(name: "#backend"), "a record stores the name without #")
    }

    private func written(_ id: String) throws -> JSONValue? {
        try paths.storedJSON(id, "tags")
    }

    func testTheRecordKeepsTagsAsASortedArrayAndReadsTypedForms() throws {
        let data = Data(##"{"id":"t","tags":["release","Backend","#ops","release"]}"##.utf8)
        let record = try JSONDecoder().decode(TopicRecord.self, from: data)
        XCTAssertEqual(record.tags, tags("backend", "ops", "release"))
        let store = TopicStore(paths: paths)
        try store.write { try $0.create(record) }
        try store.write { try $0.update("t") { $0.title = "Renamed" } }
        XCTAssertEqual(try written("t"), .array([.string("backend"), .string("ops"), .string("release")]))
        XCTAssertEqual(try store.read().records.first?.tags, tags("backend", "ops", "release"))

        try store.write { try $0.changeTags(of: "t", .set([])) }
        XCTAssertEqual(try written("t"), .array([]), "a Topic with no Tags has an empty array")
        XCTAssertEqual(try store.read().records.first?.title, "Renamed")
    }

    func testTheImportKeepsTheTagsOfAnEntryAndLeavesOutWhatIsNotATag() throws {
        try paths.seedTopicRecordsFile(entries: [#"{"id":"t","tags":["release","",7,"a b",{"x":1}]}"#, #"{"id":"u","tags":"backend"}"#])
        let store = TopicStore(paths: paths)
        XCTAssertEqual(try store.read().records.map(\.tags), [tags("release"), []])
        XCTAssertEqual(try written("t"), .array([.string("release")]))
        XCTAssertEqual(try written("u"), .array([]), "a tags value that is not an array is no Tags")
        try store.write { try $0.changeTags(of: "u", .add([Tag(name: "qa")!])) }
        XCTAssertEqual(try written("u"), .array([.string("qa")]))
    }

    func testAChangeAddsRemovesOrSetsAndOnlyAnOpenTopicChanges() throws {
        let store = TopicStore(paths: paths)
        var settled = TopicRecord(id: "done")
        settled.settledAt = "2026-01-01T00:00:00Z"
        try store.write {
            try $0.create(TopicRecord(id: "t"))
            try $0.create(settled)
        }
        func current() throws -> Set<Tag> { try XCTUnwrap(store.read().records.first { $0.id == "t" }).tags }
        try store.write { try $0.changeTags(of: "t", .add([Tag(name: "b")!, Tag(name: "a")!])) }
        XCTAssertEqual(try current(), tags("a", "b"))
        try store.write { try $0.changeTags(of: "t", .add([Tag(name: "a")!, Tag(name: "c")!])) }
        XCTAssertEqual(try current(), tags("a", "b", "c"))
        try store.write { try $0.changeTags(of: "t", .remove([Tag(name: "b")!, Tag(name: "z")!])) }
        XCTAssertEqual(try current(), tags("a", "c"))
        try store.write { try $0.changeTags(of: "t", .set([Tag(name: "x")!])) }
        XCTAssertEqual(try current(), tags("x"))
        XCTAssertThrowsError(try store.write { try $0.changeTags(of: "done", .add([Tag(name: "x")!])) })
        XCTAssertThrowsError(try store.write { try $0.changeTags(of: "missing", .add([Tag(name: "x")!])) })
        XCTAssertEqual(try store.read().records.first { $0.id == "done" }?.tags, [])
    }

    private func config(_ text: String) throws -> Config {
        try Config.load(path: "/cfg/config.yaml") { _ in text }.get()
    }

    func testTopicsTagsDefinesTagsInConfigOrderWithAColor() throws {
        let config = try config("""
        topics:
          tags:
            work:
              color: Blue
            personal:
              color: '#33aa55'
            home:
              color: {light: '#5E8C6A', dark: '#7FA88A'}
            gs: {}
            ops:
        """)
        XCTAssertEqual(config.problems, [])
        let defined = try XCTUnwrap(config.topics.tags)
        XCTAssertEqual(defined.definitions.map(\.tag.name), ["work", "personal", "home", "gs", "ops"], "Config order, not A to Z")
        XCTAssertEqual(defined.definitions[0].color, .single(.system(.blue)))
        XCTAssertEqual(defined.definitions[1].color, .single(.rgb(red: 0x33, green: 0xaa, blue: 0x55)))
        XCTAssertEqual(defined.definitions[2].color, .pair(light: .rgb(red: 0x5e, green: 0x8c, blue: 0x6a),
                                                           dark: .rgb(red: 0x7f, green: 0xa8, blue: 0x8a)))
        XCTAssertEqual(defined.definitions[3].color, TagDefinition(tag: Tag(name: "gs")!).color,
                       "a Tag with no colour gets the same colour from its name each time")
        let derived = Set(["a", "b", "c", "d", "e", "f", "g", "h"].map { TagDefinition(tag: Tag(name: $0)!).color })
        XCTAssertGreaterThan(derived.count, 2, "colours made from names differ between Tags")
    }

    func testNoTopicsTagsOrAnEmptyOneTurnsTagsOff() throws {
        XCTAssertNil(try config("").topics.tags)
        XCTAssertNil(try config("topics:\n  tags: {}").topics.tags)
        XCTAssertNil(try config("topics:\n  tags:").topics.tags)
        XCTAssertEqual(try config("topics:\n  tags:").problems, [])
    }

    func testABadTagKeyOrValueIsAConfigProblemWithItsLineAndTheOtherTagsApply() throws {
        let config = try config("""
        topics:
          tags:
            Backend: {}
            back_end: {}
            ops:
              color: accent
              icon: star
            qa: green
            docs:
              color: '#33aa55'
              display_name: Docs
            release: {}
        """)
        let expected = "expected one of blue, orange, red, green, yellow, purple, pink, teal, gray, or a quoted '#RRGGBB', "
            + "or a mapping with light and dark"
        XCTAssertEqual(config.problems.map { "\($0.line): \($0.message)" }, [
            "3: topics.tags: \"Backend\" is not a Tag: use lower case letters, digits and -, e.g. backend",
            "4: topics.tags: \"back_end\" is not a Tag: use lower case letters, digits and -, e.g. backend",
            "6: topics.tags.ops.color: " + expected,
            "7: unknown key \"topics.tags.ops.icon\"",
            "8: topics.tags.qa: expected a mapping",
            "11: unknown key \"topics.tags.docs.display_name\"",
        ])
        XCTAssertEqual(config.topics.tags?.definitions.map(\.tag.name), ["ops", "qa", "docs", "release"],
                       "a bad key leaves its Tag out; a bad value leaves only that value out")
        XCTAssertEqual(config.topics.tags?.definitions[2].color, .single(.rgb(red: 0x33, green: 0xaa, blue: 0x55)),
                       "a Tag with an old display_name still loads with its colour")
    }

    func testShownTagsFollowConfigOrderThenTheTagsTheConfigNoLongerDefines() throws {
        let defined = try XCTUnwrap(ConfigTags([TagDefinition(tag: Tag(name: "work")!),
                                                TagDefinition(tag: Tag(name: "personal")!)]))
        let shown = defined.shown(tags("zed", "personal", "work", "old"))
        XCTAssertEqual(shown.map(\.tag.name), ["work", "personal", "old", "zed"])
        XCTAssertEqual(shown.map { $0.definition == nil }, [false, false, true, true])
        XCTAssertEqual(defined.tag(typed: "#WORK")?.name, "work", "the name finds the Tag in any case")
        XCTAssertEqual(defined.tag(typed: "Personal")?.name, "personal")
        XCTAssertNil(defined.tag(typed: "#old"), "a Tag the Config does not define is not found")
        XCTAssertEqual(defined.undefinedTags(added: .set([Tag(name: "work")!, Tag(name: "old")!, Tag(name: "new")!]),
                                             to: tags("old")).map(\.name), ["new"],
                       "a Tag the Config no longer defines can stay, but no undefined Tag can be added")
        XCTAssertEqual(defined.undefinedTags(added: .remove([Tag(name: "old")!]), to: tags("old")), [])
    }
}
