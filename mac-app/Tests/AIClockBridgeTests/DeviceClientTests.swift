import XCTest
@testable import AIClockBridge

final class DeviceClientTests: XCTestCase {
    private var originalHost = ""

    override func setUp() {
        super.setUp()
        originalHost = DeviceClient.host
        DeviceClient.host = ""
    }

    override func tearDown() {
        DeviceClient.wiredCommandHandler = nil
        DeviceClient.wiredInfoProvider = nil
        DeviceClient.host = originalHost
        super.tearDown()
    }

    func testFetchInfoPrefersWiredDevice() {
        var wired = DeviceInfo()
        wired.ip = "/dev/cu.usbserial-test"
        wired.ssid = "USB"
        wired.bridge = "USB serial"
        DeviceClient.wiredInfoProvider = { wired }

        let completed = expectation(description: "wired device info returned")
        DeviceClient.fetchInfo { result in
            guard case let .success(info) = result else {
                XCTFail("Expected wired device info")
                completed.fulfill()
                return
            }
            XCTAssertEqual(info.ip, "/dev/cu.usbserial-test")
            XCTAssertEqual(info.ssid, "USB")
            XCTAssertEqual(info.bridge, "USB serial")
            completed.fulfill()
        }
        wait(for: [completed], timeout: 1)
    }

    func testStockNamesPayloadValidation() {
        let oneRow = Data(count: StockMonitor.nameW * StockMonitor.nameH * 2)
        var valid = Data([1])
        valid.append(oneRow)
        XCTAssertTrue(SerialLink.isValidStockNamesPayload(valid))

        XCTAssertFalse(SerialLink.isValidStockNamesPayload(Data([0])))
        XCTAssertFalse(SerialLink.isValidStockNamesPayload(Data([1])))
        XCTAssertFalse(SerialLink.isValidStockNamesPayload(Data([5])))

        var fiveRows = Data([5])
        fiveRows.append(Data(count: 5 * StockMonitor.nameW * StockMonitor.nameH * 2))
        XCTAssertTrue(SerialLink.isValidStockNamesPayload(fiveRows))
        XCTAssertFalse(SerialLink.isValidStockNamesPayload(Data([6])))
    }

    func testSalaryControlUsesWiredTransport() {
        let completed = expectation(description: "wired salary command completed")
        DeviceClient.wiredCommandHandler = { command in
            guard let salary = command["salary"] as? [String: Any] else {
                XCTFail("expected a salary payload object")
                return false
            }
            XCTAssertEqual(salary["monthly_fen"] as? Int, 250000)
            XCTAssertEqual(salary["start_min"] as? Int, 540)
            XCTAssertEqual(salary["end_min"] as? Int, 1110)
            XCTAssertEqual(salary["lunch_start_min"] as? Int, 720)
            XCTAssertEqual(salary["lunch_end_min"] as? Int, 780)
            return true
        }
        DeviceClient.configureSalary(monthlyYuan: 2500, startMin: 540, endMin: 1110,
                                     lunchStartMin: 720, lunchEndMin: 780) { error in
            XCTAssertNil(error)
            completed.fulfill()
        }
        wait(for: [completed], timeout: 1)
    }

    func testAutoRotateControlUsesWiredTransport() {
        let completed = expectation(description: "wired auto-rotation command completed")
        DeviceClient.wiredCommandHandler = { command in
            XCTAssertEqual(command["auto_rotate"] as? Bool, false)
            return true
        }
        DeviceClient.setAutoRotate(false) { error in
            XCTAssertNil(error)
            completed.fulfill()
        }
        wait(for: [completed], timeout: 1)
    }

    func testBridgeRepairDetectsAddressChangeEvenWithFreshUSBStatus() {
        XCTAssertTrue(DeviceClient.bridgeNeedsRepair(
            current: "192.168.2.154:8765",
            expected: "192.168.2.141:8765",
            lastUpdateS: 2
        ))
    }

    func testBridgeRepairSkipsMatchingFreshAddress() {
        XCTAssertFalse(DeviceClient.bridgeNeedsRepair(
            current: "192.168.2.141:8765",
            expected: "192.168.2.141:8765",
            lastUpdateS: 2
        ))
    }

    func testBridgeRepairRetriesMatchingStaleAddress() {
        XCTAssertTrue(DeviceClient.bridgeNeedsRepair(
            current: "192.168.2.141:8765",
            expected: "192.168.2.141:8765",
            lastUpdateS: 61
        ))
    }

    func testDecodeInfoIncludesFirmwareAndOTA() throws {
        let data = Data("""
        {"board":"waveshare-esp32-s3-touch-lcd-1.54","ip":"192.168.1.50",
         "mode":"weather","fw":"0.7.1-s3","ota":true,
         "orientation":{"supported":true,"auto":true,"rotation":2},
         "battery":{"supported":true,"present":true,"charging":true,
                    "level":76,"voltage_mv":3940},
         "weather_animation":{"revision":3,"frames":20}}
        """.utf8)
        let info = try XCTUnwrap(DeviceClient.decodeInfo(data))
        XCTAssertEqual(info.board, "waveshare-esp32-s3-touch-lcd-1.54")
        XCTAssertEqual(info.firmwareVersion, "0.7.1-s3")
        XCTAssertEqual(info.mode, "weather")
        XCTAssertTrue(info.otaAvailable)
        XCTAssertTrue(info.autoRotateSupported)
        XCTAssertTrue(info.autoRotateEnabled)
        XCTAssertEqual(info.screenRotation, 2)
        XCTAssertTrue(info.batterySupported)
        XCTAssertTrue(info.batteryPresent)
        XCTAssertTrue(info.batteryCharging)
        XCTAssertEqual(info.batteryLevel, 76)
        XCTAssertEqual(info.batteryVoltageMv, 3940)
        XCTAssertEqual(info.weatherAnimationRevision, 3)
        XCTAssertEqual(info.weatherAnimationFrames, 20)
    }

    func testDecodeInfoMigratesLegacyModesToWeather() throws {
        let data = Data("""
        {"ip":"192.168.1.50","mode":"codex","effective":"auto"}
        """.utf8)
        let info = try XCTUnwrap(DeviceClient.decodeInfo(data))

        XCTAssertEqual(info.mode, "weather")
        XCTAssertEqual(info.effective, "weather")
    }

    func testClockDiscoveryUsesMinimalIdentityFields() {
        XCTAssertTrue(DeviceClient.isClockInfo(["mode": "weather", "fw": "1.0.0"]))
        XCTAssertFalse(DeviceClient.isClockInfo(["mode": "weather"]))
        XCTAssertFalse(DeviceClient.isClockInfo(["fw": "1.0.0"]))
    }

    func testFirmwareImageValidation() {
        var valid = Data(repeating: 0, count: 4096)
        valid[0] = 0xE9
        XCTAssertTrue(DeviceClient.isValidFirmwareImage(valid))
        XCTAssertFalse(DeviceClient.isValidFirmwareImage(Data(repeating: 0, count: 4096)))
        XCTAssertFalse(DeviceClient.isValidFirmwareImage(Data([0xE9])))
    }

    func testFirmwareImageValidationRejectsWrongChipFamily() {
        var esp32S3 = Data(repeating: 0, count: 4096)
        esp32S3[0] = 0xE9
        esp32S3[12] = 9
        XCTAssertTrue(DeviceClient.isValidFirmwareImage(
            esp32S3,
            boardID: "waveshare-esp32-s3-touch-lcd-1.54"
        ))
        XCTAssertFalse(DeviceClient.isValidFirmwareImage(
            esp32S3,
            boardID: "esp8266-fubotv-sd2"
        ))

        var esp8266 = Data(repeating: 0, count: 4096)
        esp8266[0] = 0xE9
        XCTAssertTrue(DeviceClient.isValidFirmwareImage(
            esp8266,
            boardID: "esp8266-fubotv-sd2"
        ))
        XCTAssertFalse(DeviceClient.isValidFirmwareImage(
            esp8266,
            boardID: "waveshare-esp32-s3-touch-lcd-1.54"
        ))
    }

    func testSerialPortDiscoveryIncludesNativeUSB() {
        XCTAssertTrue(SerialLink.isSupportedSerialPortName("cu.usbserial-110"))
        XCTAssertTrue(SerialLink.isSupportedSerialPortName("cu.wchusbserial110"))
        XCTAssertTrue(SerialLink.isSupportedSerialPortName("cu.usbmodem21201"))
        XCTAssertFalse(SerialLink.isSupportedSerialPortName("cu.Bluetooth-Incoming-Port"))
    }

    func testFirmwareAuthorizationAndMultipartBody() {
        let credentials = OTACredentials(username: "admin", password: "secret")
        XCTAssertEqual(DeviceClient.basicAuthorizationHeader(credentials), "Basic YWRtaW46c2VjcmV0")
        let firmware = Data([0xE9, 0x01, 0x02])
        let body = DeviceClient.firmwareMultipartBody(firmware, boundary: "test-boundary")
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"firmware\"; filename=\"firmware.bin\""))
        XCTAssertTrue(text.hasSuffix("\r\n--test-boundary--\r\n"))
        XCTAssertNotNil(body.range(of: firmware))
    }
}
