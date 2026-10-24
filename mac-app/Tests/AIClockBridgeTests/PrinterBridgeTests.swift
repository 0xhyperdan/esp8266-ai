import XCTest
@testable import AIClockBridge

final class PrinterBridgeTests: XCTestCase {
    final class Credentials: PrinterCredentialStore {
        var values: [String: String] = [:]
        var failDelete = false
        func read(identity: String) throws -> String? { values[identity] }
        func save(_ value: String, identity: String) throws { values[identity] = value }
        func delete(identity: String) throws {
            if failDelete { throw PrinterBridgeError.keychain }
            values.removeValue(forKey: identity)
        }
    }

    func testValidation() {
        for host in ["192.168.1.1", "10.0.0.2", "172.16.0.3"] {
            XCTAssertTrue(PrinterBridgeConfiguration(host: host, serial: "ABC-123").isValid)
        }
        for host in ["8.8.8.8", "127.0.0.1", "192.168.1.999", "10.0.0.01", "10.0.0.-1", "printer.local"] {
            XCTAssertFalse(PrinterBridgeConfiguration(host: host, serial: "ABC").isValid)
        }
        XCTAssertFalse(PrinterBridgeConfiguration.validCode("short"))
        XCTAssertFalse(PrinterBridgeConfiguration.validCode("1234 678"))
        XCTAssertTrue(PrinterBridgeConfiguration.validCode("test1234"))
    }

    func testCredentialLifecycleAndDisabledState() throws {
        let suite = "PrinterBridgeTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = Credentials()
        let bridge = PrinterBridge(defaults: defaults, credentials: store)
        let config = PrinterBridgeConfiguration(host: "192.168.1.100", serial: "TEST123")
        XCTAssertThrowsError(try bridge.configure(config, accessCode: ""))
        try bridge.configure(config, accessCode: "test1234")
        XCTAssertEqual(store.values[config.identity], "test1234")
        let persisted = defaults.dictionaryRepresentation()
        XCTAssertFalse(String(describing: persisted).contains("test1234"))
        try bridge.configure(config, accessCode: "")
        XCTAssertTrue(bridge.snapshot().configured)
        XCTAssertFalse(bridge.snapshot().connected)
        XCTAssertFalse(bridge.snapshot().enabled)
        XCTAssertFalse(bridge.snapshot().native)
        store.failDelete = true
        XCTAssertThrowsError(try bridge.forget())
        XCTAssertTrue(bridge.snapshot().configured)
        store.failDelete = false
        try bridge.forget()
        XCTAssertTrue(store.values.isEmpty)
        XCTAssertFalse(bridge.snapshot().configured)
        bridge.start(); bridge.stop()
        XCTAssertFalse(bridge.snapshot().connected)
    }

    func testFragmentedAndCoalescedMQTTFrames() throws {
        let frame = PrinterMQTT.packet(0x30, Data(repeating: 42, count: 300))
        var buffer = Data()
        for byte in frame.dropLast() {
            buffer.append(byte)
            XCTAssertNil(try PrinterMQTT.next(&buffer))
        }
        buffer.append(frame.last!)
        buffer += Data([0xd0, 0])
        XCTAssertEqual(try PrinterMQTT.next(&buffer)?.body.count, 300)
        XCTAssertEqual(try PrinterMQTT.next(&buffer)?.header, 0xd0)
        XCTAssertTrue(buffer.isEmpty)
        buffer = Data([0x30, 0xff, 0xff, 0xff, 0xff])
        XCTAssertThrowsError(try PrinterMQTT.next(&buffer))
        buffer = PrinterMQTT.packet(0x30, Data(repeating: 1, count: 65_536))
        XCTAssertThrowsError(try PrinterMQTT.next(&buffer))
    }

    func testOnlyExpectedQoSZeroTopicAccepted() throws {
        let report = Data(#"{"print":{"mc_percent":42}}"#.utf8)
        let frame = PrinterMQTT.Frame(header: 0x30, body: PrinterMQTT.string("device/TEST/report") + report)
        XCTAssertEqual(try PrinterMQTT.report(frame, serial: "TEST"), report)
        XCTAssertNil(try PrinterMQTT.report(frame, serial: "OTHER"))
        XCTAssertThrowsError(try PrinterMQTT.report(.init(header: 0x32, body: frame.body), serial: "TEST"))
        XCTAssertThrowsError(try PrinterMQTT.report(.init(header: 0x30, body: Data([0, 10])), serial: "TEST"))
        let request = String(decoding: PrinterMQTT.snapshotRequest(serial: "TEST"), as: UTF8.self)
        XCTAssertTrue(request.contains("pushall"))
        XCTAssertFalse(request.contains("gcode_line"))
    }

    func testDeltaUnknownFieldsNewJobAndDualNozzle() {
        var parser = PrinterReportAccumulator()
        func data(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: ["print": object]) }
        XCTAssertTrue(parser.apply(data(["task_id": "1", "subtask_name": "测试模型", "gcode_state": "RUNNING", "mc_percent": 42, "layer_num": 2, "total_layer_num": 10])))
        XCTAssertTrue(parser.apply(data(["bed_temper": 60])))
        XCTAssertEqual(parser.value.progress, 42)
        XCTAssertFalse(parser.apply(data(["mc_percent": true, "bed_temper": NSNull()])))
        XCTAssertEqual(parser.value.bed, 60)
        XCTAssertFalse(parser.apply(Data(#"{"hms":[]}"#.utf8)))
        XCTAssertTrue(parser.apply(data(["device": ["extruder": ["state": 0, "info": [
            ["id": 0, "temp": (220 << 16) | 210], ["id": 1, "temp": (220 << 16) | 205]]]]])))
        XCTAssertTrue(parser.value.dualNozzle)
        XCTAssertEqual(parser.value.nozzle, 210)
        XCTAssertTrue(parser.apply(data(["device": ["extruder": ["state": 16]]])))
        XCTAssertEqual(parser.value.nozzle, 205)
        XCTAssertTrue(parser.apply(data(["task_id": "2"])))
        XCTAssertNil(parser.value.progress)
        XCTAssertNil(parser.value.layer)
        XCTAssertEqual(parser.value.job, "")
        XCTAssertEqual(parser.value.nozzleLeft, 205)
    }

    func testBridgeJSONIsFullBoundedAndContainsNoCredentials() throws {
        var value = PrinterStatus()
        value.native = false; value.supported = true
        value.job = String(repeating: "测", count: 400)
        value.progress = 42
        let data = value.jsonData()
        XCTAssertLessThan(data.count, 1400)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["source"] as? String, "bridge")
        XCTAssertNil(object["access_code"])
        XCTAssertNil(object["remaining_min"])
        XCTAssertEqual(PrinterStatus.decode(object).progress, 42)
        XCTAssertLessThanOrEqual((object["job"] as? String)?.utf8.count ?? 1000, 127)
        value.layer = 2
        let partial = try XCTUnwrap(JSONSerialization.jsonObject(with: value.jsonData()) as? [String: Any])
        XCTAssertNil(partial["layer"])
        value.totalLayers = 10
        let paired = try XCTUnwrap(JSONSerialization.jsonObject(with: value.jsonData()) as? [String: Any])
        XCTAssertEqual(paired["layer"] as? Int, 2)
        XCTAssertEqual(paired["total_layers"] as? Int, 10)
        let serial = SerialLink.printerFrame(value)
        XCTAssertTrue(serial.starts(with: Data("#PRINTER ".utf8)))
        XCTAssertEqual(serial.last, 0x0a)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: serial.dropFirst(9).dropLast()) as? [String: Any])
        XCTAssertEqual(decoded["progress"] as? Int, 42)
    }
}
