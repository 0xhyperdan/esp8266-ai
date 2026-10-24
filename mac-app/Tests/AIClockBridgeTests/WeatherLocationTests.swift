import Foundation
import XCTest
@testable import AIClockBridge

final class WeatherLocationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "WeatherLocationTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testDefaultsToAutomaticModeWithNanjingFallback() {
        let configuration = WeatherLocationStore(defaults: defaults).configuration

        XCTAssertEqual(configuration.mode, .automatic)
        XCTAssertEqual(configuration.location, .fallback)
    }

    func testPersistsManualLocationAndTimeZone() {
        let store = WeatherLocationStore(defaults: defaults)
        let location = WeatherLocation(
            city: "\u{4E0A}\u{6D77}",
            latitude: 31.2304,
            longitude: 121.4737,
            timeZoneIdentifier: "Asia/Shanghai"
        )

        store.save(mode: .manual, location: location)

        XCTAssertEqual(store.configuration.mode, .manual)
        XCTAssertEqual(store.configuration.location, location)
    }

    func testNormalizesMunicipalitySuffix() {
        XCTAssertEqual(
            SystemWeatherLocationResolver.normalizedCity(
                "\u{5317}\u{4EAC}\u{5E02}"
            ),
            "\u{5317}\u{4EAC}"
        )
        XCTAssertEqual(
            SystemWeatherLocationResolver.normalizedCity(
                "\u{9999}\u{6E2F}\u{7279}\u{522B}\u{884C}\u{653F}\u{533A}"
            ),
            "\u{9999}\u{6E2F}"
        )
    }

    func testWeatherURLUsesConfiguredCoordinatesAndAutomaticTimeZone() throws {
        let location = WeatherLocation(
            city: "\u{4E0A}\u{6D77}",
            latitude: 31.2304,
            longitude: 121.4737,
            timeZoneIdentifier: "Asia/Shanghai"
        )
        let url = try XCTUnwrap(WeatherMonitor.weatherURL(for: location))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues:
            (components.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            }
        )

        XCTAssertEqual(query["latitude"], "31.2304")
        XCTAssertEqual(query["longitude"], "121.4737")
        XCTAssertEqual(query["timezone"], "auto")
    }

    func testManualCityUpdatesMonitorAndStore() {
        let store = WeatherLocationStore(defaults: defaults)
        let resolver = StubWeatherLocationResolver()
        let expected = WeatherLocation(
            city: "\u{82CF}\u{5DDE}",
            latitude: 31.2989,
            longitude: 120.5853,
            timeZoneIdentifier: "Asia/Shanghai"
        )
        resolver.cityResult = .success(expected)
        let monitor = WeatherMonitor(locationStore: store, locationResolver: resolver)
        let completed = expectation(description: "manual city resolved")

        monitor.setManualCity("\u{82CF}\u{5DDE}") { result in
            XCTAssertEqual(try? result.get(), expected)
            completed.fulfill()
        }

        wait(for: [completed], timeout: 1)
        XCTAssertEqual(store.configuration.mode, .manual)
        XCTAssertEqual(store.configuration.location, expected)
        XCTAssertEqual(monitor.snapshot.city, expected.city)
    }
}

private final class StubWeatherLocationResolver: WeatherLocationResolving {
    var automaticResult: Result<WeatherLocation, Error> =
        .failure(WeatherLocationError.locationUnavailable)
    var cityResult: Result<WeatherLocation, Error> =
        .failure(WeatherLocationError.cityNotFound)

    func resolveAutomatic(completion: @escaping (Result<WeatherLocation, Error>) -> Void) {
        completion(automaticResult)
    }

    func resolveCity(_ city: String,
                     completion: @escaping (Result<WeatherLocation, Error>) -> Void) {
        completion(cityResult)
    }
}
