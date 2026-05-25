import XCTest
@testable import ShakeShelfCore

final class ShelfQuickLookResolverTests: XCTestCase {
    private let first = URL(fileURLWithPath: "/tmp/first.png")
    private let second = URL(fileURLWithPath: "/tmp/second.mov")

    func testStackModePreviewsAllFiles() {
        let urls = ShelfQuickLookResolver.urlsToPreview(
            allURLs: [first, second],
            selectedURL: second,
            isExpanded: false
        )

        XCTAssertEqual(urls, [first, second])
    }

    func testListModePreviewsSelectedFile() {
        let urls = ShelfQuickLookResolver.urlsToPreview(
            allURLs: [first, second],
            selectedURL: second,
            isExpanded: true
        )

        XCTAssertEqual(urls, [second])
    }

    func testListModeFallsBackToAllFilesWhenNothingIsSelected() {
        let urls = ShelfQuickLookResolver.urlsToPreview(
            allURLs: [first, second],
            selectedURL: nil,
            isExpanded: true
        )

        XCTAssertEqual(urls, [first, second])
    }
}
