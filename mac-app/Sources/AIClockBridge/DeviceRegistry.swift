import Foundation

extension Notification.Name {
    static let deviceRegistryDidChange = Notification.Name("AIClockBridge.deviceRegistryDidChange")
}

final class DeviceRegistry {
    static let shared = DeviceRegistry()

    private static let devicesKey = "device_hosts_v2"
    private static let selectedKey = "device_host"
    private static let maximumDevices = 8

    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var addresses: [String] {
        lock.lock()
        defer { lock.unlock() }
        return loadAddressesLocked()
    }

    var selectedAddress: String {
        get {
            lock.lock()
            defer { lock.unlock() }
            return Self.normalize(defaults.string(forKey: Self.selectedKey) ?? "")
        }
        set {
            let address = Self.normalize(newValue)
            lock.lock()
            var addresses = loadAddressesLocked()
            if !address.isEmpty, !addresses.contains(address) {
                addresses.append(address)
                addresses = Array(addresses.suffix(Self.maximumDevices))
                defaults.set(addresses, forKey: Self.devicesKey)
            }
            defaults.set(address, forKey: Self.selectedKey)
            lock.unlock()
            notifyChanged()
        }
    }

    @discardableResult
    func register(_ rawAddress: String, selectIfNeeded: Bool = true) -> String? {
        let address = Self.normalize(rawAddress)
        guard !address.isEmpty else { return nil }

        lock.lock()
        var addresses = loadAddressesLocked()
        let previousSelected = Self.normalize(defaults.string(forKey: Self.selectedKey) ?? "")
        var changed = false
        if !addresses.contains(address) {
            addresses.append(address)
            addresses = Array(addresses.suffix(Self.maximumDevices))
            defaults.set(addresses, forKey: Self.devicesKey)
            changed = true
        }
        if selectIfNeeded, previousSelected.isEmpty {
            defaults.set(address, forKey: Self.selectedKey)
            changed = true
        }
        lock.unlock()

        if changed { notifyChanged() }
        return address
    }

    func remove(_ rawAddress: String) {
        let address = Self.normalize(rawAddress)
        guard !address.isEmpty else { return }

        lock.lock()
        var addresses = loadAddressesLocked()
        let oldCount = addresses.count
        addresses.removeAll { $0 == address }
        guard addresses.count != oldCount else {
            lock.unlock()
            return
        }
        defaults.set(addresses, forKey: Self.devicesKey)
        let selected = Self.normalize(defaults.string(forKey: Self.selectedKey) ?? "")
        if selected == address {
            defaults.set(addresses.first ?? "", forKey: Self.selectedKey)
        }
        lock.unlock()
        notifyChanged()
    }

    static func normalize(_ rawAddress: String) -> String {
        var value = rawAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        if value.hasPrefix("http://") || value.hasPrefix("https://"),
           let components = URLComponents(string: value), let host = components.host {
            value = host
            if let port = components.port { value += ":\(port)" }
        }
        return value
    }

    private func loadAddressesLocked() -> [String] {
        var result: [String] = []
        for raw in defaults.stringArray(forKey: Self.devicesKey) ?? [] {
            let address = Self.normalize(raw)
            if !address.isEmpty, !result.contains(address) { result.append(address) }
        }
        let legacy = Self.normalize(defaults.string(forKey: Self.selectedKey) ?? "")
        if !legacy.isEmpty, !result.contains(legacy) {
            result.append(legacy)
            defaults.set(result, forKey: Self.devicesKey)
        }
        return Array(result.suffix(Self.maximumDevices))
    }

    private func notifyChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .deviceRegistryDidChange, object: self)
        }
    }
}
