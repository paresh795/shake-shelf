import Foundation

public struct ShelfItems: Equatable {
    public private(set) var urls: [URL]

    public init(urls: [URL] = []) {
        self.urls = []
        add(urls)
    }

    @discardableResult
    public mutating func add(_ newURLs: [URL]) -> [URL] {
        var seen = Set(urls.map { $0.standardizedFileURL.path })
        var accepted: [URL] = []

        for url in newURLs.map(\.standardizedFileURL) where url.isFileURL {
            let path = url.path
            guard !seen.contains(path) else { continue }
            seen.insert(path)
            accepted.append(url)
        }

        urls.append(contentsOf: accepted)
        return accepted
    }

    public mutating func clear() {
        urls.removeAll()
    }

    @discardableResult
    public mutating func remove(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        guard let index = urls.firstIndex(where: { $0.standardizedFileURL.path == path }) else {
            return false
        }

        urls.remove(at: index)
        return true
    }
}
