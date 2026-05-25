import XCTest
@testable import ShakeShelfCore

final class ShelfListScrollTests: XCTestCase {
    func testMaxOffsetIsZeroWhenRowsFit() {
        let maxOffset = ShelfListScroll.maxOffset(
            itemCount: 3,
            viewportHeight: 160,
            rowHeight: 35,
            rowSpacing: 4
        )

        XCTAssertEqual(maxOffset, 0)
    }

    func testMaxOffsetAccountsForRowsAndSpacing() {
        let maxOffset = ShelfListScroll.maxOffset(
            itemCount: 7,
            viewportHeight: 160,
            rowHeight: 35,
            rowSpacing: 4
        )

        XCTAssertEqual(maxOffset, 109)
    }

    func testClampedOffsetStaysInsideScrollableRange() {
        XCTAssertEqual(
            ShelfListScroll.clampedOffset(
                -10,
                itemCount: 7,
                viewportHeight: 160,
                rowHeight: 35,
                rowSpacing: 4
            ),
            0
        )

        XCTAssertEqual(
            ShelfListScroll.clampedOffset(
                999,
                itemCount: 7,
                viewportHeight: 160,
                rowHeight: 35,
                rowSpacing: 4
            ),
            109
        )
    }

    func testRowYSubtractsScrollOffset() {
        let y = ShelfListScroll.rowY(
            index: 3,
            startY: 48,
            scrollOffset: 20,
            rowHeight: 35,
            rowSpacing: 4
        )

        XCTAssertEqual(y, 145)
    }
}
