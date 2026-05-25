import XCTest
@testable import ShakeShelfCore

final class ShelfFileStoreTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testStoresDataWithSanitizedSuggestedNameAndExtension() throws {
        let store = ShelfFileStore(baseDirectory: temporaryDirectory)
        let data = Data("image-bytes".utf8)

        let url = try store.store(data: data, preferredExtension: "png", suggestedName: "../bad:name")

        XCTAssertEqual(url.deletingPathExtension().lastPathComponent, "bad-name")
        XCTAssertEqual(url.pathExtension, "png")
        XCTAssertEqual(try Data(contentsOf: url), data)
        XCTAssertTrue(url.path.hasPrefix(temporaryDirectory.path))
    }

    func testStoresDataWithUniqueNameWhenFileAlreadyExists() throws {
        let store = ShelfFileStore(baseDirectory: temporaryDirectory)
        let first = try store.store(data: Data("first".utf8), preferredExtension: "png", suggestedName: "image")
        let second = try store.store(data: Data("second".utf8), preferredExtension: "png", suggestedName: "image")

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.lastPathComponent, "image.png")
        XCTAssertEqual(second.lastPathComponent, "image 2.png")
        XCTAssertEqual(try Data(contentsOf: second), Data("second".utf8))
    }

    func testCreatesBaseDirectoryWhenMissing() throws {
        let missingDirectory = temporaryDirectory.appendingPathComponent("Incoming", isDirectory: true)
        let store = ShelfFileStore(baseDirectory: missingDirectory)

        let url = try store.store(data: Data("content".utf8), preferredExtension: "tiff", suggestedName: nil)

        XCTAssertTrue(FileManager.default.fileExists(atPath: missingDirectory.path))
        XCTAssertEqual(url.lastPathComponent, "Dropped Image.tiff")
    }
}
