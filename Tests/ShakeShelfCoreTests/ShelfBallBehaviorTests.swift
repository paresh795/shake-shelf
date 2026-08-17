import Foundation
import ShakeShelfCore
import XCTest

final class ShelfBallBehaviorTests: XCTestCase {
    private let frame = NSRect(x: 0, y: 0, width: 1440, height: 900)

    func testBallRectIsCenteredOnPoint() {
        let rect = ShelfBallBehavior.ballRect(centeredAt: CGPoint(x: 100, y: 200))

        XCTAssertEqual(rect.width, ShelfBallBehavior.ballDiameter)
        XCTAssertEqual(rect.height, ShelfBallBehavior.ballDiameter)
        XCTAssertEqual(rect.midX, 100, accuracy: 0.001)
        XCTAssertEqual(rect.midY, 200, accuracy: 0.001)
    }

    func testDefaultHomePositionSitsInBottomRightWithInset() {
        let home = ShelfBallBehavior.defaultHomePosition(in: frame)

        XCTAssertEqual(home.x, frame.maxX - ShelfBallBehavior.defaultHomeInset - ShelfBallBehavior.ballDiameter / 2, accuracy: 0.001)
        XCTAssertEqual(home.y, frame.minY + ShelfBallBehavior.defaultHomeInset + ShelfBallBehavior.ballDiameter / 2, accuracy: 0.001)
        XCTAssertTrue(frame.contains(home))
    }

    func testClampedPositionPullsOutOfBoundsPointsInside() {
        let clamped = ShelfBallBehavior.clampedPosition(CGPoint(x: -5000, y: 9000), in: frame)

        XCTAssertTrue(frame.contains(clamped))
        XCTAssertEqual(clamped.x, frame.minX + ShelfBallBehavior.clampInset, accuracy: 0.001)
        XCTAssertEqual(clamped.y, frame.maxY - ShelfBallBehavior.clampInset, accuracy: 0.001)
    }

    func testClampedPositionKeepsInteriorPoints() {
        let point = CGPoint(x: 500, y: 400)
        XCTAssertEqual(ShelfBallBehavior.clampedPosition(point, in: frame), point)
    }

    func testClampedPositionHandlesTinyFrame() {
        let tiny = NSRect(x: 0, y: 0, width: 12, height: 12)
        let clamped = ShelfBallBehavior.clampedPosition(CGPoint(x: -100, y: 100), in: tiny)

        XCTAssertTrue(tiny.contains(clamped))
    }

    func testShouldCollapseOnlyWhenFullyIdle() {
        let idle = ShelfBallBehavior.shouldCollapse(
            pointerInShelfArea: false,
            mouseButtonPressed: false,
            quickLookVisible: false,
            receivingExternalDrop: false,
            appIsActive: false
        )
        XCTAssertTrue(idle)

        let pointerOver = ShelfBallBehavior.shouldCollapse(
            pointerInShelfArea: true,
            mouseButtonPressed: false,
            quickLookVisible: false,
            receivingExternalDrop: false,
            appIsActive: false
        )
        XCTAssertFalse(pointerOver)

        let buttonDown = ShelfBallBehavior.shouldCollapse(
            pointerInShelfArea: false,
            mouseButtonPressed: true,
            quickLookVisible: false,
            receivingExternalDrop: false,
            appIsActive: false
        )
        XCTAssertFalse(buttonDown)

        let quickLookOpen = ShelfBallBehavior.shouldCollapse(
            pointerInShelfArea: false,
            mouseButtonPressed: false,
            quickLookVisible: true,
            receivingExternalDrop: false,
            appIsActive: false
        )
        XCTAssertFalse(quickLookOpen)

        let receivingDrop = ShelfBallBehavior.shouldCollapse(
            pointerInShelfArea: false,
            mouseButtonPressed: false,
            quickLookVisible: false,
            receivingExternalDrop: true,
            appIsActive: false
        )
        XCTAssertFalse(receivingDrop)

        let appActive = ShelfBallBehavior.shouldCollapse(
            pointerInShelfArea: false,
            mouseButtonPressed: false,
            quickLookVisible: false,
            receivingExternalDrop: false,
            appIsActive: true
        )
        XCTAssertFalse(appActive)
    }

    func testDragMovementThreshold() {
        XCTAssertFalse(ShelfBallBehavior.isDragMovement(from: .zero, to: CGPoint(x: 2, y: 2)))
        XCTAssertTrue(ShelfBallBehavior.isDragMovement(from: .zero, to: CGPoint(x: 4, y: 0)))
        XCTAssertTrue(ShelfBallBehavior.isDragMovement(from: .zero, to: CGPoint(x: 0, y: -4)))
    }

    func testRestMovementDetectsPointerSettling() {
        XCTAssertTrue(ShelfBallBehavior.isRestMovement(from: .zero, to: CGPoint(x: 3, y: 3)))
        XCTAssertTrue(ShelfBallBehavior.isRestMovement(from: .zero, to: .zero))
        XCTAssertFalse(ShelfBallBehavior.isRestMovement(from: .zero, to: CGPoint(x: 10, y: 0)))
        XCTAssertFalse(ShelfBallBehavior.isRestMovement(from: .zero, to: CGPoint(x: 0, y: -12)))
    }

    func testShelfFrameBloomsAboveBall() {
        let frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let ball = CGPoint(x: 400, y: 300)
        let size = NSSize(width: 270, height: 230)
        let shelf = ShelfBallBehavior.shelfFrame(nearBall: ball, size: size, in: frame)
        let ballRect = ShelfBallBehavior.ballRect(centeredAt: ball)

        XCTAssertEqual(shelf.minY, ballRect.maxY + ShelfBallBehavior.anchorGap, accuracy: 0.001)
        XCTAssertEqual(shelf.midX, ball.x, accuracy: 0.001)
    }

    func testShelfFrameFlipsBelowBallWhenNoRoomAbove() {
        let frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let ball = CGPoint(x: 400, y: 820)
        let size = NSSize(width: 270, height: 230)
        let shelf = ShelfBallBehavior.shelfFrame(nearBall: ball, size: size, in: frame)
        let ballRect = ShelfBallBehavior.ballRect(centeredAt: ball)

        XCTAssertEqual(shelf.maxY, ballRect.minY - ShelfBallBehavior.anchorGap, accuracy: 0.001)
    }

    func testShelfFrameStaysInsideScreenEdges() {
        let frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: 600, height: 500)

        let leftEdge = ShelfBallBehavior.shelfFrame(nearBall: CGPoint(x: 0, y: 450), size: size, in: frame)
        XCTAssertGreaterThanOrEqual(leftEdge.minX, frame.minX + ShelfBallBehavior.edgeGap - 0.001)
        XCTAssertLessThanOrEqual(leftEdge.maxX, frame.maxX - ShelfBallBehavior.edgeGap + 0.001)

        let topEdge = ShelfBallBehavior.shelfFrame(nearBall: CGPoint(x: 720, y: 0), size: size, in: frame)
        XCTAssertGreaterThanOrEqual(topEdge.minY, frame.minY + ShelfBallBehavior.edgeGap - 0.001)
        XCTAssertLessThanOrEqual(topEdge.maxY, frame.maxY - ShelfBallBehavior.edgeGap + 0.001)
    }
}
