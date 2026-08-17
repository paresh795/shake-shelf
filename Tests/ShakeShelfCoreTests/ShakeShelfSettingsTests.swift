import Foundation
import ShakeShelfCore
import XCTest

final class ShakeShelfSettingsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ShakeShelfSettingsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testLoadsDefaultsWhenNothingStored() {
        let settings = ShakeShelfSettings.load(from: defaults)
        XCTAssertEqual(settings.sensitivity, .medium)
        XCTAssertFalse(settings.launchAtLogin)
        XCTAssertFalse(settings.persistItemsAcrossRelaunch)
        XCTAssertTrue(settings.collapseToBallEnabled)
    }

    func testSaveAndLoadRoundTrip() {
        var settings = ShakeShelfSettings()
        settings.sensitivity = .high
        settings.launchAtLogin = true
        settings.persistItemsAcrossRelaunch = true
        settings.collapseToBallEnabled = false
        settings.save(to: defaults)

        let loaded = ShakeShelfSettings.load(from: defaults)
        XCTAssertEqual(loaded, settings)
    }

    func testUnknownSensitivityFallsBackToMedium() {
        defaults.set("extreme", forKey: "shakeSensitivity")
        defaults.set(true, forKey: "persistItemsAcrossRelaunch")

        let loaded = ShakeShelfSettings.load(from: defaults)
        XCTAssertEqual(loaded.sensitivity, .medium)
        XCTAssertTrue(loaded.persistItemsAcrossRelaunch)
    }
}
