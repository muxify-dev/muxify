import AppKit
import XCTest
@testable import MuxifyCore

/// Which Tags a Topic card of the AppKit Topics list shows, and how wide they are, for each placement
/// (`CardTagsLayout` in UI/SidebarTagsView.swift, as `CardTagsView` lays them out in SwiftUI).
@MainActor final class CardTagsLayoutTests: XCTestCase {
    private func tags(_ placement: Config.Sidebar.TagPlacement, _ names: [String]) -> CardTags {
        CardTags(placement: placement, items: names.map {
            let tag = Tag(name: $0)!
            return CardTags.Item(shown: ShownTag(tag: tag, definition: TagDefinition(tag: tag)), text: $0)
        }, identifier: "topic-t")
    }

    private func parts(_ tags: CardTags, width: CGFloat = .greatestFiniteMagnitude) -> [String] {
        CardTagsLayout(tags, width: width, fontSize: InterfaceFontSize(), scale: 2).parts.map {
            switch $0.part {
            case .mark(let shown): "mark " + shown.tag.name
            case .chip(let item): item.text
            case .more(let count): "+\(count)"
            }
        }
    }

    func testTheCornerShowsAMarkForEachTagThreePointsApart() {
        let layout = CardTagsLayout(tags(.corner, ["work", "ops", "qa"]), fontSize: InterfaceFontSize(), scale: 2)
        XCTAssertEqual(layout.parts.map(\.frame.minX), [0, 11, 22])
        XCTAssertEqual(layout.size, NSSize(width: 30, height: 8))
        XCTAssertEqual(CardTagsLayout(tags(.corner, ["work"]), fontSize: InterfaceFontSize(18), scale: 2).size.width, 12,
                       "a Tag Mark grows with the Interface font size")
    }

    func testTheTitleShowsTheFirstChipAndPlusTheRest() {
        XCTAssertEqual(parts(tags(.title, ["work", "ops", "qa"])), ["work", "+2"])
        XCTAssertEqual(parts(tags(.title, ["work"])), ["work"])
    }

    func testTheLineShowsTheWidestRowThatFitsElsePlusNAlone() {
        let line = tags(.line, ["work", "ops", "qa"])
        let all = CardTagsLayout(line, fontSize: InterfaceFontSize(), scale: 2).size.width
        XCTAssertEqual(parts(line), ["work", "ops", "qa"])
        XCTAssertEqual(parts(line, width: all), ["work", "ops", "qa"], "a row exactly as wide as the room fits")
        XCTAssertEqual(parts(line, width: all - 1), ["work", "ops", "+1"])
        XCTAssertEqual(parts(line, width: 0), ["+3"])
    }
}
