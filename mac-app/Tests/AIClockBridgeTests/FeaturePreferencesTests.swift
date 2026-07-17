import XCTest
@testable import AIClockBridge

final class FeaturePreferencesTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "FeaturePreferencesTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testAllOptionalFeaturesAreEnabledByDefault() {
        let preferences = FeaturePreferences(defaults: defaults)

        XCTAssertEqual(preferences.enabledOptionalModes, ["net", "music", "stock", "pomodoro"])
        XCTAssertEqual(DisplayModeDescriptor.selectableModes(
            enabledOptionalModes: preferences.enabledOptionalModes
        ), ["auto", "claude", "codex", "net", "music", "stock", "pomodoro"])
    }

    func testDisabledFeaturePersistsAndIsRemovedFromSelectableModes() {
        let preferences = FeaturePreferences(defaults: defaults)

        preferences.setEnabled(false, for: "net")

        XCTAssertFalse(preferences.isEnabled("net"))
        XCTAssertEqual(preferences.enabledOptionalModes, ["music", "stock", "pomodoro"])
        XCTAssertEqual(DisplayModeDescriptor.selectableModes(
            enabledOptionalModes: preferences.enabledOptionalModes
        ), ["auto", "claude", "codex", "music", "stock", "pomodoro"])
    }

    func testStoredModesAreNormalizedToCatalogOrder() {
        defaults.set(["pomodoro", "unknown", "music"],
                     forKey: FeaturePreferences.storageKey)
        let preferences = FeaturePreferences(defaults: defaults)

        XCTAssertEqual(preferences.enabledOptionalModes, ["music", "pomodoro"])
        XCTAssertTrue(preferences.isEnabled("claude"))
    }
}
