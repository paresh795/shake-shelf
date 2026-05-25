import Foundation

public enum ShelfQuickLookResolver {
    public static func urlsToPreview(allURLs: [URL], selectedURL: URL?, isExpanded: Bool) -> [URL] {
        guard isExpanded, let selectedURL else {
            return allURLs
        }

        return allURLs.contains(selectedURL) ? [selectedURL] : allURLs
    }
}
