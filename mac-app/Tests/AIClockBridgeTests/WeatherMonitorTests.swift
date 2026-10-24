import XCTest
@testable import AIClockBridge

final class WeatherMonitorTests: XCTestCase {
    func testParsesCurrentWeatherPayload() throws {
        let data = Data("""
        {
          "current": {
            "temperature_2m": 32.6,
            "relative_humidity_2m": 56.8,
            "weather_code": 95
          }
        }
        """.utf8)

        let parsed = try XCTUnwrap(WeatherMonitor.parseWeather(data: data))

        XCTAssertEqual(parsed.temperature, 33)
        XCTAssertEqual(parsed.humidity, 57)
        XCTAssertEqual(parsed.code, 95)
        XCTAssertEqual(WeatherMonitor.condition(for: parsed.code),
                       "\u{96F7}\u{9635}\u{96E8}")
    }

    func testParsesAirQualityAndMapsGrade() throws {
        let data = Data("""
        {"current":{"us_aqi":42.4}}
        """.utf8)

        let value = try XCTUnwrap(WeatherMonitor.parseAirQuality(data: data))

        XCTAssertEqual(value, 42)
        XCTAssertEqual(WeatherMonitor.airQualityGrade(value), "\u{4F18}")
        XCTAssertEqual(WeatherMonitor.airQualityGrade(88), "\u{826F}")
    }

    func testScreenRevisionChangesWithMinuteAndWeatherRevision() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)

        let initial = WeatherMonitor.screenRevision(now: date, weatherRevision: 1)
        let nextMinute = WeatherMonitor.screenRevision(
            now: date.addingTimeInterval(60),
            weatherRevision: 1
        )
        let weatherUpdate = WeatherMonitor.screenRevision(now: date, weatherRevision: 2)

        XCTAssertNotEqual(initial, nextMinute)
        XCTAssertNotEqual(initial, weatherUpdate)
    }

    func testMapsOpenMeteoCodesToFactoryWeatherAssets() {
        XCTAssertEqual(WeatherMonitor.factoryWeatherIconIndex(for: 0), 0)
        XCTAssertEqual(WeatherMonitor.factoryWeatherIconIndex(for: 1), 1)
        XCTAssertEqual(WeatherMonitor.factoryWeatherIconIndex(for: 3), 2)
        XCTAssertEqual(WeatherMonitor.factoryWeatherIconIndex(for: 63), 3)
        XCTAssertEqual(WeatherMonitor.factoryWeatherIconIndex(for: 95), 4)
        XCTAssertEqual(WeatherMonitor.factoryWeatherIconIndex(for: 75), 5)
        XCTAssertEqual(WeatherMonitor.factoryWeatherIconIndex(for: 45), 7)
    }

    func testPackagesCompleteFactoryWeatherAssetSet() {
        XCTAssertTrue(WeatherMonitor.factoryAssetsAvailable)
    }

    func testRendersExactDeviceSizedRGB565Frame() {
        let monitor = WeatherMonitor()

        XCTAssertEqual(monitor.screenRGB565().count, 240 * 240 * 2)
        XCTAssertNotNil(monitor.screenImage())
    }

    func testDeviceFrameOmitsSecondsAndStaysStableWithinMinute() throws {
        let monitor = WeatherMonitor()
        let epoch = 1_800_000_000
        let minuteStart = Date(timeIntervalSince1970: Double(epoch - epoch % 60))
        let laterInMinute = minuteStart.addingTimeInterval(42)
        let nextMinute = minuteStart.addingTimeInterval(60)

        let earlyDeviceFrame = monitor.screenRGB565(now: minuteStart)
        let laterDeviceFrame = monitor.screenRGB565(now: laterInMinute)
        XCTAssertEqual(earlyDeviceFrame, laterDeviceFrame)
        assertRGB565SecondsAreaIsBlack(earlyDeviceFrame)
        XCTAssertNotEqual(earlyDeviceFrame, monitor.screenRGB565(now: nextMinute))

        let earlyWired = try XCTUnwrap(monitor.wiredScreenSnapshot(now: minuteStart))
        let laterWired = try XCTUnwrap(
            monitor.wiredScreenSnapshot(now: laterInMinute)
        )
        let nextMinuteWired = try XCTUnwrap(
            monitor.wiredScreenSnapshot(now: nextMinute)
        )
        XCTAssertEqual(earlyWired.revision, laterWired.revision)
        XCTAssertEqual(earlyWired.encoded, laterWired.encoded)
        XCTAssertNotEqual(earlyWired.revision, nextMinuteWired.revision)
        XCTAssertNotEqual(earlyWired.encoded, nextMinuteWired.encoded)

        // The Mac preview keeps its local seconds rendering. A 1.2-second gap
        // also lands on the same astronaut frame, isolating the second change.
        let earlyPreview = try XCTUnwrap(monitor.screenImage(now: minuteStart))
        let laterPreview = try XCTUnwrap(
            monitor.screenImage(now: minuteStart.addingTimeInterval(1.2))
        )
        let earlyTIFF = try XCTUnwrap(earlyPreview.tiffRepresentation)
        let laterTIFF = try XCTUnwrap(laterPreview.tiffRepresentation)
        XCTAssertNotEqual(earlyTIFF, laterTIFF)
    }

    func testBuildsFactoryAstronautFramePack() {
        let data = WeatherMonitor().astronautRGB565()

        XCTAssertEqual(
            data.count,
            2 + WeatherMonitor.astronautFrameCount
                * WeatherMonitor.astronautWidth
                * WeatherMonitor.astronautHeight
                * 2
        )
        XCTAssertEqual(data.first, UInt8(WeatherMonitor.astronautAssetRevision))
        XCTAssertEqual(data[data.startIndex + 1], UInt8(WeatherMonitor.astronautFrameCount))
    }

    func testRGB565PackBitsRoundTripsRunsAndLiterals() throws {
        let pixels: [UInt8] = [
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x12, 0x34, 0x56, 0x78,
            0xAB, 0xCD, 0xAB, 0xCD, 0xAB, 0xCD, 0xAB, 0xCD,
        ]
        let input = Data(pixels)
        let encoded = WeatherMonitor.encodeRGB565PackBits(input)

        XCTAssertEqual(try decodeRGB565PackBits(encoded), input)
        XCTAssertLessThan(encoded.count, input.count)
    }

    func testBuildsCompressedWiredWeatherAssets() throws {
        let monitor = WeatherMonitor()
        let screen = try XCTUnwrap(monitor.wiredScreenSnapshot())
        let astronaut = try XCTUnwrap(monitor.wiredAstronautSnapshot())

        XCTAssertEqual(screen.decodedSize, 240 * 240 * 2)
        XCTAssertEqual(try decodeRGB565PackBits(screen.encoded).count, screen.decodedSize)
        XCTAssertLessThan(screen.encoded.count, screen.decodedSize)

        XCTAssertEqual(astronaut.revision, WeatherMonitor.astronautAssetRevision)
        XCTAssertEqual(astronaut.frames, WeatherMonitor.astronautFrameCount)
        XCTAssertEqual(
            try decodeRGB565PackBits(astronaut.encoded).count,
            astronaut.decodedSize - 2
        )
        XCTAssertLessThan(astronaut.encoded.count, astronaut.decodedSize - 2)
    }

    func testClockColonAndAstronautCadenceMatchVisualTuning() {
        XCTAssertEqual(WeatherMonitor.clockColonLeft, 88)
        XCTAssertEqual(WeatherMonitor.clockColonTop, 69)
        XCTAssertEqual(WeatherMonitor.astronautFrameIntervalMilliseconds, 30)
    }

    private func decodeRGB565PackBits(_ encoded: Data) throws -> Data {
        enum DecodeError: Error { case truncated }
        let bytes = Array(encoded)
        var output = Data()
        var index = 0
        while index < bytes.count {
            let control = bytes[index]
            index += 1
            let count = Int(control & 0x7F) + 1
            if control & 0x80 != 0 {
                guard index + 1 < bytes.count else { throw DecodeError.truncated }
                let pixel = [bytes[index], bytes[index + 1]]
                index += 2
                for _ in 0..<count { output.append(contentsOf: pixel) }
            } else {
                let byteCount = count * 2
                guard index + byteCount <= bytes.count else { throw DecodeError.truncated }
                output.append(contentsOf: bytes[index..<(index + byteCount)])
                index += byteCount
            }
        }
        return output
    }

    private func assertRGB565SecondsAreaIsBlack(_ frame: Data) {
        for y in 90..<153 {
            for x in 196..<240 {
                let offset = (y * 240 + x) * 2
                XCTAssertEqual(frame[frame.startIndex + offset], 0)
                XCTAssertEqual(frame[frame.startIndex + offset + 1], 0)
            }
        }
    }
}
