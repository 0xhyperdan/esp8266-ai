import XCTest
@testable import AIClockBridge

final class AppRuntimeControllerTests: XCTestCase {
    private final class FakeActivity: RuntimeActivity {
        private(set) var startCount = 0
        private(set) var stopCount = 0
        private(set) var isRunning = false

        func start() {
            guard !isRunning else { return }
            isRunning = true
            startCount += 1
        }

        func stop() {
            guard isRunning else { return }
            isRunning = false
            stopCount += 1
        }
    }

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "AppRuntimeControllerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testSleepStopsEveryActivityAndCancelsPairing() {
        let preferences = FeaturePreferences(defaults: defaults)
        let core = FakeActivity()
        let stock = FakeActivity()
        let music = FakeActivity()
        var cancellationCount = 0
        let runtime = makeRuntime(
            preferences: preferences,
            alwaysOn: [core],
            features: ["stock": stock, "music": music],
            cancelPairing: { cancellationCount += 1 }
        )

        runtime.start()
        runtime.prepareForSleep()

        XCTAssertTrue(runtime.isSuspended)
        XCTAssertFalse(core.isRunning)
        XCTAssertFalse(stock.isRunning)
        XCTAssertFalse(music.isRunning)
        XCTAssertEqual(cancellationCount, 1)
    }

    func testFeatureChangesStartAndStopOnlyTheirMonitor() {
        let preferences = FeaturePreferences(defaults: defaults)
        preferences.setEnabled(false, for: "music")
        let core = FakeActivity()
        let stock = FakeActivity()
        let music = FakeActivity()
        let runtime = makeRuntime(
            preferences: preferences,
            alwaysOn: [core],
            features: ["stock": stock, "music": music]
        )

        runtime.start()
        XCTAssertFalse(music.isRunning)
        XCTAssertTrue(stock.isRunning)

        preferences.setEnabled(true, for: "music")
        preferences.setEnabled(false, for: "stock")
        runtime.applyFeatureConfiguration()

        XCTAssertTrue(music.isRunning)
        XCTAssertFalse(stock.isRunning)
        runtime.stop()
    }

    func testWeatherActivityAlwaysRuns() {
        let preferences = FeaturePreferences(defaults: defaults)
        preferences.setEnabled(false, for: "weather")
        let weather = FakeActivity()
        let runtime = makeRuntime(
            preferences: preferences,
            alwaysOn: [],
            features: ["weather": weather]
        )

        runtime.start()

        XCTAssertTrue(preferences.isEnabled("weather"))
        XCTAssertTrue(weather.isRunning)
        runtime.stop()
    }

    func testWakeResumesOnlyCurrentlyEnabledFeatures() {
        let preferences = FeaturePreferences(defaults: defaults)
        let core = FakeActivity()
        let music = FakeActivity()
        let stock = FakeActivity()
        let runtime = makeRuntime(
            preferences: preferences,
            alwaysOn: [core],
            features: ["music": music, "stock": stock]
        )

        runtime.start()
        runtime.prepareForSleep()
        preferences.setEnabled(false, for: "stock")
        runtime.resumeAfterWake()

        XCTAssertFalse(runtime.isSuspended)
        XCTAssertTrue(core.isRunning)
        XCTAssertTrue(music.isRunning)
        XCTAssertFalse(stock.isRunning)
        XCTAssertEqual(core.startCount, 2)
        XCTAssertEqual(stock.startCount, 1)
        runtime.stop()
    }

    private func makeRuntime(preferences: FeaturePreferences,
                             alwaysOn: [RuntimeActivity],
                             features: [String: RuntimeActivity],
                             cancelPairing: @escaping () -> Void = {}) -> AppRuntimeController {
        AppRuntimeController(
            featurePreferences: preferences,
            alwaysOnActivities: alwaysOn,
            featureActivities: features,
            notificationCenter: NotificationCenter(),
            pairingInterval: 3_600,
            wakeDelay: 0,
            pairingAction: {},
            cancelPairingAction: cancelPairing
        )
    }
}
