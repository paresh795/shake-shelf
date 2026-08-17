import CoreGraphics
import Foundation

/// Pure, testable geometry and decision logic for the collapsible shelf ball.
public enum ShelfBallBehavior {
    public static let ballDiameter: CGFloat = 44
    public static let hoverHaloInset: CGFloat = 36
    public static let shelfHoverMargin: CGFloat = 64
    public static let autoCollapseDelay: TimeInterval = 2.5
    public static let hoverOpenDwell: TimeInterval = 0.35
    public static let hoverRestThreshold: CGFloat = 6
    public static let defaultHomeInset: CGFloat = 48
    public static let clampInset: CGFloat = 10
    public static let anchorGap: CGFloat = 12
    public static let edgeGap: CGFloat = 10
    public static let dragThreshold: CGFloat = 4

    public static func ballRect(centeredAt point: CGPoint) -> NSRect {
        NSRect(
            x: point.x - ballDiameter / 2,
            y: point.y - ballDiameter / 2,
            width: ballDiameter,
            height: ballDiameter
        )
    }

    public static func defaultHomePosition(in visibleFrame: NSRect) -> CGPoint {
        CGPoint(
            x: visibleFrame.maxX - defaultHomeInset - ballDiameter / 2,
            y: visibleFrame.minY + defaultHomeInset + ballDiameter / 2
        )
    }

    public static func clampedPosition(_ point: CGPoint, in visibleFrame: NSRect) -> CGPoint {
        let minX = visibleFrame.minX + clampInset
        let maxX = visibleFrame.maxX - clampInset
        let minY = visibleFrame.minY + clampInset
        let maxY = visibleFrame.maxY - clampInset

        let clampedX = maxX < minX ? (minX + maxX) / 2 : min(max(point.x, minX), maxX)
        let clampedY = maxY < minY ? (minY + maxY) / 2 : min(max(point.y, minY), maxY)

        return CGPoint(x: clampedX, y: clampedY)
    }

    /// Shelf anchored just above the ball, flipping below when there is no room,
    /// clamped to the visible frame.
    public static func shelfFrame(nearBall ballCenter: CGPoint, size: NSSize, in visibleFrame: NSRect) -> NSRect {
        let ball = ballRect(centeredAt: ballCenter)

        var origin = CGPoint(
            x: ballCenter.x - size.width / 2,
            y: ball.maxY + anchorGap
        )

        if origin.y + size.height > visibleFrame.maxY - edgeGap {
            origin.y = ball.minY - anchorGap - size.height
        }

        origin.x = max(visibleFrame.minX + edgeGap, min(origin.x, visibleFrame.maxX - size.width - edgeGap))
        origin.y = max(visibleFrame.minY + edgeGap, min(origin.y, visibleFrame.maxY - size.height - edgeGap))

        return NSRect(origin: origin, size: size)
    }

    public static func shouldCollapse(
        pointerInShelfArea: Bool,
        mouseButtonPressed: Bool,
        quickLookVisible: Bool,
        receivingExternalDrop: Bool,
        appIsActive: Bool
    ) -> Bool {
        if appIsActive { return false }
        if mouseButtonPressed { return false }
        if quickLookVisible { return false }
        if receivingExternalDrop { return false }
        return !pointerInShelfArea
    }

    public static func isDragMovement(from start: CGPoint, to end: CGPoint) -> Bool {
        let dx = end.x - start.x
        let dy = end.y - start.y
        return (dx * dx) + (dy * dy) >= dragThreshold * dragThreshold
    }

    /// True when the pointer has moved less than the rest threshold between
    /// two samples — used to open the ball only when the pointer settles.
    public static func isRestMovement(from start: CGPoint, to end: CGPoint) -> Bool {
        let dx = end.x - start.x
        let dy = end.y - start.y
        return (dx * dx) + (dy * dy) < hoverRestThreshold * hoverRestThreshold
    }
}
