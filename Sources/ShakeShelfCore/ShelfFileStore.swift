import Foundation

public struct ShelfFileStore {
    private let baseDirectory: URL
    private let fileManager: FileManager

    public init(baseDirectory: URL, fileManager: FileManager = .default) {
        self.baseDirectory = baseDirectory
        self.fileManager = fileManager
    }

    public static func defaultIncomingDirectory() throws -> URL {
        let supportDirectory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        return supportDirectory
            .appendingPathComponent("Shake Shelf", isDirectory: true)
            .appendingPathComponent("Incoming", isDirectory: true)
    }

    public func ensureBaseDirectory() throws -> URL {
        try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        return baseDirectory
    }

    public func store(data: Data, preferredExtension: String, suggestedName: String?) throws -> URL {
        _ = try ensureBaseDirectory()

        let suggestedName = sanitize(suggestedName)
        let sanitizedName = suggestedName.isEmpty ? "Dropped Image" : suggestedName
        let sanitizedExtension = sanitizeExtension(preferredExtension)
        let destination = uniqueURL(baseName: sanitizedName, pathExtension: sanitizedExtension)

        try data.write(to: destination, options: .atomic)
        return destination
    }

    private func uniqueURL(baseName: String, pathExtension: String) -> URL {
        var candidate = baseDirectory
            .appendingPathComponent(baseName)
            .appendingPathExtension(pathExtension)

        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = baseDirectory
                .appendingPathComponent("\(baseName) \(suffix)")
                .appendingPathExtension(pathExtension)
            suffix += 1
        }

        return candidate
    }

    private func sanitize(_ name: String?) -> String {
        guard let name else { return "" }

        let invalid = CharacterSet(charactersIn: "/:\\")
            .union(.newlines)
            .union(.controlCharacters)

        let cleaned = name
            .components(separatedBy: invalid)
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return cleaned.isEmpty ? "" : String(cleaned.prefix(80))
    }

    private func sanitizeExtension(_ pathExtension: String) -> String {
        let cleaned = pathExtension
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }

        return cleaned.isEmpty ? "dat" : String(cleaned.prefix(12))
    }
}
