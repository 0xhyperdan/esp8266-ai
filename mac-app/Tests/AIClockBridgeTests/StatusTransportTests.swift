import XCTest
@testable import AIClockBridge

final class StatusTransportTests: XCTestCase {
    func testDeviceCanRequestSameMinuteWeatherFrameWithoutInterruptingUpload() {
        XCTAssertEqual(SerialLink.weatherScreenRevision(
            afterDeviceLine: "#WEATHER_SCREEN_NEEDED", current: 42,
            uploadInProgress: false), -1)
        XCTAssertEqual(SerialLink.weatherScreenRevision(
            afterDeviceLine: "#WEATHER_SCREEN_NEEDED", current: 42,
            uploadInProgress: true), 42)
        XCTAssertEqual(SerialLink.weatherScreenRevision(
            afterDeviceLine: "#WEATHER_ASSET_ACK 0", current: 42,
            uploadInProgress: false), 42)
    }

    func testStatusEnvelopeContainsOnlyHeartbeatFields() throws {
        let envelope = StatusEnvelope(timestamp: 1_800_000_000, musicPlaying: true)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: envelope.jsonData()) as? [String: Any]
        )

        XCTAssertEqual(object["ts"] as? Int, 1_800_000_000)
        XCTAssertEqual(object["music_playing"] as? Bool, true)
        XCTAssertEqual(Set(object.keys), ["ts", "music_playing"])
    }

    func testUSBStatusFrameRetainsLineProtocol() throws {
        let frame = SerialLink.statusFrame(
            StatusEnvelope(timestamp: 1_800_000_001, musicPlaying: false)
        )
        let text = try XCTUnwrap(String(data: frame, encoding: .utf8))

        XCTAssertTrue(text.hasPrefix("#STATUS "))
        XCTAssertTrue(text.hasSuffix("\n"))
        XCTAssertFalse(text.contains("active_tasks"))
        XCTAssertFalse(text.contains("state"))
        XCTAssertFalse(text.contains("windows"))
    }
}
