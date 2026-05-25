import Foundation

public struct DragShakeSample: Sendable {
    public let time: TimeInterval
    public let x: Double

    public init(time: TimeInterval, x: Double) {
        self.time = time
        self.x = x
    }
}

public struct DragShakeRecognizer: Sendable {
    public var window: TimeInterval
    public var minimumReversals: Int
    public var minimumTravelPerLeg: Double
    public var cooldown: TimeInterval

    private var samples: [DragShakeSample]
    private var lastShakeTime: TimeInterval

    public init(
        window: TimeInterval = 0.45,
        minimumReversals: Int = 4,
        minimumTravelPerLeg: Double = 12,
        cooldown: TimeInterval = 0.8
    ) {
        self.window = window
        self.minimumReversals = minimumReversals
        self.minimumTravelPerLeg = minimumTravelPerLeg
        self.cooldown = cooldown
        self.samples = []
        self.lastShakeTime = -.infinity
    }

    public mutating func reset() {
        samples.removeAll()
    }

    public mutating func ingest(_ sample: DragShakeSample) -> Bool {
        samples.append(sample)
        samples.removeAll { sample.time - $0.time > window }

        guard sample.time - lastShakeTime > cooldown else { return false }
        guard detectShake() else { return false }

        lastShakeTime = sample.time
        samples.removeAll()
        return true
    }

    private func detectShake() -> Bool {
        guard samples.count >= 4 else { return false }

        var reversals = 0
        var legTravel = 0.0
        var lastDirection = 0

        for index in 1..<samples.count {
            let dx = samples[index].x - samples[index - 1].x
            let direction = dx > 0.5 ? 1 : (dx < -0.5 ? -1 : 0)
            if direction == 0 { continue }

            if direction == lastDirection {
                legTravel += abs(dx)
            } else {
                if lastDirection != 0, legTravel >= minimumTravelPerLeg {
                    reversals += 1
                }

                legTravel = abs(dx)
                lastDirection = direction
            }
        }

        return reversals >= minimumReversals
    }
}
