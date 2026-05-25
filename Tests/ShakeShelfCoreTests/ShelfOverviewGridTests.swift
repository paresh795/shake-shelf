import XCTest
@testable import ShakeShelfCore

final class ShelfOverviewGridTests: XCTestCase {
    func testSmallShelvesUseEnoughColumnsToAvoidTallLayouts() {
        XCTAssertEqual(ShelfOverviewGrid.columns(forItemCount: 2), 2)
        XCTAssertEqual(ShelfOverviewGrid.columns(forItemCount: 6), 3)
        XCTAssertEqual(ShelfOverviewGrid.columns(forItemCount: 8), 4)
    }

    func testLargerShelvesCapColumnCount() {
        XCTAssertEqual(ShelfOverviewGrid.columns(forItemCount: 16), 6)
        XCTAssertEqual(ShelfOverviewGrid.columns(forItemCount: 40), 6)
    }

    func testRowsRoundUpForLastPartialRow() {
        XCTAssertEqual(ShelfOverviewGrid.rows(forItemCount: 8, columns: 4), 2)
        XCTAssertEqual(ShelfOverviewGrid.rows(forItemCount: 9, columns: 4), 3)
        XCTAssertEqual(ShelfOverviewGrid.rows(forItemCount: 0, columns: 4), 0)
    }
}
