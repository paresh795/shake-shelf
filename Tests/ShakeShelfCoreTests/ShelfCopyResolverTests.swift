import XCTest
@testable import ShakeShelfCore

final class ShelfCopyResolverTests: XCTestCase {
    private let first = URL(fileURLWithPath: "/tmp/first.png")
    private let second = URL(fileURLWithPath: "/tmp/second.png")

    func testStackModeCopiesAllFiles() {
        let urls = ShelfCopyResolver.urlsToCopy(
            allURLs: [first, second],
            selectedURL: first,
            isExpanded: false
        )

        XCTAssertEqual(urls, [first, second])
    }

    func testListModeCopiesSelectedFile() {
        let urls = ShelfCopyResolver.urlsToCopy(
            allURLs: [first, second],
            selectedURL: second,
            isExpanded: true
        )

        XCTAssertEqual(urls, [second])
    }

    func testListModeFallsBackToAllFilesWhenNothingIsSelected() {
        let urls = ShelfCopyResolver.urlsToCopy(
            allURLs: [first, second],
            selectedURL: nil,
            isExpanded: true
        )

        XCTAssertEqual(urls, [first, second])
    }
}
