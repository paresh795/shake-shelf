import Foundation

public enum ShelfDragSurface {
    case compactStack
    case list
    case overview
}

public enum ShelfDragResolver {
    public static func urlsToDrag(allURLs: [URL], selectedURL: URL?, surface: ShelfDragSurface) -> [URL] {
        switch surface {
        case .compactStack:
            return allURLs
        case .list, .overview:
            guard let selectedURL, allURLs.contains(selectedURL) else {
                return []
            }

            return [selectedURL]
        }
    }
}
