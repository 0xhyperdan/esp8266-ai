import Foundation

struct DisplayModeDescriptor: Equatable {
    let mode: String
    let menuTitle: String
    let segmentTitle: String
    let preferredWidth: Double
    let isConfigurable: Bool

    static let all: [DisplayModeDescriptor] = [
        DisplayModeDescriptor(mode: "weather",
                              menuTitle: "\u{5929}\u{6C14}\u{65F6}\u{949F}",
                              segmentTitle: "\u{5929}\u{6C14}", preferredWidth: 42,
                              isConfigurable: false),
        DisplayModeDescriptor(mode: "printer", menuTitle: "打印机状态",
                              segmentTitle: "打印机", preferredWidth: 48,
                              isConfigurable: false),
        DisplayModeDescriptor(mode: "music", menuTitle: "\u{97F3}\u{4E50}\u{64AD}\u{653E}",
                              segmentTitle: "\u{97F3}\u{4E50}", preferredWidth: 36,
                              isConfigurable: true),
        DisplayModeDescriptor(mode: "stock", menuTitle: "\u{80A1}\u{7968}\u{884C}\u{60C5}",
                              segmentTitle: "\u{80A1}\u{7968}", preferredWidth: 36,
                              isConfigurable: true),
        DisplayModeDescriptor(mode: "salary", menuTitle: "\u{85AA}\u{8D44}\u{65F6}\u{949F}",
                              segmentTitle: "\u{85AA}\u{8D44}", preferredWidth: 42,
                              isConfigurable: true),
    ]

    static var configurable: [DisplayModeDescriptor] {
        all.filter(\.isConfigurable)
    }

    static func descriptor(for mode: String) -> DisplayModeDescriptor? {
        all.first { $0.mode == normalizedMode(mode) }
    }

    static func normalizedMode(_ mode: String) -> String {
        all.contains { $0.mode == mode } ? mode : "weather"
    }

    static func selectableModes(enabledOptionalModes: [String],
                                printerSupported: Bool = false) -> [String] {
        let enabled = Set(enabledOptionalModes)
        return all.filter { ($0.mode != "printer" || printerSupported)
            && (!$0.isConfigurable || enabled.contains($0.mode)) }.map(\.mode)
    }
}

final class FeaturePreferences {
    static let shared = FeaturePreferences()
    static let storageKey = "enabledOptionalDisplayModes"
    static let catalogVersionKey = "optionalDisplayModeCatalogVersion"
    static let currentCatalogVersion = 7

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var enabledOptionalModes: [String] {
        get {
            guard let stored = defaults.array(forKey: Self.storageKey) as? [String] else {
                defaults.set(Self.currentCatalogVersion, forKey: Self.catalogVersionKey)
                return DisplayModeDescriptor.configurable.map(\.mode)
            }
            let enabled = Set(stored)
            let normalized = DisplayModeDescriptor.configurable.map(\.mode).filter(enabled.contains)
            if defaults.integer(forKey: Self.catalogVersionKey) < Self.currentCatalogVersion
                || normalized != stored {
                defaults.set(Self.currentCatalogVersion, forKey: Self.catalogVersionKey)
                defaults.set(normalized, forKey: Self.storageKey)
            }
            return normalized
        }
        set {
            let requested = Set(newValue)
            let normalized = DisplayModeDescriptor.configurable.map(\.mode).filter(requested.contains)
            defaults.set(normalized, forKey: Self.storageKey)
            defaults.set(Self.currentCatalogVersion, forKey: Self.catalogVersionKey)
        }
    }

    func isEnabled(_ mode: String) -> Bool {
        guard DisplayModeDescriptor.descriptor(for: mode)?.isConfigurable == true else { return true }
        return enabledOptionalModes.contains(mode)
    }

    func setEnabled(_ enabled: Bool, for mode: String) {
        guard DisplayModeDescriptor.descriptor(for: mode)?.isConfigurable == true else { return }
        var modes = Set(enabledOptionalModes)
        if enabled {
            modes.insert(mode)
        } else {
            modes.remove(mode)
        }
        enabledOptionalModes = Array(modes)
    }
}
