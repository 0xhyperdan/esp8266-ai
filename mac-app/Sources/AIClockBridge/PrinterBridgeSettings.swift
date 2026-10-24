import AppKit

enum PrinterBridgeSettings {
    /// Fixed-size native controls avoid collapsed text fields in accessory alerts.
    static func show(bridge: PrinterBridge = .shared) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let config = bridge.configuration
        let alert = NSAlert()
        alert.messageText = "拓竹打印机 · 电脑桥接"
        alert.informativeText = "ESP8266 通过此 Mac 获取打印状态。电脑需保持开机、App 运行。访问码只保存在 Mac 钥匙串，不会发送到小电视。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "清除配置")
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 266))
        func field(_ title: String, y: CGFloat, value: String, secure: Bool = false) -> NSTextField {
            let label = NSTextField(labelWithString: title)
            label.frame = NSRect(x: 0, y: y + 28, width: 400, height: 20)
            view.addSubview(label)
            let input: NSTextField = secure ? NSSecureTextField() : NSTextField()
            input.frame = NSRect(x: 0, y: y, width: 400, height: 26)
            input.stringValue = value
            view.addSubview(input)
            return input
        }
        let host = field("打印机 IPv4", y: 204, value: config.host)
        let serial = field("打印机序列号 SN", y: 143, value: config.serial)
        let code = field("LAN Access Code（同一台留空可保留）", y: 82, value: "", secure: true)
        let enabled = NSButton(checkboxWithTitle: "开启打印机监控", target: nil, action: nil)
        enabled.frame = NSRect(x: 0, y: 46, width: 400, height: 22)
        enabled.state = config.enabled ? .on : .off
        view.addSubview(enabled)
        let trust = NSButton(checkboxWithTitle: "信任此局域网，允许打印机自签名 TLS 证书", target: nil, action: nil)
        trust.frame = NSRect(x: 0, y: 14, width: 400, height: 22)
        trust.state = config.allowSelfSigned ? .on : .off
        view.addSubview(trust)
        alert.accessoryView = view
        let response = alert.runModal()
        guard response != .alertSecondButtonReturn else { return }
        do {
            if response == .alertThirdButtonReturn {
                try bridge.forget()
            } else {
                let next = PrinterBridgeConfiguration(
                    host: host.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                    serial: serial.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                    enabled: enabled.state == .on, allowSelfSigned: trust.state == .on)
                try bridge.configure(next, accessCode: code.stringValue)
                if next.enabled { DeviceClient.setDisplayMode("printer") { _ in } }
            }
        } catch {
            let failure = NSAlert()
            failure.messageText = "打印机设置未完成"
            failure.informativeText = error.localizedDescription
            failure.runModal()
        }
        code.stringValue = ""
    }
}
