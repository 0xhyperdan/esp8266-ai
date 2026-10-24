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

        XCTAssertEqual(DisplayModeDescriptor.configurable.map(\.mode),
                       ["music", "stock", "salary"])
        XCTAssertEqual(preferences.enabledOptionalModes,
                       ["music", "stock", "salary"])
        XCTAssertEqual(DisplayModeDescriptor.selectableModes(
            enabledOptionalModes: preferences.enabledOptionalModes
        ), ["weather", "music", "stock", "salary"])
    }

    func testDisabledFeaturePersistsAndIsRemovedFromSelectableModes() {
        let preferences = FeaturePreferences(defaults: defaults)

        preferences.setEnabled(false, for: "music")

        XCTAssertFalse(preferences.isEnabled("music"))
        XCTAssertEqual(preferences.enabledOptionalModes, ["stock", "salary"])
        XCTAssertEqual(DisplayModeDescriptor.selectableModes(
            enabledOptionalModes: preferences.enabledOptionalModes
        ), ["weather", "stock", "salary"])
    }

    func testStoredModesAreNormalizedToCatalogOrder() {
        defaults.set(["pomodoro", "unknown", "music"],
                     forKey: FeaturePreferences.storageKey)
        defaults.set(FeaturePreferences.currentCatalogVersion,
                     forKey: FeaturePreferences.catalogVersionKey)
        let preferences = FeaturePreferences(defaults: defaults)

        XCTAssertEqual(preferences.enabledOptionalModes, ["music"])
        XCTAssertTrue(preferences.isEnabled("weather"))
        XCTAssertEqual(DisplayModeDescriptor.normalizedMode("weather"), "weather")
    }

    func testRemovedNetworkPreferenceIsDiscardedWithoutEnablingOtherFeatures() {
        defaults.set(["net", "stock"], forKey: FeaturePreferences.storageKey)
        defaults.set(5, forKey: FeaturePreferences.catalogVersionKey)
        let preferences = FeaturePreferences(defaults: defaults)

        XCTAssertEqual(preferences.enabledOptionalModes, ["stock"])
        XCTAssertEqual(defaults.array(forKey: FeaturePreferences.storageKey) as? [String], ["stock"])
        XCTAssertEqual(DisplayModeDescriptor.normalizedMode("net"), "weather")
        XCTAssertEqual(defaults.integer(forKey: FeaturePreferences.catalogVersionKey), 7)
    }

    func testWeatherIsAlwaysSelectableAndCannotBeDisabled() {
        defaults.set(["weather", "music", "stock"], forKey: FeaturePreferences.storageKey)
        defaults.set(2, forKey: FeaturePreferences.catalogVersionKey)
        let preferences = FeaturePreferences(defaults: defaults)

        XCTAssertEqual(preferences.enabledOptionalModes, ["music", "stock"])
        XCTAssertTrue(preferences.isEnabled("weather"))

        preferences.setEnabled(false, for: "weather")
        XCTAssertEqual(preferences.enabledOptionalModes, ["music", "stock"])
        XCTAssertEqual(DisplayModeDescriptor.selectableModes(
            enabledOptionalModes: preferences.enabledOptionalModes
        ), ["weather", "music", "stock"])
        XCTAssertEqual(defaults.integer(forKey: FeaturePreferences.catalogVersionKey), 7)
    }

    func testLegacyAndUnknownModesMigrateToWeather() {
        for mode in ["auto", "claude", "codex", "home", "usage", "info", "net", "unknown"] {
            XCTAssertEqual(DisplayModeDescriptor.normalizedMode(mode), "weather")
        }

        XCTAssertEqual(DisplayModeDescriptor.normalizedMode("music"), "music")
        XCTAssertEqual(DisplayModeDescriptor.normalizedMode("stock"), "stock")
        XCTAssertEqual(DisplayModeDescriptor.normalizedMode("pomodoro"), "weather")
        XCTAssertEqual(DisplayModeDescriptor.normalizedMode("salary"), "salary")
    }
}
