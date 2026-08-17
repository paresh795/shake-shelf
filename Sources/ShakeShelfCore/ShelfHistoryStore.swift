import Foundation

public struct ShelfSession: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var urls: [String]
    public var firstSeen: Date
    public var lastSeen: Date

    public init(id: UUID = UUID(), urls: [String], firstSeen: Date, lastSeen: Date) {
        self.id = id
        self.urls = urls
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }
}

public struct ShelfHistoryStore: Sendable {
    public static let defaultRetentionInterval: TimeInterval = 7 * 24 * 60 * 60
    public static let defaultMaxSessions = 200

    private let fileURL: URL
    private let retentionInterval: TimeInterval
    private let maxSessions: Int
    private var sessions: [ShelfSession]
    private var dirty = false

    public init(
        fileURL: URL,
        retentionInterval: TimeInterval = ShelfHistoryStore.defaultRetentionInterval,
        maxSessions: Int = ShelfHistoryStore.defaultMaxSessions
    ) {
        self.fileURL = fileURL
        self.retentionInterval = retentionInterval
        self.maxSessions = maxSessions
        self.sessions = Self.loadSessions(from: fileURL)
    }

    public static func defaultFileURL() throws -> URL {
        let supportDirectory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        return supportDirectory
            .appendingPathComponent("Shake Shelf", isDirectory: true)
            .appendingPathComponent("History.plist", isDirectory: false)
    }

    // MARK: - Recording

    /// Records that `urls` was the shelf state at `date`.
    /// Identical content extends the most recent session; different content opens a new one.
    /// Empty states are never recorded.
    public mutating func record(urls: [URL], at date: Date) {
        let paths = normalized(urls)
        guard !paths.isEmpty else { return }

        prune(now: date)

        if let last = sessions.last, contentKey(last.urls) == contentKey(paths) {
            sessions[sessions.count - 1].lastSeen = date
        } else {
            sessions.append(ShelfSession(urls: paths, firstSeen: date, lastSeen: date))
            enforceCap()
        }

        dirty = true
    }

    // MARK: - Reading

    /// All sessions that are still within the retention window, newest first.
    public mutating func allSessions() -> [ShelfSession] {
        prune(now: Date())
        return sessions.reversed()
    }

    /// Converts a session's paths back into existing file URLs, counting missing files.
    public func restoreState(from session: ShelfSession) -> (urls: [URL], missing: Int) {
        var urls: [URL] = []
        var missing = 0

        for path in session.urls {
            if FileManager.default.fileExists(atPath: path) {
                urls.append(URL(fileURLWithPath: path).standardizedFileURL)
            } else {
                missing += 1
            }
        }

        return (urls, missing)
    }

    // MARK: - Mutation

    public mutating func clearHistory() {
        sessions.removeAll()
        dirty = true
    }

    // MARK: - Persistence

    /// Writes the current in-memory state to disk (atomic). No-op when nothing changed.
    public func persistToDisk() {
        guard dirty else { return }

        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try PropertyListEncoder().encode(sessions)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            return
        }
    }

    public mutating func reloadFromDisk() {
        sessions = Self.loadSessions(from: fileURL)
        dirty = false
    }

    // MARK: - Helpers

    private func normalized(_ urls: [URL]) -> [String] {
        var seen: Set<String> = []
        var paths: [String] = []

        for url in urls where url.isFileURL {
            let path = url.standardizedFileURL.path
            guard !seen.contains(path) else { continue }
            seen.insert(path)
            paths.append(path)
        }

        return paths
    }

    private func contentKey(_ paths: [String]) -> String {
        paths.sorted().joined(separator: "\u{1F}")
    }

    private mutating func prune(now: Date) {
        let cutoff = now.timeIntervalSince1970 - retentionInterval
        sessions.removeAll { $0.lastSeen.timeIntervalSince1970 < cutoff }
    }

    private mutating func enforceCap() {
        guard sessions.count > maxSessions else { return }
        let overflow = sessions.count - maxSessions
        sessions.removeFirst(overflow)
    }

    private static func loadSessions(from fileURL: URL) -> [ShelfSession] {
        guard let data = FileManager.default.contents(atPath: fileURL.path) else {
            return []
        }

        do {
            return try PropertyListDecoder().decode([ShelfSession].self, from: data)
        } catch {
            return []
        }
    }
}
