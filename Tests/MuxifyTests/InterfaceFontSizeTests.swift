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

    func testADraggedWidthOutsideTheScaledBoundsIsClampedToThem() {
        XCTAssertEqual(SidebarWidth.shown(dragged: 200, size: InterfaceFontSize(18)), 270, "below 180 × 1.5")
        XCTAssertEqual(SidebarWidth.shown(dragged: 400, size: InterfaceFontSize(9)), 315, "above 420 × 0.75")
        XCTAssertEqual(SidebarWidth.shown(dragged: 100, size: InterfaceFontSize()), 180)
        XCTAssertEqual(SidebarWidth.shown(dragged: 900, size: InterfaceFontSize()), 420)
    }
}
