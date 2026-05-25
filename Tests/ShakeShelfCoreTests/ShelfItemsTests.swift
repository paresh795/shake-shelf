import XCTest
@testable import ShakeShelfCore

final class ShelfItemsTests: XCTestCase {
    func testAddKeepsUniqueFileURLsInOrder() {
        var items = ShelfItems()
        let first = URL(fileURLWithPath: "/tmp/example.png")
        let duplicate = URL(fileURLWithPath: "/tmp/../tmp/example.png")
        let second = URL(fileURLWithPath: "/tmp/second.mov")

        let accepted = items.add([first, duplicate, second])

        XCTAssertEqual(accepted, [first.standardizedFileURL, second.standardizedFileURL])
        XCTAssertEqual(items.urls, [first.standardizedFileURL, second.standardizedFileURL])
    }

    func testAddRejectsNonFileURLs() {
        var items = ShelfItems()
        let remote = URL(string: "https://example.com/image.png")!

        let accepted = items.add([remote])

        XCTAssertTrue(accepted.isEmpty)
        XCTAssertTrue(items.urls.isEmpty)
    }

    func testClearRemovesAllURLs() {
        var items = ShelfItems(urls: [
            URL(fileURLWithPath: "/tmp/first.png"),
            URL(fileURLWithPath: "/tmp/second.mov")
        ])

        items.clear()

        XCTAssertTrue(items.urls.isEmpty)
    }

    func testRemoveDeletesOneURLAndKeepsTheRestInOrder() {
        let first = URL(fileURLWithPath: "/tmp/first.png")
        let second = URL(fileURLWithPath: "/tmp/second.mov")
        let third = URL(fileURLWithPath: "/tmp/third.pdf")
        var items = ShelfItems(urls: [first, second, third])

        let removed = items.remove(second)

        XCTAssertTrue(removed)
        XCTAssertEqual(items.urls, [first, third].map(\.standardizedFileURL))
    }

    func testRemoveMatchesStandardizedFileURL() {
        let first = URL(fileURLWithPath: "/tmp/first.png")
        let equivalent = URL(fileURLWithPath: "/tmp/../tmp/first.png")
        var items = ShelfItems(urls: [first])

        let removed = items.remove(equivalent)

        XCTAssertTrue(removed)
        XCTAssertTrue(items.urls.isEmpty)
    }

    func testRemoveReturnsFalseWhenURLIsNotInShelf() {
        let first = URL(fileURLWithPath: "/tmp/first.png")
        let missing = URL(fileURLWithPath: "/tmp/missing.png")
        var items = ShelfItems(urls: [first])

        let removed = items.remove(missing)

        XCTAssertFalse(removed)
        XCTAssertEqual(items.urls, [first.standardizedFileURL])
    }
}
