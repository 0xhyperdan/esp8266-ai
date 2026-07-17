import CoreGraphics
import XCTest
@testable import AIClockBridge

final class PetdexServiceTests: XCTestCase {
    func testBuildAnimationProducesBigEndianRGB565Sprite() throws {
        let width = PetdexService.frameW
        let height = PetdexService.frameH
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue |
            CGImageAlphaInfo.premultipliedLast.rawValue
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let sheet = try XCTUnwrap(context.makeImage())
        let state = PetdexAnimState(id: "test", label: "Test", row: 0,
                                    frames: 1, durationMs: 100)

        let animation = try XCTUnwrap(PetdexService.buildAnimation(
            sheet: sheet,
            state: state,
            targetW: width,
            targetH: height
        ))

        XCTAssertEqual(animation.frameCount, 1)
        XCTAssertFalse(animation.gif.isEmpty)
        XCTAssertEqual(animation.sprite.count, 1 + width * height * 2)
        XCTAssertEqual(animation.sprite.first, 1)
        let firstPixel = UInt16(animation.sprite[1]) << 8 | UInt16(animation.sprite[2])
        XCTAssertEqual(firstPixel & 0xF800, 0xF800)
        XCTAssertEqual(firstPixel & 0x001F, 0)
    }

    func testRGB565ConversionUsesExpectedChannelLayout() {
        XCTAssertEqual(PetdexService.rgb565(red: 255, green: 0, blue: 0), 0xF800)
        XCTAssertEqual(PetdexService.rgb565(red: 0, green: 255, blue: 0), 0x07E0)
        XCTAssertEqual(PetdexService.rgb565(red: 0, green: 0, blue: 255), 0x001F)
    }
}
