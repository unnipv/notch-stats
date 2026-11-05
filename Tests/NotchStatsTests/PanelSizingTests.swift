import XCTest
@testable import NotchStats

final class PanelSizingTests: XCTestCase {

    private func height(_ rows: Int, rowHeight: CGFloat = AppStore.rowHeight) -> CGFloat {
        AppStore.expandedHeight(barHeight: 32, rows: rows, rowHeight: rowHeight)
    }

    func testPanelHeightIsExactlyItsContent() {
        // Each extra row adds one row plus one gap, and nothing else.
        XCTAssertEqual(height(4) - height(3), AppStore.rowHeight + AppStore.rowSpacing)
        XCTAssertEqual(height(5) - height(3), 2 * (AppStore.rowHeight + AppStore.rowSpacing))
    }

    func testPanelHeightDependsOnlyOnTheRowCount() {
        // A refresh that changes values but not the count cannot resize it.
        XCTAssertEqual(height(5), height(5))
    }

    func testSessionRowsAreShorterThanUsageRows() {
        XCTAssertLessThan(height(4, rowHeight: AppStore.sessionRowHeight), height(4))
    }

    func testPanelNeverCollapsesBelowOneRow() {
        XCTAssertEqual(height(0), height(1))
    }

    func testSixRowsStillFitTheWindow() {
        // The island window is 620 pt tall.
        XCTAssertLessThanOrEqual(height(6), 620)
    }
}
