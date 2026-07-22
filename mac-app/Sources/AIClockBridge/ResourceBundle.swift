import Foundation

extension Bundle {
    static let aiClockResources: Bundle = {
        if let resourceURL = Bundle.main.resourceURL {
            let appBundleURL = resourceURL.appendingPathComponent("AIClockBridge_AIClockBridge.bundle")
            if let bundle = Bundle(url: appBundleURL) {
                return bundle
            }
        }
        return .module
    }()
}
