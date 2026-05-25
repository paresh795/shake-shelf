import Foundation

public enum ShelfCopyResolver {
    public static func urlsToCopy(allURLs: [URL], selectedURL: URL?, isExpanded: Bool) -> [URL] {
        guard isExpanded, let selectedURL else {
            return allURLs
        }

        return allURLs.contains(selectedURL) ? [selectedURL] : allURLs
    }
}
