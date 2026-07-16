import AppKit
import XCTest
@testable import AIClockBridge

final class MenuBarIconTests: XCTestCase {
    func testIconAlwaysUsesBlackBackground() throws {
        let icon = MenuBarController.retroMacIcon()

        let representation = try XCTUnwrap(NSBitmapImageRep(
            data: try XCTUnwrap(icon.tiffRepresentation)
        ))
        let center = try XCTUnwrap(representation.colorAt(
            x: representation.pixelsWide / 2,
            y: representation.pixelsHigh / 2
        ))

        XCTAssertLessThan(center.brightnessComponent, 0.15)
        XCTAssertFalse(icon.isTemplate)
    }
}
