import Foundation

public struct DragShakeSample: Sendable {
    public let time: TimeInterval
    public let x: Double

    public init(time: TimeInterval, x: Double) {
        self.time = time
        self.x = x
    }
}

public enum ShakeSensitivity: String, Sendable, CaseIterable {
    case low
    case medium
    case high

    public var configuration: DragShakeConfiguration {
        switch self {
        case .low:
            return DragShakeConfiguration(
                window: 0.55,
                minimumReversals: 5,
                minimumTravelPerLeg: 16,
                cooldown: 0.9
            )
        case .medium:
            return DragShakeConfiguration(
                window: 0.45,
                minimumReversals: 4,
                minimumTravelPerLeg: 12,
                cooldown: 0.8
            )
        case .high:
            return DragShakeConfiguration(
                window: 0.38,
                minimumReversals: 3,
                minimumTravelPerLeg: 8,
                cooldown: 0.7
            )
        }
    }

    public var displayName: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }
}

public struct DragShakeConfiguration: Sendable, Equatable {
    public var window: TimeInterval
    public var minimumReversals: Int
    public var minimumTravelPerLeg: Double
    public var cooldown: TimeInterval

    public init(
        window: TimeInterval,
        minimumReversals: Int,
        minimumTravelPerLeg: Double,
        cooldown: TimeInterval
    ) {
        self.window = window
        self.minimumReversals = minimumReversals
        self.minimumTravelPerLeg = minimumTravelPerLeg
        self.cooldown = cooldown
    }

    public static let standard = ShakeSensitivity.medium.configuration
}

public struct DragShakeRecognizer: Sendable {
    public var configuration: DragShakeConfiguration

    private var samples: [DragShakeSample]
    private var lastShakeTime: TimeInterval

    public init(configuration: DragShakeConfiguration = .standard) {
        self.configuration = configuration
        self.samples = []
        self.lastShakeTime = -.infinity
    }

    public init(sensitivity: ShakeSensitivity) {
        self.init(configuration: sensitivity.configuration)
    }

    public mutating func reset() {
        samples.removeAll()
    }

    public mutating func ingest(_ sample: DragShakeSample) -> Bool {
        samples.append(sample)
        samples.removeAll { sample.time - $0.time > configuration.window }

        guard sample.time - lastShakeTime > configuration.cooldown else { return false }
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
                if lastDirection != 0, legTravel >= configuration.minimumTravelPerLeg {
                    reversals += 1
                }

                legTravel = abs(dx)
                lastDirection = direction
            }
        }

        return reversals >= configuration.minimumReversals
    }
}
