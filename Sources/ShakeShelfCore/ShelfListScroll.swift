import Foundation

public enum ShelfListScroll {
    public static func contentHeight(
        itemCount: Int,
        rowHeight: Double,
        rowSpacing: Double
    ) -> Double {
        guard itemCount > 0 else { return 0 }
        return (Double(itemCount) * rowHeight) + (Double(max(0, itemCount - 1)) * rowSpacing)
    }

    public static func maxOffset(
        itemCount: Int,
        viewportHeight: Double,
        rowHeight: Double,
        rowSpacing: Double
    ) -> Double {
        max(0, contentHeight(itemCount: itemCount, rowHeight: rowHeight, rowSpacing: rowSpacing) - viewportHeight)
    }

    public static func clampedOffset(
        _ offset: Double,
        itemCount: Int,
        viewportHeight: Double,
        rowHeight: Double,
        rowSpacing: Double
    ) -> Double {
        min(
            max(0, offset),
            maxOffset(
                itemCount: itemCount,
                viewportHeight: viewportHeight,
                rowHeight: rowHeight,
                rowSpacing: rowSpacing
            )
        )
    }

    public static func rowY(
        index: Int,
        startY: Double,
        scrollOffset: Double,
        rowHeight: Double,
        rowSpacing: Double
    ) -> Double {
        startY + (Double(index) * (rowHeight + rowSpacing)) - scrollOffset
    }
}
