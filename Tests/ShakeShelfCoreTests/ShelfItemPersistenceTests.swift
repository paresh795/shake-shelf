import Foundation
import ShakeShelfCore
import XCTest

final class ShelfItemPersistenceTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShelfItemPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makePersistence() -> ShelfItemPersistence {
        ShelfItemPersistence(fileURL: directory.appendingPathComponent("Items.plist"))
    }

    private func makeTempFile(named name: String) -> URL {
        let url = directory.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data("hello".utf8))
        return url
    }

    func testRoundTripPreservesExistingFiles() throws {
        let first = makeTempFile(named: "a.txt")
        let second = makeTempFile(named: "b.txt")
        let persistence = makePersistence()

        try persistence.save([first, second])
        XCTAssertEqual(Set(persistence.load().map(\.path)), Set([first.path, second.path]))
    }

    func testLoadSkipsDeletedFiles() throws {
        let existing = makeTempFile(named: "kept.txt")
        let deleted = directory.appendingPathComponent("gone.txt")
        let persistence = makePersistence()

        try persistence.save([existing, deleted])
        XCTAssertEqual(persistence.load().map(\.path), [existing.path])
    }

    func testLoadIsEmptyWhenNothingSaved() {
        XCTAssertTrue(makePersistence().load().isEmpty)
    }

    func testClearRemovesSavedState() throws {
        let file = makeTempFile(named: "c.txt")
        let persistence = makePersistence()

        try persistence.save([file])
        try persistence.clear()

        XCTAssertTrue(persistence.load().isEmpty)
    }

    func testSaveDeduplicatesPaths() throws {
        let file = makeTempFile(named: "d.txt")
        let persistence = makePersistence()

        try persistence.save([file, file])
        XCTAssertEqual(persistence.load().count, 1)
    }
}
