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

    func testParsePreservesSourcePricePrecision() {
        let text = [
            quote(symbol: "sh513130", name: "ETF", price: "1.234",
                  change: "0.001", percent: "0.08"),
            quote(symbol: "sh600519", name: "Stock", price: "12345.67",
                  change: "-1.23", percent: "-0.01"),
        ].joined(separator: "\n")

        let rows = StockMonitor.parse(
            text: text,
            order: ["sh513130", "sh600519"]
        )

        XCTAssertEqual(rows.map(\.price), ["1.234", "12345.67"])
        XCTAssertEqual(rows.map(\.pct), ["+0.08%", "-0.01%"])
    }

    func testParseRejectsNonFinitePrice() {
        let text = quote(
            symbol: "sh513130",
            name: "ETF",
            price: "nan",
            change: "0.001",
            percent: "0.08"
        )

        XCTAssertTrue(StockMonitor.parse(text: text, order: ["sh513130"]).isEmpty)
    }

    private func quote(symbol: String, name: String, price: String,
                       change: String, percent: String) -> String {
        var fields = Array(repeating: "0", count: 33)
        fields[1] = name
        fields[3] = price
        fields[31] = change
        fields[32] = percent
        return "v_\(symbol)=\"\(fields.joined(separator: "~"))\";"
    }
}
