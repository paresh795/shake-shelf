import Foundation

public struct ShakeShelfSettings: Equatable, Sendable {
    public var sensitivity: ShakeSensitivity
    public var launchAtLogin: Bool
    public var persistItemsAcrossRelaunch: Bool
    public var collapseToBallEnabled: Bool

    public init(
        sensitivity: ShakeSensitivity = .medium,
        launchAtLogin: Bool = false,
        persistItemsAcrossRelaunch: Bool = false,
        collapseToBallEnabled: Bool = true
    ) {
        self.sensitivity = sensitivity
        self.launchAtLogin = launchAtLogin
        self.persistItemsAcrossRelaunch = persistItemsAcrossRelaunch
        self.collapseToBallEnabled = collapseToBallEnabled
    }

    private enum Key {
        static let sensitivity = "shakeSensitivity"
        static let launchAtLogin = "launchAtLogin"
        static let persistItemsAcrossRelaunch = "persistItemsAcrossRelaunch"
        static let collapseToBallEnabled = "collapseToBallEnabled"
    }

    public static func load(from defaults: UserDefaults = .standard) -> ShakeShelfSettings {
        let rawSensitivity = defaults.string(forKey: Key.sensitivity)
        let sensitivity = rawSensitivity.flatMap(ShakeSensitivity.init(rawValue:)) ?? .medium

        return ShakeShelfSettings(
            sensitivity: sensitivity,
            launchAtLogin: defaults.bool(forKey: Key.launchAtLogin),
            persistItemsAcrossRelaunch: defaults.bool(forKey: Key.persistItemsAcrossRelaunch),
            collapseToBallEnabled: defaults.object(forKey: Key.collapseToBallEnabled) as? Bool ?? true
        )
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(sensitivity.rawValue, forKey: Key.sensitivity)
        defaults.set(launchAtLogin, forKey: Key.launchAtLogin)
        defaults.set(persistItemsAcrossRelaunch, forKey: Key.persistItemsAcrossRelaunch)
        defaults.set(collapseToBallEnabled, forKey: Key.collapseToBallEnabled)
    }
}
