import XCTest
@testable import MuxifyCore

final class FocusRuleTests: XCTestCase {
    private func gap(view: Bool = false, palette: Bool = false, sheet: Bool = false, emptyPage: Bool = false,
                     gitView: Bool = false, shown: PanelLayout.Shown = .both, last: FocusHolder? = .terminal) -> FocusGap {
        FocusGap(firstResponderIsView: view, paletteIsOpen: palette, sheetIsOpen: sheet, showsEmptyPage: emptyPage,
                 gitViewIsOpen: gitView, layout: PanelLayout(shown: shown), lastFocus: last)
    }

    func testFocusGoesBackToTheHolderThatHadItLast() {
        XCTAssertEqual(gap(last: .terminal).focusToRestore, .terminal)
        XCTAssertEqual(gap(last: .browser).focusToRestore, .browser)
        XCTAssertEqual(gap(last: nil).focusToRestore, .terminal, "with no record, the Terminal takes Focus")
    }

    func testFocusGoesToTheSideOnScreenWhenTheLastHolderIsHidden() {
        XCTAssertEqual(gap(shown: .terminal, last: .browser).focusToRestore, .terminal)
        XCTAssertEqual(gap(shown: .browser, last: .terminal).focusToRestore, .browser)
        XCTAssertEqual(gap(shown: .browser, last: nil).focusToRestore, .browser)
    }

    func testAnOpenGitViewTakesFocusOverItsSides() {
        XCTAssertEqual(gap(gitView: true, last: .gitView).focusToRestore, .gitView)
        XCTAssertEqual(gap(gitView: true, last: .terminal).focusToRestore, .gitView)
        XCTAssertEqual(gap(gitView: false, last: .gitView).focusToRestore, .terminal, "a closed Git View gives its sides Focus")
    }

    func testNothingMovesWhileAViewHasFocus() {
        XCTAssertNil(gap(view: true).focusToRestore)
        XCTAssertNil(gap(view: true, gitView: true, last: .browser).focusToRestore)
    }

    func testNothingMovesWhileAPaletteOrASheetTakesInput() {
        XCTAssertNil(gap(palette: true).focusToRestore)
        XCTAssertNil(gap(sheet: true).focusToRestore)
    }

    func testTheEmptyTopicPageKeepsFocusOnNoView() {
        XCTAssertNil(gap(emptyPage: true).focusToRestore)
        XCTAssertNil(gap(emptyPage: true, shown: .browser, last: .browser).focusToRestore)
    }
}
