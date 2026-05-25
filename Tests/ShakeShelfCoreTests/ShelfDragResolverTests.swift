import XCTest
@testable import ShakeShelfCore

final class ShelfDragResolverTests: XCTestCase {
    private let first = URL(fileURLWithPath: "/tmp/first.png")
    private let second = URL(fileURLWithPath: "/tmp/second.png")

    func testCompactStackDragsAllFiles() {
        let urls = ShelfDragResolver.urlsToDrag(
            allURLs: [first, second],
            selectedURL: nil,
            surface: .compactStack
        )

        XCTAssertEqual(urls, [first, second])
    }

    func testListRowDragsSelectedFileOnly() {
        let urls = ShelfDragResolver.urlsToDrag(
            allURLs: [first, second],
            selectedURL: second,
            surface: .list
        )

        XCTAssertEqual(urls, [second])
    }

    func testOverviewTileDragsSelectedFileOnly() {
        let urls = ShelfDragResolver.urlsToDrag(
            allURLs: [first, second],
            selectedURL: first,
            surface: .overview
        )

        XCTAssertEqual(urls, [first])
    }

    func testOverviewEmptySpaceDoesNotDragAllFiles() {
        let urls = ShelfDragResolver.urlsToDrag(
            allURLs: [first, second],
            selectedURL: nil,
            surface: .overview
        )

        XCTAssertTrue(urls.isEmpty)
    }
}
