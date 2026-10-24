import AppKit
import UniformTypeIdentifiers

final class OTAUpdateController: NSObject {
    static let shared = OTAUpdateController()
    static var menuTitle: String { text("ota.menu", "Wi-Fi Firmware Update…") }

    private var progressWindow: NSWindow?
    private var statusLabel: NSTextField?
    private var progressIndicator: NSProgressIndicator?
    private var updating = false

    func start() {
        guard !updating else {
            progressWindow?.makeKeyAndOrderFront(nil)
            return
        }
        guard let host = DeviceClient.baseURL?.host, !host.isEmpty else {
            Self.alert(title: Self.text("ota.no_device.title", "Device address required"),
                       message: Self.text("ota.no_device.message", "Set the device address first."))
            return
        }

        DeviceClient.fetchLANInfo { [weak self] result in
            guard let self = self else { return }
            switch result {
            case let .success(info):
                guard info.otaAvailable else {
                    Self.alert(title: Self.text("ota.unsupported.title", "OTA unavailable"),
                               message: Self.text("ota.unsupported.message",
                                                  "This device firmware does not support Wi-Fi updates."))
                    return
                }
                self.chooseFirmware(host: host, info: info)
            case let .failure(error):
                Self.alert(title: Self.text("ota.connect_failed.title", "Could not reach device"),
                           message: error.localizedDescription)
            }
        }
    }

    private func chooseFirmware(host: String, info: DeviceInfo) {
        let targetName = DeviceClient.firmwareTargetName(for: info.board)
        let panel = NSOpenPanel()
        let titleFormat = Self.text("ota.file.title", "Select %@ firmware")
        panel.title = String(format: titleFormat, targetName)
        panel.prompt = Self.text("ota.file.choose", "Choose Firmware")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let firmwareType = UTType(filenameExtension: "bin") {
            panel.allowedContentTypes = [firmwareType]
        }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let firmware = try Data(contentsOf: url, options: .mappedIfSafe)
            guard DeviceClient.isValidFirmwareImage(firmware, boardID: info.board) else {
                let messageFormat = Self.text(
                    "ota.invalid.message",
                    "Select a firmware.bin built for this %@ device."
                )
                Self.alert(title: Self.text("ota.invalid.title", "Invalid firmware"),
                           message: String(format: messageFormat, targetName))
                return
            }
            guard let credentials = credentials(host: host) else { return }
            beginUpload(firmware, host: host, boardID: info.board, credentials: credentials)
        } catch {
            Self.alert(title: Self.text("ota.read_failed.title", "Could not read firmware"),
                       message: error.localizedDescription)
        }
    }

    private func credentials(host: String) -> OTACredentials? {
        do {
            if let saved = try OTACredentialStore.load(host: host) { return saved }
        } catch {
            Self.alert(title: Self.text("ota.keychain_failed.title", "Keychain unavailable"),
                       message: error.localizedDescription)
        }

        let alert = NSAlert()
        alert.messageText = Self.text("ota.credentials.title", "OTA credentials")
        alert.informativeText = Self.text("ota.credentials.message",
                                          "Enter the credentials configured in ota_secrets.h.")
        let username = NSTextField(string: "admin")
        username.placeholderString = Self.text("ota.credentials.username", "Username")
        let password = NSSecureTextField(string: "")
        password.placeholderString = Self.text("ota.credentials.password", "Password")
        let stack = NSStackView(views: [username, password])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: 56)
        alert.accessoryView = stack
        alert.addButton(withTitle: Self.text("ota.credentials.save", "Save and Continue"))
        alert.addButton(withTitle: Self.text("ota.cancel", "Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        let value = OTACredentials(
            username: username.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password.stringValue
        )
        guard !value.username.isEmpty, !value.password.isEmpty else {
            Self.alert(title: Self.text("ota.credentials.invalid.title", "Credentials required"),
                       message: Self.text("ota.credentials.invalid.message",
                                          "Both username and password are required."))
            return nil
        }
        do {
            try OTACredentialStore.save(value, host: host)
        } catch {
            Self.alert(title: Self.text("ota.keychain_failed.title", "Keychain unavailable"),
                       message: error.localizedDescription)
        }
        return value
    }

    private func beginUpload(_ firmware: Data, host: String, boardID: String,
                             credentials: OTACredentials) {
        updating = true
        showProgressWindow()
        DeviceClient.uploadFirmware(firmware, boardID: boardID,
                                    credentials: credentials, progress: { [weak self] state in
            self?.apply(state)
        }, completion: { [weak self] result in
            guard let self = self else { return }
            self.updating = false
            self.progressIndicator?.stopAnimation(nil)
            self.progressWindow?.close()
            self.progressWindow = nil
            switch result {
            case let .success(info):
                let version = info.firmwareVersion.isEmpty ? "?" : info.firmwareVersion
                let format = Self.text("ota.success.message", "Device %@ is online with firmware %@.")
                Self.alert(title: Self.text("ota.success.title", "Firmware updated"),
                           message: String(format: format, info.ip, version))
            case let .failure(error):
                if (error as NSError).code == 401 { OTACredentialStore.delete(host: host) }
                Self.alert(title: Self.text("ota.failed.title", "Firmware update failed"),
                           message: error.localizedDescription)
            }
        })
    }

    private func showProgressWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 120),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = Self.text("ota.progress.title", "Wi-Fi Firmware Update")
        window.isReleasedWhenClosed = false
        window.center()
        let label = NSTextField(labelWithString: Self.text("ota.progress.starting", "Preparing upload…"))
        label.frame = NSRect(x: 24, y: 70, width: 332, height: 22)
        let indicator = NSProgressIndicator(frame: NSRect(x: 24, y: 36, width: 332, height: 16))
        indicator.minValue = 0
        indicator.maxValue = 100
        indicator.doubleValue = 0
        window.contentView?.addSubview(label)
        window.contentView?.addSubview(indicator)
        statusLabel = label
        progressIndicator = indicator
        progressWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func apply(_ state: FirmwareUpdateProgress) {
        switch state {
        case let .uploading(fraction):
            progressIndicator?.isIndeterminate = false
            progressIndicator?.doubleValue = fraction * 100
            let format = Self.text("ota.progress.uploading", "Uploading… %d%%")
            statusLabel?.stringValue = String(format: format, Int(fraction * 100))
        case .restarting:
            progressIndicator?.isIndeterminate = true
            progressIndicator?.startAnimation(nil)
            statusLabel?.stringValue = Self.text("ota.progress.restarting",
                                                 "Upload complete. Waiting for device restart…")
        }
    }

    private static func alert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: text("ota.ok", "OK"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    fileprivate static func text(_ key: String, _ fallback: String) -> String {
        Bundle.aiClockResources.localizedString(forKey: key, value: fallback, table: nil)
    }
}
