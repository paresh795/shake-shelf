import Foundation
import ShakeShelfCore
import XCTest

final class ShelfHistoryStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShelfHistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeStore(
        retention: TimeInterval = ShelfHistoryStore.defaultRetentionInterval,
        maxSessions: Int = ShelfHistoryStore.defaultMaxSessions
    ) -> ShelfHistoryStore {
        ShelfHistoryStore(
            fileURL: directory.appendingPathComponent("History.plist"),
            retentionInterval: retention,
            maxSessions: maxSessions
        )
    }

    private func makeFile(named name: String) -> URL {
        let url = directory.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data("hi".utf8))
        return url
    }

    private func snapshot(_ store: ShelfHistoryStore) -> [(key: String, first: Double, last: Double)] {
        var copy = store
        return copy.allSessions().map { (key: $0.urls.sorted().joined(separator: ","), first: $0.firstSeen.timeIntervalSince1970, last: $0.lastSeen.timeIntervalSince1970) }
    }

    // 1. Identical content extends the existing session — no new record.
    func testIdenticalContentExtendsSession() {
        let a = makeFile(named: "a.txt")
        let b = makeFile(named: "b.txt")
        let first = Date().addingTimeInterval(-7200)
        let second = Date().addingTimeInterval(-3600)
        var store = makeStore()

        store.record(urls: [a, b], at: first)
        store.record(urls: [a, b], at: second)

        let sessions = snapshot(store)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].first, first.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(sessions[0].last, second.timeIntervalSince1970, accuracy: 0.001)
    }

    // 2. Different content closes the current session and opens a new one.
    func testDifferentContentOpensNewSession() {
        let a = makeFile(named: "a.txt")
        let b = makeFile(named: "b.txt")
        let c = makeFile(named: "c.txt")
        let first = Date().addingTimeInterval(-7200)
        let second = Date().addingTimeInterval(-3600)
        var store = makeStore()

        store.record(urls: [a, b], at: first)
        store.record(urls: [a, c], at: second)

        let sessions = snapshot(store)
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].last, second.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(sessions[1].first, first.timeIntervalSince1970, accuracy: 0.001)
    }

    // 3. Content equality is order-insensitive.
    func testContentEqualityIgnoresOrder() {
        let a = makeFile(named: "a.txt")
        let b = makeFile(named: "b.txt")
        var store = makeStore()

        store.record(urls: [a, b], at: Date().addingTimeInterval(-7200))
        store.record(urls: [b, a], at: Date().addingTimeInterval(-3600))

        XCTAssertEqual(snapshot(store).count, 1)
    }

    // 4. Empty states are never recorded.
    func testEmptyStateIsIgnored() {
        var store = makeStore()
        store.record(urls: [], at: Date().addingTimeInterval(-7200))
        XCTAssertTrue(snapshot(store).isEmpty)
    }

    // 5. Duplicate paths within one snapshot are deduplicated.
    func testDuplicatePathsDeduplicated() {
        let a = makeFile(named: "a.txt")
        var store = makeStore()
        store.record(urls: [a, a], at: Date().addingTimeInterval(-7200))

        var copy = store
        let sessions = copy.allSessions()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].urls.count, 1)
    }

    // 6. Retention prunes sessions older than the window.
    func testRetentionPrunesOldSessions() {
        let a = makeFile(named: "a.txt")
        let b = makeFile(named: "b.txt")
        var store = makeStore(retention: 100)

        store.record(urls: [a], at: Date().addingTimeInterval(-200))
        store.record(urls: [b], at: Date().addingTimeInterval(-50))

        var copy = store
        copy.allSessions()
        let pruned = snapshot(copy)
        XCTAssertEqual(pruned.count, 1)
        XCTAssertTrue(pruned[0].key.contains("b.txt"))
    }

    // 7. The session cap is enforced, keeping the most recent sessions.
    func testSessionCapKeepsMostRecent() {
        var store = makeStore(maxSessions: 3)
        for index in 0..<10 {
            let file = makeFile(named: "f\(index).txt")
            store.record(urls: [file], at: Date().addingTimeInterval(Double(index) * 10))
        }

        var copy = store
        let sessions = copy.allSessions()
        XCTAssertEqual(sessions.count, 3)
        XCTAssertTrue(sessions[0].urls[0].hasSuffix("f9.txt"))
    }

    // 8. Persistence round-trip preserves sessions.
    func testPersistenceRoundTrip() throws {
        let a = makeFile(named: "a.txt")
        let b = makeFile(named: "b.txt")
        let recorded = Date().addingTimeInterval(-7200)
        var store = makeStore()
        store.record(urls: [a, b], at: recorded)
        store.persistToDisk()

        var reloaded = makeStore()
        reloaded.reloadFromDisk()
        let sessions = snapshot(reloaded)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].first, recorded.timeIntervalSince1970, accuracy: 0.001)
    }

    // 9. Corrupt file loads as empty without throwing.
    func testCorruptFileLoadsEmpty() throws {
        let corruptURL = directory.appendingPathComponent("History.plist")
        try Data("not a plist".utf8).write(to: corruptURL)

        var store = makeStore()
        XCTAssertTrue(snapshot(store).isEmpty)
    }

    // 10. Missing files are filtered at restore, with a count.
    func testRestoreFiltersMissingFiles() {
        let existing = makeFile(named: "kept.txt")
        let missingPath = directory.appendingPathComponent("gone.txt").path

        var store = makeStore()
        store.record(urls: [existing, URL(fileURLWithPath: missingPath)], at: Date().addingTimeInterval(-7200))

        var copy = store
        guard let session = copy.allSessions().first else {
            return XCTFail("expected a session")
        }
        let (urls, missing) = store.restoreState(from: session)
        XCTAssertEqual(urls.map(\.lastPathComponent), ["kept.txt"])
        XCTAssertEqual(missing, 1)
    }

    // 11. Restoring an all-missing session yields zero files.
    func testRestoreAllMissing() {
        var store = makeStore()
        store.record(urls: [URL(fileURLWithPath: directory.appendingPathComponent("nope.txt").path)], at: Date().addingTimeInterval(-7200))

        var copy = store
        guard let session = copy.allSessions().first else {
            return XCTFail("expected a session")
        }
        let (urls, missing) = store.restoreState(from: session)
        XCTAssertTrue(urls.isEmpty)
        XCTAssertEqual(missing, 1)
    }

    // 12. clearHistory empties the store and persists.
    func testClearHistory() throws {
        let a = makeFile(named: "a.txt")
        var store = makeStore()
        store.record(urls: [a], at: Date().addingTimeInterval(-7200))
        store.clearHistory()
        store.persistToDisk()

        var reloaded = makeStore()
        reloaded.reloadFromDisk()
        XCTAssertTrue(snapshot(reloaded).isEmpty)
    }
}
