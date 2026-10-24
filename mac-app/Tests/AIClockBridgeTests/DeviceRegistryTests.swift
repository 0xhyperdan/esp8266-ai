import XCTest
@testable import AIClockBridge

final class DeviceRegistryTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "DeviceRegistryTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testMigratesLegacySelectedHostIntoDeviceList() {
        defaults.set("192.168.1.20", forKey: "device_host")
        let registry = DeviceRegistry(defaults: defaults)

        XCTAssertEqual(registry.selectedAddress, "192.168.1.20")
        XCTAssertEqual(registry.addresses, ["192.168.1.20"])
    }

    func testRegistersTwoDevicesWithoutChangingSelection() {
        let registry = DeviceRegistry(defaults: defaults)

        registry.register("192.168.1.20")
        registry.register("http://192.168.1.21/")
        registry.register("192.168.1.20")

        XCTAssertEqual(registry.addresses, ["192.168.1.20", "192.168.1.21"])
        XCTAssertEqual(registry.selectedAddress, "192.168.1.20")
    }

    func testSelectionAndRemovalFallBackToRemainingDevice() {
        let registry = DeviceRegistry(defaults: defaults)
        registry.register("192.168.1.20")
        registry.register("192.168.1.21")
        registry.selectedAddress = "192.168.1.21"

        registry.remove("192.168.1.21")

        XCTAssertEqual(registry.addresses, ["192.168.1.20"])
        XCTAssertEqual(registry.selectedAddress, "192.168.1.20")
    }
}
