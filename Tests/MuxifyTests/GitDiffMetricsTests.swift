import AppKit
import XCTest

/// The diff's code gutters follow the code font, the Terminal's `font-size` less one point (ADR 0068).
final class GitDiffMetricsTests: XCTestCase {
    private typealias Metrics = GitView.TextMetrics

    private func metrics(_ fontSize: CGFloat, _ layout: GitView.Layout = .unified, width: CGFloat = 1000,
                         widestNumber: Int = 120) -> Metrics {
        Metrics(fontSize: fontSize, layout: layout, width: width, widestNumber: widestNumber)
    }

    /// How wide `text` is typeset in the line numbers' font at the code size `fontSize`.
    private func typesetWidth(_ text: String, fontSize: CGFloat) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: Metrics.numberSize(fontSize), weight: .regular)
        return NSAttributedString(string: text, attributes: [.font: font]).size().width
    }

    func testAtTheTerminalsDefaultSizeTheGuttersAreTheirFormerFixedWidths() {
        let unified = metrics(12)
        XCTAssertEqual(unified.numberWidth, 46)
        XCTAssertEqual(unified.numberPadding, 9)
        XCTAssertEqual(unified.markerWidth, 18)
        XCTAssertEqual(unified.gutterWidth, 92)
        XCTAssertEqual(unified.codeX, 110)
        XCTAssertEqual(unified.lineHeight, 19)
        XCTAssertEqual(unified.hunkHeight, 30)
        let split = metrics(12, .split)
        XCTAssertEqual(split.numberWidth, 46)
        XCTAssertEqual(split.gutterWidth, 46)
        XCTAssertEqual(split.codeX, 64)
        // A 4-digit number is the widest a column holds at its least width.
        XCTAssertEqual(metrics(12, widestNumber: 9999), unified)
        XCTAssertEqual(metrics(12, widestNumber: 0), unified)
    }

    func testTheGuttersGrowWithTheCodeFont() {
        for layout in [GitView.Layout.unified, .split] {
            let small = metrics(12, layout)
            let large = metrics(17, layout)
            XCTAssertGreaterThan(large.charWidth, small.charWidth)
            XCTAssertGreaterThan(large.lineHeight, small.lineHeight)
            XCTAssertGreaterThan(large.numberWidth, small.numberWidth)
            XCTAssertGreaterThan(large.numberPadding, small.numberPadding)
            XCTAssertGreaterThan(large.markerWidth, small.markerWidth)
            XCTAssertGreaterThan(large.gutterWidth, small.gutterWidth)
            XCTAssertGreaterThan(large.codeX, small.codeX)
            XCTAssertGreaterThan(large.hunkHeight, small.hunkHeight)
            // Each grows about as the code font does, from 12 to 17.
            XCTAssertEqual(large.numberWidth / small.numberWidth, 17 / 12, accuracy: 0.05)
            XCTAssertEqual(large.markerWidth / small.markerWidth, 17 / 12, accuracy: 0.05)
        }
    }

    func testFiveDigitsFitAtSize17AndAtSize12() {
        for fontSize: CGFloat in [12, 17] {
            for widest in [10_000, 99_999] {
                let metrics = metrics(fontSize, widestNumber: widest)
                let room = metrics.numberWidth - 2 * metrics.numberPadding
                XCTAssertGreaterThanOrEqual(room, typesetWidth(String(widest), fontSize: fontSize),
                                            "\(widest) does not fit its column at \(fontSize)")
            }
        }
        // The fixed 46 points held only three digits whole at 17.
        XCTAssertLessThan(46 - 9, typesetWidth("9999", fontSize: 17))
    }

    func testTheColumnFitsTheWidestLineNumberShownAndAtLeastFourDigits() {
        for fontSize: CGFloat in [12, 17] {
            let four = metrics(fontSize, widestNumber: 9999)
            let five = metrics(fontSize, widestNumber: 10_000)
            let seven = metrics(fontSize, widestNumber: 1_234_567)
            XCTAssertGreaterThan(five.numberWidth, four.numberWidth)
            XCTAssertGreaterThan(seven.numberWidth, five.numberWidth)
            XCTAssertEqual(five.codeX - four.codeX, 2 * (five.numberWidth - four.numberWidth))
            for (metrics, widest) in [(four, "9999"), (five, "10000"), (seven, "1234567")] {
                XCTAssertGreaterThanOrEqual(metrics.numberWidth - 2 * metrics.numberPadding,
                                            typesetWidth(widest, fontSize: fontSize))
            }
        }
    }

    func testCodeStartsAfterTheGutterAndTheMarkerAndWrapsAtThePanesEdge() {
        for fontSize: CGFloat in [12, 17] {
            for layout in [GitView.Layout.unified, .split] {
                for width: CGFloat in [500, 801, 1400] {
                    let metrics = metrics(fontSize, layout, width: width, widestNumber: 10_000)
                    XCTAssertEqual(metrics.codeX, metrics.gutterWidth + metrics.markerWidth)
                    XCTAssertEqual(metrics.gutterWidth, (layout == .split ? 1 : 2) * metrics.numberWidth)
                    // A side of a split diff is half the pane, less the line between them.
                    let side = layout == .split ? (width - 1) / 2 : width
                    let room = side - metrics.codeX - Metrics.trailingRoom
                    XCTAssertLessThanOrEqual(CGFloat(metrics.columns) * metrics.charWidth, room)
                    XCTAssertGreaterThan(CGFloat(metrics.columns + 1) * metrics.charWidth, room)
                    XCTAssertEqual(metrics.charWidth, NSAttributedString(
                        string: "0", attributes: [.font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)]
                    ).size().width, accuracy: 0.01)
                }
            }
        }
    }

    func testTheLineHeightIsTheCodeSizeAndAHalfAndMore() {
        XCTAssertEqual(Metrics.lineHeight(12), 19)
        XCTAssertEqual(Metrics.lineHeight(17), 27)
        XCTAssertEqual(metrics(17).lineHeight, 27)
        XCTAssertEqual(metrics(17).fontSize, 17)
        XCTAssertEqual(metrics(17).hunkHeight, 38)
    }

    @MainActor
    func testTheWidestLineNumberIsOfTheLinesShown() {
        let lines = [GitDiffLine(kind: .context, old: 9998, new: 10_001, text: "a"),
                     GitDiffLine(kind: .removed, old: 9999, new: nil, text: "b"),
                     GitDiffLine(kind: .added, old: nil, new: 10_002, text: "c")]
        let unified = lines.enumerated().map { GitView.DiffRow(id: $0.offset, kind: .line($0.element), file: 0, hunk: 0, lines: []) }
        XCTAssertEqual(GitView.widestLineNumber(in: unified), 10_002)
        // A split diff's old side shows old numbers, and its new side new ones.
        let split = [GitView.DiffRow(id: 0, kind: .pair(old: lines[1], new: lines[2]), file: 0, hunk: 0, lines: []),
                     GitView.DiffRow(id: 1, kind: .hunk(file: 0, hunk: 0), file: 0, hunk: 0, lines: [])]
        XCTAssertEqual(GitView.widestLineNumber(in: split), 10_002)
        XCTAssertEqual(GitView.widestLineNumber(in: []), 0)
    }
}
