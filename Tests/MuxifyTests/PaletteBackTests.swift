import XCTest
@testable import MuxifyCore

final class PaletteBackTests: XCTestCase {
    @MainActor func testBackspaceInTheEmptyFieldOfTheFirstStepKeepsThePaletteOpen() {
        let palette = CommandPalette()
        for config in [CommandPaletteConfig.goTo, .commands] {
            palette.toggle(config)
            palette.back()
            XCTAssertEqual(palette.current?.name, config.name, "⌫ closed \(config.name), and only ⎋ closes")
            palette.close(restoringFocus: false)
        }
        palette.begin(.text(.renameTopic(TopicRecord(id: "t"))))
        palette.back()
        XCTAssertTrue(palette.isOpen, "⌫ closed an Action that opened at its first step")
        palette.close(restoringFocus: false)
    }

    @MainActor func testBackspaceInTheEmptyFieldOfAnActionGoesBackToTheSearchThatStartedIt() {
        let palette = CommandPalette()
        palette.toggle(.commands)
        palette.query = "New Topic"
        palette.begin(.text(.renameTopic(TopicRecord(id: "t"))), keepingHistory: true)
        palette.back()
        XCTAssertEqual(palette.current?.name, CommandPaletteConfig.commands.name)
        XCTAssertEqual(palette.query, "New Topic")
        palette.close(restoringFocus: false)
    }
}
