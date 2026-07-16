import XCTest
@testable import AIClockBridge

final class DeviceClientTests: XCTestCase {
    override func tearDown() {
        DeviceClient.wiredInfoProvider = nil
        DeviceClient.wiredPetUploadHandler = nil
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

    func testUploadGifPrefersWiredTransport() {
        let gif = Data([0x47, 0x49, 0x46])
        let completed = expectation(description: "wired pet upload completed")
        DeviceClient.wiredPetUploadHandler = { data, slot, completion in
            XCTAssertEqual(data, gif)
            XCTAssertEqual(slot, "claude")
            completion(nil)
            return true
        }

        DeviceClient.uploadGif(gif, slot: "claude") { error in
            XCTAssertNil(error)
            completed.fulfill()
        }

        wait(for: [completed], timeout: 1)
    }

    func testPetUploadCrc32MatchesStandardVector() {
        XCTAssertEqual(SerialLink.crc32(Data("123456789".utf8)), 0xCBF4_3926)
    }

    func testDecodeInfoIncludesFirmwareAndOTA() throws {
        let data = Data("""
        {"ip":"192.168.1.50","mode":"auto","fw":"0.5.3","ota":true,
         "sprite_upload":{"state":"processing","slot":"codex","error":""},
         "claude":{"custom_sprite":false},"codex":{"custom_sprite":true}}
        """.utf8)
        let info = try XCTUnwrap(DeviceClient.decodeInfo(data))
        XCTAssertEqual(info.firmwareVersion, "0.5.3")
        XCTAssertTrue(info.otaAvailable)
        XCTAssertEqual(info.spriteUploadState, "processing")
        XCTAssertEqual(info.spriteUploadSlot, "codex")
        XCTAssertTrue(info.codexCustomSprite)
    }

    func testFirmwareImageValidation() {
        var valid = Data(repeating: 0, count: 4096)
        valid[0] = 0xE9
        XCTAssertTrue(DeviceClient.isValidFirmwareImage(valid))
        XCTAssertFalse(DeviceClient.isValidFirmwareImage(Data(repeating: 0, count: 4096)))
        XCTAssertFalse(DeviceClient.isValidFirmwareImage(Data([0xE9])))
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
