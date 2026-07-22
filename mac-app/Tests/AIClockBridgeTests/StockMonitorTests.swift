import XCTest
@testable import AIClockBridge

final class StockMonitorTests: XCTestCase {
    func testQuoteURLUsesHTTPS() {
        let url = StockMonitor.quoteURL(for: ["sh600519", "usAAPL"])

        XCTAssertEqual(url?.scheme, "https")
        XCTAssertEqual(url?.host, "qt.gtimg.cn")
        XCTAssertEqual(url?.path, "/q=sh600519,usAAPL")
    }

    func testQuoteURLRejectsEmptyWatchlist() {
        XCTAssertNil(StockMonitor.quoteURL(for: []))
    }
}
