import SwiftUI
import XCTest
@testable import MuxifyCore

final class InterfaceFontSizeTests: XCTestCase {
    /// Font sizes, symbol sizes and fixed lengths that surfaces are designed at.
    private let designSizes: [CGFloat] = [7, 9, 10, 10.5, 11, 11.5, 12, 13, 14, 20, 24, 30, 52, 180, 260, 420]

    func testAt12EveryDesignSizeIsUnchanged() {
        let size = InterfaceFontSize()
        XCTAssertEqual(size.points, 12)
        XCTAssertEqual(size.factor, 1)
        for design in designSizes {
            XCTAssertEqual(size(design), design)
            XCTAssertEqual(size.font(design, weight: .medium), Font.system(size: design, weight: .medium))
            XCTAssertEqual(size.font(design), Font.system(size: design))
            XCTAssertEqual(size.font(design, design: .monospaced), Font.system(size: design, design: .monospaced))
        }
        XCTAssertEqual(size(180...420), 180...420)
    }

    func testAt18EveryDesignSizeIsOneAndAHalfTimesAsLarge() {
        let size = InterfaceFontSize(18)
        XCTAssertEqual(size.factor, 1.5)
        for design in designSizes {
            XCTAssertEqual(size(design), design * 1.5, accuracy: 0.0001)
            XCTAssertEqual(size.font(design), Font.system(size: design * 1.5))
        }
        XCTAssertEqual(size(180...420), 270...630)
    }

    func testFractionalSizesKeepTheRatioTo12() {
        let size = InterfaceFontSize(13.5)
        XCTAssertEqual(size.factor, 1.125, accuracy: 0.0001)
        XCTAssertEqual(size(13), 14.625, accuracy: 0.0001)
    }

    func testTheSmallestAndLargestSizesGivePositiveFiniteSizes() {
        for points in [InterfaceFontSize.range.lowerBound, InterfaceFontSize.range.upperBound] {
            let size = InterfaceFontSize(points)
            for design in designSizes {
                XCTAssertGreaterThan(size(design), 0, "\(points)")
                XCTAssertTrue(size(design).isFinite, "\(points)")
            }
        }
        XCTAssertEqual(InterfaceFontSize(9)(12), 9)
        XCTAssertEqual(InterfaceFontSize(24)(12), 24)
    }

    func testAnUndraggedSidebarShowsTheDefaultWidthTimesTheFactor() {
        XCTAssertEqual(SidebarWidth.shown(dragged: nil, size: InterfaceFontSize()), 260)
        XCTAssertEqual(SidebarWidth.shown(dragged: nil, size: InterfaceFontSize(18)), 390)
        XCTAssertEqual(SidebarWidth.shown(dragged: nil, size: InterfaceFontSize(9)), 195)
        XCTAssertEqual(SidebarWidth.shown(dragged: nil, size: InterfaceFontSize(24)), 520)
    }

    func testTheResizeBoundsScaleByTheFactor() {
        XCTAssertEqual(SidebarWidth.bounds(InterfaceFontSize()), 180...420)
        XCTAssertEqual(SidebarWidth.bounds(InterfaceFontSize(18)), 270...630)
        XCTAssertEqual(SidebarWidth.bounds(InterfaceFontSize(9)), 135...315)
    }

    func testADraggedWidthStaysAsDraggedInsideTheScaledBounds() {
        for (points, dragged) in [(12.0, 300.0), (18, 300), (18, 600), (9, 200), (24, 400)] {
            XCTAssertEqual(SidebarWidth.shown(dragged: dragged, size: InterfaceFontSize(points)), dragged, "\(points)")
        }
    }

    func testTheHeaderIsUIHeaderHeightOrItsDefaultTimesTheFactor() throws {
        func height(_ text: String) throws -> CGFloat {
            TitlebarMetrics.headerHeight(try Config.load(path: "/cfg/muxify/config.yaml") { _ in text }.get())
        }
        XCTAssertEqual(try height(""), 30, "the default at 12 is the header as it was designed")
        XCTAssertEqual(try height("ui:\n  font_size: 12"), 30)
        XCTAssertEqual(try height("ui:\n  font_size: 18"), 45, "the default 30 at 18")
        XCTAssertEqual(try height("ui:\n  header_height: 26"), 26, "ui.header_height is a length at 12")
        XCTAssertEqual(try height("ui:\n  header_height: 26\n  font_size: 18"), 39)
        XCTAssertEqual(try height("ui:\n  header_height: 24\n  font_size: 9"), 18, "the least height also scales")
        // The rule for ui.header_height is unchanged: a value under 24 is a problem, and the default 30 scales.
        let invalid = try Config.load(path: "/cfg/muxify/config.yaml") { _ in "ui:\n  header_height: 20\n  font_size: 18" }.get()
        XCTAssertEqual(invalid.problems.map(\.message), ["ui.header_height: expected a finite number of at least 24 points"])
        XCTAssertEqual(TitlebarMetrics.headerHeight(invalid), 45)
    }

    func testADraggedWidthOutsideTheScaledBoundsIsClampedToThem() {
        XCTAssertEqual(SidebarWidth.shown(dragged: 200, size: InterfaceFontSize(18)), 270, "below 180 × 1.5")
        XCTAssertEqual(SidebarWidth.shown(dragged: 400, size: InterfaceFontSize(9)), 315, "above 420 × 0.75")
        XCTAssertEqual(SidebarWidth.shown(dragged: 100, size: InterfaceFontSize()), 180)
        XCTAssertEqual(SidebarWidth.shown(dragged: 900, size: InterfaceFontSize()), 420)
    }

    func testASystemControlIsRegularAt12AndTakesTheSizeNearestItsGrownHeight() {
        XCTAssertEqual(InterfaceFontSize().systemControlSize, .regular)
        XCTAssertEqual(InterfaceFontSize(13).systemControlSize, .regular)
        XCTAssertEqual(InterfaceFontSize(15).systemControlSize, .large)
        XCTAssertEqual(InterfaceFontSize(18).systemControlSize, .extraLarge)
        XCTAssertEqual(InterfaceFontSize(24).systemControlSize, .extraLarge)
        XCTAssertEqual(InterfaceFontSize(9).systemControlSize, .small)
    }

    func testASmallSystemControlIsSmallAt12AndTakesTheSizeNearestItsGrownHeight() {
        XCTAssertEqual(InterfaceFontSize().systemControlSize(at: .small), .small)
        XCTAssertEqual(InterfaceFontSize(13).systemControlSize(at: .small), .small)
        XCTAssertEqual(InterfaceFontSize(18).systemControlSize(at: .small), .large)
        XCTAssertEqual(InterfaceFontSize(24).systemControlSize(at: .small), .extraLarge)
        XCTAssertEqual(InterfaceFontSize().systemControlSize(at: .regular), .regular)
    }

    func testATextStyleIsItselfAt12AndItsPointSizeTimesTheFactorAt18() {
        let styles: [(Font.TextStyle, NSFont.TextStyle)] = [
            (.largeTitle, .largeTitle), (.title, .title1), (.title2, .title2), (.title3, .title3), (.headline, .headline),
            (.subheadline, .subheadline), (.body, .body), (.callout, .callout), (.footnote, .footnote),
            (.caption, .caption1), (.caption2, .caption2),
        ]
        for (style, appKit) in styles {
            XCTAssertEqual(style.designFont.size, NSFont.preferredFont(forTextStyle: appKit).pointSize, "\(style)")
            XCTAssertEqual(InterfaceFontSize().font(style), .system(style), "\(style)")
        }
        XCTAssertEqual(InterfaceFontSize().font(.callout, weight: .semibold), .system(.callout, weight: .semibold))
        XCTAssertEqual(InterfaceFontSize(18).font(.caption), .system(size: 15, weight: .regular))
        XCTAssertEqual(InterfaceFontSize(18).font(.title2, weight: .semibold), .system(size: 25.5, weight: .semibold))
        XCTAssertEqual(InterfaceFontSize(18).font(.headline), .system(size: 19.5, weight: .bold))
        XCTAssertEqual(InterfaceFontSize(18).font(.caption, design: .monospaced), .system(size: 15, weight: .regular, design: .monospaced))
    }

    func testTheGitListsRowsHeadersAndLanesAreTheirDesignSizesAt12AndGrowByTheFactor() {
        XCTAssertEqual(GitListMetrics.rowHeight(InterfaceFontSize()), 24)
        XCTAssertEqual(GitListMetrics.rowHeight(InterfaceFontSize(18)), 36)
        // The header, the rows, and the list's 12 points of padding, which do not grow.
        XCTAssertEqual(GitListMetrics.listHeight(rows: 5, size: InterfaceFontSize()), 36 + 5 * 24 + 12)
        XCTAssertEqual(GitListMetrics.listHeight(rows: 5, size: InterfaceFontSize(18)), 54 + 5 * 36 + 12)
        XCTAssertEqual(GitListMetrics.listHeight(rows: 0, size: InterfaceFontSize()), 36 + 24 + 12, "an empty list has room for one row")
        XCTAssertEqual(InterfaceFontSize(18)(GitListMetrics.designLane), 16.5)
    }

    func testTheListPaneAt12IsItsShareOfTheGitViewBetween240And380() {
        let size = InterfaceFontSize()
        for (gitView, pane) in [(400.0, 240.0), (600, 240), (800, 240), (1000, 300), (1266, 379.8), (2000, 380)] {
            XCTAssertEqual(GitListMetrics.paneWidth(in: gitView, size: size), pane, accuracy: 0.0001, "\(gitView)")
        }
    }

    func testTheListPanesBoundsGrowByTheFactorButNeverPastHalfTheGitView() {
        let size = InterfaceFontSize(18)
        XCTAssertEqual(GitListMetrics.paneWidth(in: 760, size: size), 360, "the least width, 240 at 12")
        XCTAssertEqual(GitListMetrics.paneWidth(in: 1600, size: size), 480, "its share between 360 and 570")
        XCTAssertEqual(GitListMetrics.paneWidth(in: 3000, size: size), 570, "the most width, 380 at 12")
        XCTAssertEqual(GitListMetrics.paneWidth(in: 600, size: size), 300, "half the Git View, so the diff keeps its room")
        XCTAssertEqual(GitListMetrics.paneWidth(in: 400, size: size), 240, "never less than at 12")
        XCTAssertEqual(GitListMetrics.paneWidth(in: 900, size: InterfaceFontSize(24)), 450)
    }

    func testAGitViewPopupIsItsDesignWidthAt12AsBeforeAndNeverWiderThanTheGitViewLessItsMargins() {
        let size = InterfaceFontSize()
        for design in [GitPopupMetrics.designCommitBoxWidth, GitPopupMetrics.designMenuWidth, GitPopupMetrics.designPromptWidth] {
            for gitView in [400.0, 700, 1000, 2000] as [CGFloat] {
                XCTAssertEqual(GitPopupMetrics.width(design, in: gitView, size: size), min(design, gitView - 48), "\(design) in \(gitView)")
            }
        }
    }

    func testAGitViewPopupGrowsByTheFactorWhileTheGitViewHasRoomForIt() {
        let size = InterfaceFontSize(18)
        XCTAssertEqual(GitPopupMetrics.width(GitPopupMetrics.designCommitBoxWidth, in: 1000, size: size), 930)
        XCTAssertEqual(GitPopupMetrics.width(GitPopupMetrics.designMenuWidth, in: 1000, size: size), 690)
        XCTAssertEqual(GitPopupMetrics.width(GitPopupMetrics.designPromptWidth, in: 1000, size: size), 780)
        XCTAssertEqual(GitPopupMetrics.width(GitPopupMetrics.designCommitBoxWidth, in: 760, size: size), 712,
                       "the Git View less its margins, so the commit box stays in the App Window")
        XCTAssertEqual(GitPopupMetrics.width(GitPopupMetrics.designMenuWidth, in: 600, size: InterfaceFontSize(24)), 552)
    }

    func testTheCommitBoxsFileListShowsUpToFourAndAHalfRowsOfTheGrownHeight() {
        XCTAssertEqual(GitPopupMetrics.fileRowHeight(InterfaceFontSize()), 24)
        XCTAssertEqual(GitPopupMetrics.fileRowHeight(InterfaceFontSize(18)), 36)
        XCTAssertEqual(GitPopupMetrics.fileListHeight(files: 2, size: InterfaceFontSize()), 48)
        XCTAssertEqual(GitPopupMetrics.fileListHeight(files: 2, size: InterfaceFontSize(18)), 72)
        XCTAssertEqual(GitPopupMetrics.fileListHeight(files: 9, size: InterfaceFontSize()), 108, "4.5 rows, and it scrolls")
        XCTAssertEqual(GitPopupMetrics.fileListHeight(files: 9, size: InterfaceFontSize(18)), 162)
        XCTAssertEqual(GitPopupMetrics.fileListHeight(files: 0, size: InterfaceFontSize(18)), 0)
    }

    func testThePalettesListIsItsRowsAndHeadersUpToSixAndAHalfRowsOfTheGrownHeight() {
        XCTAssertEqual(PaletteMetrics.rowHeight(InterfaceFontSize()), 52)
        XCTAssertEqual(PaletteMetrics.headerHeight(InterfaceFontSize()), 24)
        XCTAssertEqual(PaletteMetrics.rowHeight(InterfaceFontSize(18)), 78)
        XCTAssertEqual(PaletteMetrics.headerHeight(InterfaceFontSize(18)), 36)
        XCTAssertEqual(PaletteMetrics.listHeight(rows: 3, headers: 2, size: InterfaceFontSize()), 3 * 52 + 2 * 24)
        XCTAssertEqual(PaletteMetrics.listHeight(rows: 3, headers: 2, size: InterfaceFontSize(18)), 3 * 78 + 2 * 36)
        XCTAssertEqual(PaletteMetrics.listHeight(rows: 20, headers: 3, size: InterfaceFontSize()), 338, "6.5 rows, and it scrolls")
        XCTAssertEqual(PaletteMetrics.listHeight(rows: 20, headers: 3, size: InterfaceFontSize(18)), 507)
    }

    func testThePaletteIs700PointsAt12AndGrowsByTheFactorButNeverPastTheAppWindowLessItsMargins() {
        for window in [820.0, 1000, 2000] as [CGFloat] {
            XCTAssertEqual(PaletteMetrics.width(in: CGSize(width: window, height: 800), size: InterfaceFontSize()), 700, "\(window)")
        }
        XCTAssertEqual(PaletteMetrics.width(in: CGSize(width: 600, height: 800), size: InterfaceFontSize()), 552)
        XCTAssertEqual(PaletteMetrics.width(in: CGSize(width: 2000, height: 800), size: InterfaceFontSize(18)), 1050)
        XCTAssertEqual(PaletteMetrics.width(in: CGSize(width: 1000, height: 800), size: InterfaceFontSize(18)), 952,
                       "the App Window less its margins, so the palette stays in it")
    }
}
