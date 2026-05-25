import Foundation

public enum ShelfOverviewGrid {
    public static func columns(forItemCount itemCount: Int) -> Int {
        switch itemCount {
        case ...0:
            return 0
        case 1...2:
            return itemCount
        case 3...6:
            return 3
        case 7...8:
            return 4
        case 9...15:
            return 5
        default:
            return 6
        }
    }

    public static func rows(forItemCount itemCount: Int, columns: Int) -> Int {
        guard itemCount > 0, columns > 0 else { return 0 }
        return Int(ceil(Double(itemCount) / Double(columns)))
    }
}
