import XCTest
@testable import AIClockBridge

final class PrinterStatusTests: XCTestCase {
    func testPrinterCapabilityAndDualNozzleDecoding() throws {
        let data = Data("""
        {"mode":"printer","printer":{"supported":true,"configured":true,
         "enabled":true,"connected":true,"dual_nozzle":true,
         "nozzle_left_c":205,"nozzle_right_c":210}}
        """.utf8)
        let device = try XCTUnwrap(DeviceClient.decodeInfo(data))
        XCTAssertEqual(device.mode, "printer")
        XCTAssertTrue(device.printer.dualNozzle)
        XCTAssertEqual(device.printer.nozzleLeft, 205)
        XCTAssertEqual(device.printer.nozzleRight, 210)
        XCTAssertFalse(DisplayModeDescriptor.selectableModes(
            enabledOptionalModes: []).contains("printer"))
        XCTAssertTrue(DisplayModeDescriptor.selectableModes(
            enabledOptionalModes: [], printerSupported: true).contains("printer"))
    }
    func testMissingAndInvalidMeasurementsRemainUnknown() {
        let state = PrinterStatus.decode(["supported": true, "progress": 101,
                                          "nozzle_c": NSNull(), "bed_c": true])
        XCTAssertTrue(state.supported)
        XCTAssertNil(state.progress)
        XCTAssertNil(state.nozzle)
        XCTAssertNil(state.bed)
        XCTAssertEqual(state.remainingText, "--")
    }

    func testOfflineAndStaleNeverDisplayIdle() {
        var state = PrinterStatus.decode(["supported": true, "configured": true,
                                          "enabled": true, "state": "IDLE"])
        XCTAssertEqual(state.statusText, "打印机离线")
        state.connected = true
        state.stale = true
        XCTAssertEqual(state.statusText, "数据已过期")
    }

    func testProgressAndRemainingTime() {
        let state = PrinterStatus.decode(["supported": true, "configured": true,
            "enabled": true, "connected": true, "state": "RUNNING",
            "progress": 34, "remaining_min": 125, "layer": 8, "total_layers": 100])
        XCTAssertEqual(state.progress, 34)
        XCTAssertEqual(state.remainingText, "2h 5m")
        XCTAssertEqual(state.statusText, "正在打印")
        XCTAssertEqual(state.totalLayers, 100)
    }
}
