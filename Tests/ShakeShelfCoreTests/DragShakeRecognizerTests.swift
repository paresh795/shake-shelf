import ShakeShelfCore
import XCTest

final class DragShakeRecognizerTests: XCTestCase {
    func testRecognizesFastDraggedBackAndForthMotion() {
        var recognizer = DragShakeRecognizer(
            window: 0.45,
            minimumReversals: 4,
            minimumTravelPerLeg: 12,
            cooldown: 0.8
        )

        let xs = [100, 122, 96, 124, 94, 126, 92]
        let results = xs.enumerated().map { index, x in
            recognizer.ingest(DragShakeSample(time: Double(index) * 0.06, x: Double(x)))
        }

        XCTAssertTrue(results.contains(true))
    }

    func testIgnoresSlowDrift() {
        var recognizer = DragShakeRecognizer()

        let xs = [100, 105, 110, 116, 121, 127, 132]
        let results = xs.enumerated().map { index, x in
            recognizer.ingest(DragShakeSample(time: Double(index) * 0.08, x: Double(x)))
        }

        XCTAssertFalse(results.contains(true))
    }

    func testResetsOnMouseUp() {
        var recognizer = DragShakeRecognizer()

        _ = recognizer.ingest(DragShakeSample(time: 0.00, x: 100))
        _ = recognizer.ingest(DragShakeSample(time: 0.05, x: 126))
        recognizer.reset()

        XCTAssertFalse(recognizer.ingest(DragShakeSample(time: 0.10, x: 90)))
    }
}
