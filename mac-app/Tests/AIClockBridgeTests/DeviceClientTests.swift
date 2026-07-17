import XCTest
@testable import AIClockBridge

final class DeviceClientTests: XCTestCase {
    override func tearDown() {
        DeviceClient.wiredCommandHandler = nil
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
        DeviceClient.wiredPetUploadHandler = { data, slot, format, completion in
            XCTAssertEqual(data, gif)
            XCTAssertEqual(slot, "claude")
            XCTAssertEqual(format, "gif")
            completion(nil)
            return true
        }

        DeviceClient.uploadGif(gif, slot: "claude") { error in
            XCTAssertNil(error)
            completed.fulfill()
        }

        wait(for: [completed], timeout: 1)
    }

    func testUploadPetUsesNativeSpriteOverWiredTransport() {
        let sprite = Data([0x01, 0xF8, 0x00])
        let gif = Data([0x47, 0x49, 0x46])
        let completed = expectation(description: "wired native pet upload completed")
        DeviceClient.wiredPetUploadHandler = { data, slot, format, completion in
            XCTAssertEqual(data, sprite)
            XCTAssertEqual(slot, "codex")
            XCTAssertEqual(format, "rgb565")
            completion(nil)
            return true
        }

        DeviceClient.uploadPet(sprite, fallbackGif: gif, slot: "codex") { error in
            XCTAssertNil(error)
            completed.fulfill()
        }

        wait(for: [completed], timeout: 1)
    }

    func testPetUploadCrc32MatchesStandardVector() {
        XCTAssertEqual(SerialLink.crc32(Data("123456789".utf8)), 0xCBF4_3926)
    }

    func testPomodoroControlUsesWiredTransport() {
        let completed = expectation(description: "wired pomodoro command completed")
        DeviceClient.wiredCommandHandler = { command in
            XCTAssertEqual(command["pomodoro"] as? String, "configure")
            XCTAssertEqual(command["focus_min"] as? Int, 50)
            XCTAssertEqual(command["break_min"] as? Int, 10)
            return true
        }
        DeviceClient.controlPomodoro("configure", focusMinutes: 50, breakMinutes: 10) { error in
            XCTAssertNil(error)
            completed.fulfill()
        }
        wait(for: [completed], timeout: 1)
    }

    func testDecodeInfoIncludesFirmwareAndOTA() throws {
        let data = Data("""
        {"ip":"192.168.1.50","mode":"pomodoro","fw":"0.6.0","ota":true,
         "sprite_upload":{"state":"processing","slot":"codex","error":""},
         "pomodoro":{"phase":"break","running":true,"remaining_s":238,"duration_s":300,
                       "completed":3,"focus_min":25,"break_min":5},
         "claude":{"custom_sprite":false},"codex":{"custom_sprite":true}}
        """.utf8)
        let info = try XCTUnwrap(DeviceClient.decodeInfo(data))
        XCTAssertEqual(info.firmwareVersion, "0.6.0")
        XCTAssertEqual(info.mode, "pomodoro")
        XCTAssertTrue(info.otaAvailable)
        XCTAssertEqual(info.spriteUploadState, "processing")
        XCTAssertEqual(info.spriteUploadSlot, "codex")
        XCTAssertTrue(info.codexCustomSprite)
        XCTAssertEqual(info.pomodoroPhase, "break")
        XCTAssertTrue(info.pomodoroRunning)
        XCTAssertEqual(info.pomodoroRemainingS, 238)
        XCTAssertEqual(info.pomodoroDurationS, 300)
        XCTAssertEqual(info.pomodoroCompleted, 3)
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
