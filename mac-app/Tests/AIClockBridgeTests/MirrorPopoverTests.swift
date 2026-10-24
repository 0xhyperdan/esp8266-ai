import AppKit
import XCTest
@testable import AIClockBridge

final class MirrorPopoverTests: XCTestCase {
    func testPrinterPreviewRendersProgressWithoutOtherScenes() throws {
        let view = MirrorView(frame: NSRect(x: 0, y: 0, width: 240, height: 240))
        view.printerMode = true
        view.deviceOK = true
        view.printerStatus = PrinterStatus.decode([
            "supported": true, "configured": true, "enabled": true,
            "connected": true, "state": "RUNNING", "job": "X2D 测试模型",
            "progress": 83, "remaining_min": 42, "layer": 168,
            "total_layers": 200, "dual_nozzle": true,
            "nozzle_left_c": 205, "nozzle_right_c": 210, "bed_c": 60
        ])
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let color = try XCTUnwrap(bitmap.colorAt(
            x: bitmap.pixelsWide * 50 / 240,
            y: bitmap.pixelsHigh * 94 / 240)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(color.greenComponent, color.redComponent)
        if let output = ProcessInfo.processInfo.environment["AICLOCK_PRINTER_PREVIEW"] {
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: output))
        }
    }

    func testWeatherPreviewKeepsImageOrientation() throws {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 240, height: 240, bitsPerComponent: 8,
            bytesPerRow: 960, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 120, width: 240, height: 120))
        context.setFillColor(NSColor.blue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 240, height: 120))
        let image = NSImage(cgImage: try XCTUnwrap(context.makeImage()), size: NSSize(width: 240, height: 240))
        let mirror = MirrorView(frame: NSRect(x: 0, y: 0, width: 240, height: 240))
        mirror.weatherMode = true
        mirror.weatherImage = image
        let bitmap = try XCTUnwrap(mirror.bitmapImageRepForCachingDisplay(in: mirror.bounds))
        mirror.cacheDisplay(in: mirror.bounds, to: bitmap)
        let top = try XCTUnwrap(bitmap.colorAt(
            x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 10
        )?.usingColorSpace(.deviceRGB))
        let bottom = try XCTUnwrap(bitmap.colorAt(
            x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh * 9 / 10
        )?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(top.redComponent, top.blueComponent)
        XCTAssertGreaterThan(bottom.blueComponent, bottom.redComponent)
    }

    func testDualDeviceSelectorPreservesRetainedModes() throws {
        let controller = MirrorPopoverController(
            nowPlaying: NowPlayingMonitor(),
            stockMonitor: StockMonitor(),
            weatherMonitor: WeatherMonitor(), enabledOptionalModes: ["music", "stock"]
        )
        let view = controller.prepareDesignQASnapshot(
            addresses: ["192.168.1.20", "192.168.1.21"], selectedAddress: "192.168.1.20"
        )
        let controls = view.subviews.compactMap { $0 as? NSSegmentedControl }
        let devices = try XCTUnwrap(controls.first { $0.segmentCount == 2 })
        XCTAssertFalse(devices.isHidden)
        XCTAssertEqual(devices.label(forSegment: 1), "192.168.1.21")
        XCTAssertEqual(devices.selectedSegment, 0)
        XCTAssertEqual(view.frame.size, NSSize(width: 316, height: 454))
        let modes = try XCTUnwrap(controls.first { $0.segmentCount == 3 })
        XCTAssertEqual(modes.label(forSegment: 0), "天气")
        XCTAssertEqual(modes.label(forSegment: 1), "音乐")
        XCTAssertEqual(modes.label(forSegment: 2), "股票")
    }
}
