import Foundation

struct DisplayModeDescriptor: Equatable {
    let mode: String
    let menuTitle: String
    let segmentTitle: String
    let preferredWidth: Double
    let isConfigurable: Bool

    static let all: [DisplayModeDescriptor] = [
        DisplayModeDescriptor(mode: "auto",
                              menuTitle: "\u{81EA}\u{52A8}\u{FF08}\u{8C01}\u{5728}\u{5E72}\u{6D3B}\u{663E}\u{793A}\u{8C01}\u{FF09}",
                              segmentTitle: "\u{81EA}\u{52A8}", preferredWidth: 36,
                              isConfigurable: false),
        DisplayModeDescriptor(mode: "claude", menuTitle: "\u{56FA}\u{5B9A} Claude",
                              segmentTitle: "Claude", preferredWidth: 52,
                              isConfigurable: false),
        DisplayModeDescriptor(mode: "codex", menuTitle: "\u{56FA}\u{5B9A} Codex",
                              segmentTitle: "Codex", preferredWidth: 50,
                              isConfigurable: false),
        DisplayModeDescriptor(mode: "net", menuTitle: "\u{7F51}\u{901F}\u{66F2}\u{7EBF}",
                              segmentTitle: "\u{7F51}\u{901F}", preferredWidth: 36,
                              isConfigurable: true),
        DisplayModeDescriptor(mode: "music", menuTitle: "\u{97F3}\u{4E50}\u{64AD}\u{653E}",
                              segmentTitle: "\u{97F3}\u{4E50}", preferredWidth: 36,
                              isConfigurable: true),
        DisplayModeDescriptor(mode: "stock", menuTitle: "\u{80A1}\u{7968}\u{884C}\u{60C5}",
                              segmentTitle: "\u{80A1}\u{7968}", preferredWidth: 36,
                              isConfigurable: true),
        DisplayModeDescriptor(mode: "pomodoro", menuTitle: "\u{756A}\u{8304}\u{65F6}\u{949F}",
                              segmentTitle: "\u{756A}\u{8304}", preferredWidth: 42,
                              isConfigurable: true),
    ]

    static var configurable: [DisplayModeDescriptor] {
        all.filter(\.isConfigurable)
    }

    static func descriptor(for mode: String) -> DisplayModeDescriptor? {
        all.first { $0.mode == mode }
    }

    static func selectableModes(enabledOptionalModes: [String]) -> [String] {
        let enabled = Set(enabledOptionalModes)
        return all.filter { !$0.isConfigurable || enabled.contains($0.mode) }.map(\.mode)
    }
}

final class FeaturePreferences {
    static let shared = FeaturePreferences()
    static let storageKey = "enabledOptionalDisplayModes"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var enabledOptionalModes: [String] {
        get {
            guard let stored = defaults.array(forKey: Self.storageKey) as? [String] else {
                return DisplayModeDescriptor.configurable.map(\.mode)
            }
            let enabled = Set(stored)
            return DisplayModeDescriptor.configurable.map(\.mode).filter(enabled.contains)
        }
        set {
            let requested = Set(newValue)
            let normalized = DisplayModeDescriptor.configurable.map(\.mode).filter(requested.contains)
            defaults.set(normalized, forKey: Self.storageKey)
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
