import AppKit

// Menu-bar item: a retro Macintosh icon drawn with a fixed black background.
// Left click opens a live mirror of the ESP8266
// screen (MirrorPopover); right click opens the control menu with usage
// meters and device remote control. No quota text lives in the bar itself.
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let service: StatusService
    private let usage: UsageFetcher
    private let port: UInt16
    private let featurePreferences: FeaturePreferences
    private let featureConfigurationChanged: () -> Void
    private let controlMenu = NSMenu()
    private let mirrorPopover: MirrorPopoverController

    private let claudeUsageItem = NSMenuItem(title: "Claude …", action: nil, keyEquivalent: "")
    private let codexUsageItem = NSMenuItem(title: "Codex …", action: nil, keyEquivalent: "")
    private let deviceInfoItem = NSMenuItem(title: "设备：未设置", action: nil, keyEquivalent: "")
    private let pomodoroStatusItem = NSMenuItem(title: "\u{756A}\u{8304}\u{65F6}\u{949F}",
                                                action: nil, keyEquivalent: "")
    private let pomodoroToggleItem = NSMenuItem(title: "\u{5F00}\u{59CB}",
                                                action: nil, keyEquivalent: "")
    private var modeItems: [String: NSMenuItem] = [:]
    private var featureToggleItems: [String: NSMenuItem] = [:]
    private var featureSpecificItems: [String: NSMenuItem] = [:]
    private var latestDeviceInfo: DeviceInfo?

    init(service: StatusService, usage: UsageFetcher, netMonitor: NetSpeedMonitor,
         nowPlaying: NowPlayingMonitor, stockMonitor: StockMonitor, port: UInt16,
         featurePreferences: FeaturePreferences = .shared,
         featureConfigurationChanged: @escaping () -> Void = {}) {
        self.service = service
        self.usage = usage
        self.port = port
        self.featurePreferences = featurePreferences
        self.featureConfigurationChanged = featureConfigurationChanged
        self.mirrorPopover = MirrorPopoverController(service: service, netMonitor: netMonitor,
                                                     nowPlaying: nowPlaying, stockMonitor: stockMonitor,
                                                     enabledOptionalModes: featurePreferences.enabledOptionalModes)
        super.init()
        buildMenu()
        applyFeatureConfiguration()
        if let button = statusItem.button {
            button.image = Self.retroMacIcon()
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    func systemWillSleep() {
        mirrorPopover.prepareForSystemSleep()
    }

    func systemDidWake() {
        refreshDeviceSection()
    }

    static func retroMacIcon() -> NSImage {
        let background = NSColor(calibratedWhite: 0.06, alpha: 1)
        let foreground = NSColor.white
        let border = NSColor(calibratedWhite: 0.92, alpha: 1)

        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let bezel = NSBezierPath(roundedRect: NSRect(x: 1.25, y: 1.25, width: 15.5, height: 15.5),
                                     xRadius: 3, yRadius: 3)
            background.setFill()
            bezel.fill()
            border.setStroke()
            bezel.lineWidth = 1.25
            bezel.stroke()

            foreground.setFill()
            NSBezierPath(ovalIn: NSRect(x: 5.25, y: 10.4, width: 1.6, height: 1.6)).fill()
            NSBezierPath(ovalIn: NSRect(x: 11.15, y: 10.4, width: 1.6, height: 1.6)).fill()

            let smile = NSBezierPath()
            smile.move(to: NSPoint(x: 5.6, y: 7.4))
            smile.curve(to: NSPoint(x: 12.4, y: 7.4),
                        controlPoint1: NSPoint(x: 7.2, y: 4.9),
                        controlPoint2: NSPoint(x: 10.8, y: 4.9))
            foreground.setStroke()
            smile.lineWidth = 1.25
            smile.lineCapStyle = .round
            smile.stroke()

            NSColor.systemGreen.setFill()
            NSBezierPath(ovalIn: NSRect(x: 3.35, y: 13.25, width: 1.5, height: 1.5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Left click -> mirror popover; right click -> control menu.
    @objc private func statusItemClicked() {
        guard let button = statusItem.button else { return }
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            statusItem.menu = controlMenu
            button.performClick(nil)
            statusItem.menu = nil // detach so left click keeps toggling the popover
        } else {
            mirrorPopover.toggle(relativeTo: button)
        }
    }

    // MARK: - menu construction

    private func buildMenu() {
        let menu = controlMenu
        menu.delegate = self

        claudeUsageItem.isEnabled = false
        codexUsageItem.isEnabled = false
        menu.addItem(claudeUsageItem)
        menu.addItem(codexUsageItem)
        menu.addItem(.separator())

        deviceInfoItem.isEnabled = false
        menu.addItem(deviceInfoItem)

        menu.addItem(makeItem("自动查找并配对设备", #selector(autoPairAction)))
        menu.addItem(makeItem("设置设备地址…", #selector(setDeviceAddress)))
        menu.addItem(makeItem("打开设备网页", #selector(openDevicePage)))
        menu.addItem(makeItem(OTAUpdateController.menuTitle, #selector(openFirmwareUpdater)))

        let displayMenu = NSMenu()
        for descriptor in DisplayModeDescriptor.all {
            let item = NSMenuItem(title: descriptor.menuTitle,
                                  action: #selector(setDisplayMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = descriptor.mode
            modeItems[descriptor.mode] = item
            displayMenu.addItem(item)
        }
        let displayItem = NSMenuItem(title: "屏幕显示", action: nil, keyEquivalent: "")
        displayItem.submenu = displayMenu
        menu.addItem(displayItem)
        // (屏幕亮度在左键弹出的镜像页底部，做成滑条了)

        let featureMenu = NSMenu()
        for descriptor in DisplayModeDescriptor.configurable {
            let item = NSMenuItem(title: descriptor.menuTitle,
                                  action: #selector(toggleFeature(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = descriptor.mode
            featureToggleItems[descriptor.mode] = item
            featureMenu.addItem(item)
        }
        let featureItem = NSMenuItem(title: "\u{529F}\u{80FD}\u{914D}\u{7F6E}",
                                     action: nil, keyEquivalent: "")
        featureItem.submenu = featureMenu
        menu.addItem(featureItem)

        let pomodoroMenu = NSMenu()
        pomodoroStatusItem.isEnabled = false
        pomodoroMenu.addItem(pomodoroStatusItem)
        pomodoroToggleItem.target = self
        pomodoroToggleItem.action = #selector(controlPomodoro(_:))
        pomodoroToggleItem.representedObject = "toggle"
        pomodoroMenu.addItem(pomodoroToggleItem)
        for (title, action) in [("\u{91CD}\u{7F6E}\u{672C}\u{9636}\u{6BB5}", "reset"),
                                ("\u{8DF3}\u{8FC7}\u{672C}\u{9636}\u{6BB5}", "skip")] {
            let item = NSMenuItem(title: title, action: #selector(controlPomodoro(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = action
            pomodoroMenu.addItem(item)
        }
        pomodoroMenu.addItem(.separator())
        pomodoroMenu.addItem(makeItem("\u{8BBE}\u{7F6E}\u{65F6}\u{957F}…",
                                      #selector(configurePomodoro)))
        let pomodoroItem = NSMenuItem(title: "\u{756A}\u{8304}\u{65F6}\u{949F}",
                                      action: nil, keyEquivalent: "")
        pomodoroItem.submenu = pomodoroMenu
        featureSpecificItems["pomodoro"] = pomodoroItem
        menu.addItem(pomodoroItem)

        let stockItem = makeItem("设置自选股…", #selector(setStockSymbols))
        featureSpecificItems["stock"] = stockItem
        menu.addItem(stockItem)

        menu.addItem(makeItem("更换桌宠动画…（petdex）", #selector(openPetPicker)))

        let resetMenu = NSMenu()
        for (title, slot) in [("Claude 恢复默认", "claude"), ("Codex 恢复默认", "codex")] {
            let item = NSMenuItem(title: title, action: #selector(resetSprite(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = slot
            resetMenu.addItem(item)
        }
        let resetItem = NSMenuItem(title: "恢复默认动画", action: nil, keyEquivalent: "")
        resetItem.submenu = resetMenu
        menu.addItem(resetItem)

        menu.addItem(makeItem("把本机设为设备桥接", #selector(pointBridgeHere)))
        menu.addItem(.separator())
        menu.addItem(makeItem("刷新", #selector(refreshAction), key: "r"))
        menu.addItem(makeItem("桥接服务地址", #selector(showAddress)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func makeItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: - refresh

    func menuWillOpen(_ menu: NSMenu) {
        applyFeatureConfiguration()
        usage.refresh()
        refreshUsageLines()
        refreshDeviceSection()
    }

    private func refreshUsageLines() {
        claudeUsageItem.title = Self.usageLine(name: "Claude", u: usage.claude, weeklyLabel: "\u{5468}")
        codexUsageItem.title = Self.usageLine(name: "Codex", u: usage.codex, weeklyLabel: "\u{5468}")
    }

    private static func usageLine(name: String, u: ProviderUsage, weeklyLabel: String) -> String {
        if let err = u.error, u.primaryPct == nil { return "\(name)：\(err)" }
        var parts: [String] = []
        if let p = u.primaryPct {
            var s = "5H \(Int(p))%"
            if let m = u.primaryResetMin { s += "（\(fmtMin(m))后重置）" }
            parts.append(s)
        }
        if let p = u.weeklyPct {
            var s = "\(weeklyLabel) \(Int(p))%"
            if let m = u.weeklyResetMin { s += "（\(fmtMin(m))）" }
            parts.append(s)
        }
        return parts.isEmpty ? "\(name)：额度未知" : "\(name)　" + parts.joined(separator: "　")
    }

    private static func fmtMin(_ min: Int) -> String {
        if min >= 48 * 60 { return "\(min / (24 * 60))天" }
        if min >= 60 { return "\(min / 60)h\(min % 60 > 0 ? "\(min % 60)m" : "")" }
        return "\(min)m"
    }

    private func refreshDeviceSection() {
        let host = DeviceClient.host
        deviceInfoItem.title = host.isEmpty ? "设备：正在检查 USB…" : "设备：\(host)（连接中…）"
        DeviceClient.fetchInfo { [weak self] result in
            guard let self = self else { return }
            switch result {
            case let .success(info):
                if DisplayModeDescriptor.descriptor(for: info.mode)?.isConfigurable == true,
                   !self.featurePreferences.isEnabled(info.mode) {
                    DeviceClient.setDisplayMode("auto") { [weak self] _ in
                        self?.refreshDeviceSection()
                    }
                    return
                }
                self.latestDeviceInfo = info
                let sprites = [info.claudeCustomSprite ? "C:自定义" : "C:默认",
                               info.codexCustomSprite ? "X:自定义" : "X:默认"]
                let showing = info.mode == "net" ? "网速"
                    : info.mode == "music" ? "音乐"
                    : info.mode == "stock" ? "股票"
                    : info.mode == "pomodoro" ? "番茄钟"
                    : (info.showing == "claude" ? "Claude" : "Codex")
                self.deviceInfoItem.title =
                    "设备：\(info.ip) · 正在显示 \(showing) · \(sprites.joined(separator: " "))"
                for (mode, item) in self.modeItems { item.state = mode == info.mode ? .on : .off }
                self.updatePomodoroMenu(info)
            case .failure:
                self.latestDeviceInfo = nil
                self.deviceInfoItem.title = host.isEmpty ? "设备：未设置地址或 USB 未连接"
                    : "设备：\(host)（无法连接）"
                self.modeItems.values.forEach { $0.state = .off }
                // self-heal: the device may have moved to a new DHCP address;
                // if it recently polled us from a different IP, adopt that.
                let seen = DeviceClient.lastSeenIP
                if !seen.isEmpty, !host.hasPrefix(seen) {
                    DeviceClient.verifyDevice(ip: seen) { ok in
                        if ok {
                            DeviceClient.host = seen
                            self.refreshDeviceSection()
                        }
                    }
                }
            }
        }
    }

    private func updatePomodoroMenu(_ info: DeviceInfo) {
        let phase = info.pomodoroPhase == "break" ? "\u{4F11}\u{606F}" : "\u{4E13}\u{6CE8}"
        let minutes = max(0, info.pomodoroRemainingS) / 60
        let seconds = max(0, info.pomodoroRemainingS) % 60
        let state = info.pomodoroRunning ? "\u{8FDB}\u{884C}\u{4E2D}" : "\u{5DF2}\u{6682}\u{505C}"
        pomodoroStatusItem.title = String(format: "%@ %02d:%02d · %@ · %@ %d",
                                          phase, minutes, seconds, state,
                                          "\u{5B8C}\u{6210}", info.pomodoroCompleted)
        pomodoroToggleItem.title = info.pomodoroRunning ? "\u{6682}\u{505C}" : "\u{5F00}\u{59CB}"
    }

    // MARK: - pairing

    @objc private func autoPairAction() {
        deviceInfoItem.title = "设备：正在查找…"
        DeviceClient.autoPair(progress: { [weak self] msg in
            self?.deviceInfoItem.title = "设备：\(msg)"
        }, completion: { [weak self] ip in
            if let ip = ip {
                Self.toast("配对成功", "已找到设备并配对：\(ip)")
                self?.refreshDeviceSection()
            } else {
                Self.toast("未找到设备", """
                局域网内没有发现 ESP8266 时钟。请确认：
                1. 设备已通电并连上同一个 WiFi（首次使用需通过 AI-Clock-Setup 热点配网）
                2. 路由器未开启"客户端隔离"
                """)
                self?.refreshDeviceSection()
            }
        })
    }

    // MARK: - actions

    private func applyFeatureConfiguration() {
        for descriptor in DisplayModeDescriptor.configurable {
            let enabled = featurePreferences.isEnabled(descriptor.mode)
            featureToggleItems[descriptor.mode]?.state = enabled ? .on : .off
            modeItems[descriptor.mode]?.isHidden = !enabled
            featureSpecificItems[descriptor.mode]?.isHidden = !enabled
        }
        mirrorPopover.updateEnabledFeatures(featurePreferences.enabledOptionalModes)
    }

    @objc private func toggleFeature(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? String else { return }
        let enabled = !featurePreferences.isEnabled(mode)
        featurePreferences.setEnabled(enabled, for: mode)
        applyFeatureConfiguration()
        featureConfigurationChanged()

        guard !enabled, latestDeviceInfo?.mode == mode else { return }
        DeviceClient.setDisplayMode("auto") { [weak self] error in
            if let error = error {
                Self.toast("\u{5207}\u{6362}\u{5931}\u{8D25}", error.localizedDescription)
            } else {
                self?.refreshDeviceSection()
            }
        }
    }

    @objc private func refreshAction() {
        usage.refresh()
        refreshUsageLines()
        refreshDeviceSection()
    }

    @objc private func setDeviceAddress() {
        let alert = NSAlert()
        alert.messageText = "设备地址"
        alert.informativeText = "ESP8266 时钟的 IP（设备开机时屏幕上会显示，例如 192.168.1.50）"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        input.stringValue = DeviceClient.host
        input.placeholderString = "192.168.1.50"
        alert.accessoryView = input
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            DeviceClient.host = input.stringValue.trimmingCharacters(in: .whitespaces)
            refreshDeviceSection()
        }
    }

    @objc private func openDevicePage() {
        guard let url = DeviceClient.baseURL else {
            setDeviceAddress()
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func openFirmwareUpdater() {
        OTAUpdateController.shared.start()
    }

    @objc private func setDisplayMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? String else { return }
        DeviceClient.setDisplayMode(mode) { [weak self] error in
            if let error = error {
                Self.toast("切换失败", error.localizedDescription)
            } else {
                self?.refreshDeviceSection()
            }
        }
    }

    @objc private func controlPomodoro(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? String else { return }
        DeviceClient.controlPomodoro(action) { [weak self] error in
            if let error = error {
                Self.toast("\u{64CD}\u{4F5C}\u{5931}\u{8D25}", error.localizedDescription)
            } else {
                self?.refreshDeviceSection()
            }
        }
    }

    @objc private func configurePomodoro() {
        let info = latestDeviceInfo
        let alert = NSAlert()
        alert.messageText = "\u{8BBE}\u{7F6E}\u{756A}\u{8304}\u{65F6}\u{949F}"
        alert.informativeText = "\u{4FDD}\u{5B58}\u{540E}\u{4F1A}\u{91CD}\u{7F6E}\u{5F53}\u{524D}\u{8BA1}\u{65F6}\u{FF0C}\u{5E76}\u{5207}\u{6362}\u{5230}\u{4E13}\u{6CE8}\u{9636}\u{6BB5}\u{3002}"
        let focusInput = NSTextField(string: String(info?.pomodoroFocusMinutes ?? 25))
        let breakInput = NSTextField(string: String(info?.pomodoroBreakMinutes ?? 5))
        let focusRow = NSStackView(views: [NSTextField(labelWithString: "\u{4E13}\u{6CE8}\u{5206}\u{949F}"),
                                           focusInput])
        let breakRow = NSStackView(views: [NSTextField(labelWithString: "\u{4F11}\u{606F}\u{5206}\u{949F}"),
                                           breakInput])
        for row in [focusRow, breakRow] {
            row.orientation = .horizontal
            row.distribution = .fillEqually
            row.spacing = 10
        }
        let stack = NSStackView(views: [focusRow, breakRow])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 260, height: 56)
        alert.accessoryView = stack
        alert.addButton(withTitle: "\u{4FDD}\u{5B58}")
        alert.addButton(withTitle: "\u{53D6}\u{6D88}")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let focusMinutes = Int(focusInput.stringValue), (1...120).contains(focusMinutes),
              let breakMinutes = Int(breakInput.stringValue), (1...60).contains(breakMinutes) else {
            Self.toast("\u{65F6}\u{957F}\u{65E0}\u{6548}",
                       "\u{4E13}\u{6CE8}\u{9700}\u{4E3A} 1–120 \u{5206}\u{949F}\u{FF0C}\u{4F11}\u{606F}\u{9700}\u{4E3A} 1–60 \u{5206}\u{949F}\u{3002}")
            return
        }
        DeviceClient.controlPomodoro("configure", focusMinutes: focusMinutes,
                                     breakMinutes: breakMinutes) { [weak self] error in
            if let error = error {
                Self.toast("\u{4FDD}\u{5B58}\u{5931}\u{8D25}", error.localizedDescription)
            } else {
                self?.refreshDeviceSection()
            }
        }
    }

    @objc private func setStockSymbols() {
        let alert = NSAlert()
        alert.messageText = "自选股"
        alert.informativeText = "逗号分隔的腾讯行情代码：sh/sz=A股、hk=港股、us=美股\n例如 sh600519,hk00700,usAAPL（设备最多显示 4 只）"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        input.stringValue = StockMonitor.symbols.joined(separator: ",")
        input.placeholderString = "sh000001,usAAPL"
        alert.accessoryView = input
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            StockMonitor.symbols = input.stringValue.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
    }

    @objc private func openPetPicker() {
        if DeviceClient.host.isEmpty { setDeviceAddress() }
        PetPickerWindowController.shared.show()
    }

    @objc private func resetSprite(_ sender: NSMenuItem) {
        guard let slot = sender.representedObject as? String else { return }
        DeviceClient.resetSprite(slot: slot) { [weak self] error in
            if let error = error {
                Self.toast("恢复失败", error.localizedDescription)
            } else {
                self?.refreshDeviceSection()
            }
        }
    }

    @objc private func pointBridgeHere() {
        guard let ip = DeviceClient.localIPv4() else {
            Self.toast("失败", "获取本机局域网 IP 失败")
            return
        }
        let bridge = "\(ip):\(port)"
        DeviceClient.setBridgeHost(bridge) { error in
            if let error = error {
                Self.toast("设置失败", error.localizedDescription)
            } else {
                Self.toast("已设置", "设备将从 http://\(bridge)/status 拉取状态")
            }
        }
    }

    @objc private func showAddress() {
        let ip = DeviceClient.localIPv4() ?? "<本机局域网IP>"
        Self.toast("桥接服务地址", "http://\(ip):\(port)/status\n\n设备端 Bridge host 填：\(ip):\(port)")
    }

    private static func toast(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
