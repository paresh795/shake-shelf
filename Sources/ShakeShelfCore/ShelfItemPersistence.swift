import Foundation

public struct ShelfItemPersistence {
    private let fileURL: URL
    private let fileManager: FileManager

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
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
            .appendingPathComponent("Items.plist", isDirectory: false)
    }

    public func save(_ urls: [URL]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let paths = urls
            .map { $0.standardizedFileURL.path }
            .sorted()

        let data = try PropertyListEncoder().encode(paths)
        try data.write(to: fileURL, options: .atomic)
    }

    public func load() -> [URL] {
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = fileManager.contents(atPath: fileURL.path),
              let paths = try? PropertyListDecoder().decode([String].self, from: data) else {
            return []
        }

        var seen: Set<String> = []
        var urls: [URL] = []

        for path in paths where fileManager.fileExists(atPath: path) {
            let standardized = URL(fileURLWithPath: path).standardizedFileURL
            guard !seen.contains(standardized.path) else { continue }
            seen.insert(standardized.path)
            urls.append(standardized)
        }

        return urls
    }

    public func clear() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }
}
