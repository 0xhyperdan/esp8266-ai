import AppKit

// Menu-bar item: a retro Macintosh icon drawn with a fixed black background.
// Left click opens a live mirror of the ESP8266
// screen (MirrorPopover); right click opens the control menu with device and
// dashboard controls.
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let port: UInt16
    private let featurePreferences: FeaturePreferences
    private let featureConfigurationChanged: () -> Void
    private let weatherMonitor: WeatherMonitor
    private let controlMenu = NSMenu()
    private let mirrorPopover: MirrorPopoverController

    private let deviceInfoItem = NSMenuItem(title: "设备：未设置", action: nil, keyEquivalent: "")
    private let deviceSelectionMenu = NSMenu()
    private let autoRotateItem = NSMenuItem(title: "自动旋转屏幕", action: nil, keyEquivalent: "")
    private let printerSettingsItem = NSMenuItem(title: "打印机设置…", action: nil, keyEquivalent: "")
    private let weatherLocationItem = NSMenuItem(
        title: "\u{5929}\u{6C14}\u{5730}\u{533A}\u{2026}",
        action: nil,
        keyEquivalent: ""
    )
    private var modeItems: [String: NSMenuItem] = [:]
    private var featureToggleItems: [String: NSMenuItem] = [:]
    private var featureSpecificItems: [String: NSMenuItem] = [:]
    private var latestDeviceInfo: DeviceInfo?

    init(nowPlaying: NowPlayingMonitor, stockMonitor: StockMonitor,
         weatherMonitor: WeatherMonitor, port: UInt16,
         featurePreferences: FeaturePreferences = .shared,
         featureConfigurationChanged: @escaping () -> Void = {}) {
        self.port = port
        self.featurePreferences = featurePreferences
        self.featureConfigurationChanged = featureConfigurationChanged
        self.weatherMonitor = weatherMonitor
        self.mirrorPopover = MirrorPopoverController(nowPlaying: nowPlaying,
                                                     stockMonitor: stockMonitor,
                                                     weatherMonitor: weatherMonitor,
                                                     enabledOptionalModes:
                                                        featurePreferences.enabledOptionalModes)
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

        deviceInfoItem.isEnabled = false
        menu.addItem(deviceInfoItem)

        let deviceSelectionItem = NSMenuItem(title: "选择设备", action: nil, keyEquivalent: "")
        deviceSelectionItem.submenu = deviceSelectionMenu
        menu.addItem(deviceSelectionItem)

        menu.addItem(makeItem("自动查找并配对设备", #selector(autoPairAction)))
        menu.addItem(makeItem("添加设备地址…", #selector(setDeviceAddress)))
        menu.addItem(makeItem("移除当前设备", #selector(removeCurrentDevice)))
        menu.addItem(makeItem("打开设备网页", #selector(openDevicePage)))
        printerSettingsItem.target = self
        printerSettingsItem.action = #selector(openPrinterSettings)
        printerSettingsItem.isHidden = true
        menu.addItem(printerSettingsItem)
        menu.addItem(makeItem(OTAUpdateController.menuTitle, #selector(openFirmwareUpdater)))

        let displayMenu = NSMenu()
        for descriptor in DisplayModeDescriptor.all {
            let item = NSMenuItem(title: descriptor.menuTitle,
                                  action: #selector(setDisplayMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = descriptor.mode
            modeItems[descriptor.mode] = item
            if descriptor.mode == "printer" { item.isHidden = true }
            displayMenu.addItem(item)
        }
        let displayItem = NSMenuItem(title: "屏幕显示", action: nil, keyEquivalent: "")
        displayItem.submenu = displayMenu
        menu.addItem(displayItem)
        autoRotateItem.target = self
        autoRotateItem.action = #selector(toggleAutoRotate)
        autoRotateItem.isHidden = true
        menu.addItem(autoRotateItem)
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

        let salaryItem = makeItem("设置工资进账…", #selector(configureSalary))
        featureSpecificItems["salary"] = salaryItem
        menu.addItem(salaryItem)

        let stockItem = makeItem("设置自选股…", #selector(setStockSymbols))
        featureSpecificItems["stock"] = stockItem
        menu.addItem(stockItem)

        weatherLocationItem.target = self
        weatherLocationItem.action = #selector(configureWeatherLocation)
        featureSpecificItems["weather"] = weatherLocationItem
        menu.addItem(weatherLocationItem)

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
        refreshWeatherLocationItem()
        refreshDeviceSection()
    }

    private func refreshDeviceSection() {
        let host = DeviceClient.host
        refreshDeviceSelectionMenu()
        let addresses = DeviceClient.deviceAddresses
        let position = addresses.firstIndex(of: host).map { "\($0 + 1)/\(addresses.count)" }
        deviceInfoItem.title = host.isEmpty ? "设备：正在检查 USB…"
            : "设备\(position.map { " \($0)" } ?? "")：\(host)（连接中…）"
        DeviceClient.fetchInfo { [weak self] result in
            guard let self = self, host == DeviceClient.host else { return }
            switch result {
            case let .success(info):
                if DisplayModeDescriptor.descriptor(for: info.mode)?.isConfigurable == true,
                   !self.featurePreferences.isEnabled(info.mode) {
                    DeviceClient.setDisplayMode("weather") { [weak self] _ in
                        self?.refreshDeviceSection()
                    }
                    return
                }
                self.latestDeviceInfo = info
                self.printerSettingsItem.isHidden = !info.printer.supported
                self.modeItems["printer"]?.isHidden = !info.printer.supported
                let showing = info.effective == "music" ? "音乐"
                    : info.effective == "stock" ? "股票"
                    : info.effective == "weather"
                        ? "\u{5929}\u{6C14}\u{65F6}\u{949F}"
                    : info.effective == "printer" ? "打印机状态"
                    : info.effective == "salary" ? "工资进账" : "天气时钟"
                var details = ["正在显示 \(showing)"]
                if info.batterySupported {
                    if info.batteryPresent {
                        let charging = info.batteryCharging ? " · 充电中" : ""
                        details.append("电池 \(info.batteryLevel)%\(charging)")
                    } else {
                        details.append("未安装电池")
                    }
                }
                self.deviceInfoItem.title =
                    "设备\(position.map { " \($0)" } ?? "")：\(info.ip) · " +
                    details.joined(separator: " · ")
                let selectedMode = DisplayModeDescriptor.normalizedMode(info.mode)
                for (mode, item) in self.modeItems {
                    item.state = mode == selectedMode ? .on : .off
                }
                self.autoRotateItem.isHidden = !info.autoRotateSupported
                self.autoRotateItem.state = info.autoRotateEnabled ? .on : .off
            case .failure:
                self.printerSettingsItem.isHidden = true
                self.modeItems["printer"]?.isHidden = true
                self.latestDeviceInfo = nil
                self.deviceInfoItem.title = host.isEmpty ? "设备：未设置地址或 USB 未连接"
                    : "设备：\(host)（无法连接）"
                self.modeItems.values.forEach { $0.state = .off }
                self.autoRotateItem.isHidden = true
                self.autoRotateItem.state = .off
                // Keep a single-device installation self-healing. With multiple
                // devices, the latest poll may belong to a different clock.
                let seen = DeviceClient.lastSeenIP
                if addresses.count <= 1, !seen.isEmpty, !host.hasPrefix(seen) {
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

    private func refreshDeviceSelectionMenu() {
        deviceSelectionMenu.removeAllItems()
        let addresses = DeviceClient.deviceAddresses
        if addresses.isEmpty {
            let item = NSMenuItem(title: "未发现设备", action: nil, keyEquivalent: "")
            item.isEnabled = false
            deviceSelectionMenu.addItem(item)
            return
        }
        for address in addresses {
            let item = NSMenuItem(title: DeviceClient.displayName(for: address),
                                  action: #selector(selectDevice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = address
            item.state = address == DeviceClient.host ? .on : .off
            deviceSelectionMenu.addItem(item)
        }
    }

    private func refreshWeatherLocationItem() {
        let configuration = weatherMonitor.locationConfiguration
        let source = configuration.mode == .automatic
            ? "\u{81EA}\u{52A8}"
            : "\u{624B}\u{52A8}"
        weatherLocationItem.title =
            "\u{5929}\u{6C14}\u{5730}\u{533A}\u{FF1A}\(configuration.location.city)\u{FF08}\(source)\u{FF09}\u{2026}"
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
                局域网内没有发现小屏幕设备。请确认：
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
        DeviceClient.setDisplayMode("weather") { [weak self] error in
            if let error = error {
                Self.toast("\u{5207}\u{6362}\u{5931}\u{8D25}", error.localizedDescription)
            } else {
                self?.refreshDeviceSection()
            }
        }
    }

    @objc private func refreshAction() {
        refreshDeviceSection()
    }

    @objc private func setDeviceAddress() {
        let alert = NSAlert()
        alert.messageText = "添加设备地址"
        alert.informativeText = "小屏幕设备的 IP（设备开机时屏幕上会显示，例如 192.168.1.50）"
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

    @objc private func selectDevice(_ sender: NSMenuItem) {
        guard let address = sender.representedObject as? String else { return }
        DeviceClient.selectDevice(address)
        latestDeviceInfo = nil
        refreshDeviceSection()
    }

    @objc private func removeCurrentDevice() {
        let address = DeviceClient.host
        guard !address.isEmpty else { return }
        DeviceClient.removeDevice(address)
        latestDeviceInfo = nil
        refreshDeviceSection()
    }

    @objc private func openDevicePage() {
        guard let url = DeviceClient.baseURL else {
            setDeviceAddress()
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func openPrinterSettings() {
        if latestDeviceInfo?.printer.supported == true,
           latestDeviceInfo?.printer.native == false {
            PrinterBridgeSettings.show()
            return
        }
        guard latestDeviceInfo?.printer.supported == true,
              let baseURL = DeviceClient.baseURL else {
            Self.toast("打印机设置", "请先选择已连接 Wi-Fi 的 ESP32-S3 设备。")
            return
        }
        NSWorkspace.shared.open(baseURL.appendingPathComponent("printer"))
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

    @objc private func toggleAutoRotate() {
        guard let info = latestDeviceInfo, info.autoRotateSupported else { return }
        DeviceClient.setAutoRotate(!info.autoRotateEnabled) { [weak self] error in
            if let error = error {
                Self.toast("设置失败", error.localizedDescription)
            } else {
                self?.refreshDeviceSection()
            }
        }
    }

    @objc private func configureSalary() {
        let info = latestDeviceInfo
        let alert = NSAlert()
        alert.messageText = "工资进账设置"
        alert.informativeText = "按中国标准月工作日 21.75 天计算：月薪 ÷ 21.75 ÷ 每日净工作秒数。午休时暂停计薪。"

        let monthlyInput = NSTextField(string: String(format: "%.2f", info?.salaryMonthlyYuan ?? 0))
        let startInput = NSTextField(string: Self.salaryTimeText(info?.salaryStartMin ?? 9 * 60))
        let endInput = NSTextField(string: Self.salaryTimeText(info?.salaryEndMin ?? 18 * 60))
        let lunchStartInput = NSTextField(string: Self.salaryTimeText(info?.salaryLunchStartMin ?? 12 * 60))
        let lunchEndInput = NSTextField(string: Self.salaryTimeText(info?.salaryLunchEndMin ?? 13 * 60))
        let rows: [(String, NSTextField)] = [
            ("月薪（元）", monthlyInput),
            ("上班时间（HH:mm）", startInput),
            ("下班时间（HH:mm）", endInput),
            ("午休开始（HH:mm）", lunchStartInput),
            ("午休结束（HH:mm）", lunchEndInput),
        ]
        let stack = NSStackView(views: rows.map { title, input in
            let label = NSTextField(labelWithString: title)
            let row = NSStackView(views: [label, input])
            row.orientation = .horizontal
            row.distribution = .fill
            row.spacing = 10
            // NSTextField(string:) 没有 intrinsic size，.fill 行会把输入框压成 0 宽，需钉住宽度
            label.widthAnchor.constraint(equalToConstant: 132).isActive = true
            input.widthAnchor.constraint(equalToConstant: 110).isActive = true
            return row
        })
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: 5 * 26 + 4 * 8)
        alert.accessoryView = stack
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        func parseTime(_ value: String) -> Int? {
            let parts = value.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
                  (0...23).contains(hour), (0...59).contains(minute) else { return nil }
            return hour * 60 + minute
        }
        let normalizedSalary = monthlyInput.stringValue.replacingOccurrences(of: ",", with: ".")
        guard let monthlyYuan = Double(normalizedSalary), monthlyYuan >= 0,
              monthlyYuan <= 10_000_000,
              let startMin = parseTime(startInput.stringValue),
              let endMin = parseTime(endInput.stringValue),
              let lunchStartMin = parseTime(lunchStartInput.stringValue),
              let lunchEndMin = parseTime(lunchEndInput.stringValue),
              startMin < endMin,
              lunchStartMin >= startMin, lunchEndMin <= endMin,
              lunchStartMin <= lunchEndMin else {
            Self.toast("设置无效", "请检查月薪和时间：午休必须位于上班到下班之间。")
            return
        }
        DeviceClient.configureSalary(monthlyYuan: monthlyYuan, startMin: startMin,
                                     endMin: endMin, lunchStartMin: lunchStartMin,
                                     lunchEndMin: lunchEndMin) { [weak self] error in
            if let error = error {
                Self.toast("保存失败", error.localizedDescription)
            } else {
                self?.refreshDeviceSection()
            }
        }
    }

    private static func salaryTimeText(_ minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60, minute % 60)
    }

    @objc private func setStockSymbols() {
        let alert = NSAlert()
        alert.messageText = "自选股"
        alert.informativeText = "逗号分隔的腾讯行情代码：sh/sz=A股、hk=港股、us=美股\n例如 sh600519,hk00700,usAAPL（设备最多显示 5 只）"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        input.stringValue = StockMonitor.symbols.joined(separator: ",")
        input.placeholderString = "sh000001,usAAPL"
        alert.accessoryView = input
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            stockMonitor.updateSymbols(input.stringValue.replacingOccurrences(of: "，", with: ",")
                .split(separator: ",").map { String($0) })
        }
    }

    @objc private func configureWeatherLocation() {
        let configuration = weatherMonitor.locationConfiguration
        let alert = NSAlert()
        alert.messageText = "\u{5929}\u{6C14}\u{5730}\u{533A}"
        alert.informativeText =
            "\u{81EA}\u{52A8}\u{6A21}\u{5F0F}\u{4F7F}\u{7528} macOS \u{7CFB}\u{7EDF}\u{5B9A}\u{4F4D}\u{FF08}\u{5305}\u{62EC} Wi-Fi \u{5B9A}\u{4F4D}\u{FF09}\u{3002}\u{624B}\u{52A8}\u{6A21}\u{5F0F}\u{8F93}\u{5165}\u{57CE}\u{5E02}\u{540D}\u{5373}\u{53EF}\u{3002}"

        let mode = NSPopUpButton(frame: .zero, pullsDown: false)
        mode.addItems(withTitles: [
            "\u{81EA}\u{52A8}\u{5B9A}\u{4F4D}",
            "\u{624B}\u{52A8}\u{57CE}\u{5E02}",
        ])
        mode.selectItem(at: configuration.mode == .automatic ? 0 : 1)

        let input = NSTextField(string: configuration.location.city)
        input.placeholderString = "\u{4F8B}\u{5982}\u{FF1A}\u{4E0A}\u{6D77}\u{3001}\u{82CF}\u{5DDE}\u{3001}\u{5317}\u{4EAC}"
        let modeRow = NSStackView(views: [
            NSTextField(labelWithString: "\u{6A21}\u{5F0F}"),
            mode,
        ])
        let cityRow = NSStackView(views: [
            NSTextField(labelWithString: "\u{57CE}\u{5E02}"),
            input,
        ])
        for row in [modeRow, cityRow] {
            row.orientation = .horizontal
            row.distribution = .fill
            row.spacing = 10
            row.views.first?.widthAnchor.constraint(equalToConstant: 44).isActive = true
        }
        let stack = NSStackView(views: [modeRow, cityRow])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: 58)
        alert.accessoryView = stack
        alert.addButton(withTitle: "\u{4FDD}\u{5B58}")
        alert.addButton(withTitle: "\u{53D6}\u{6D88}")

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        weatherLocationItem.title =
            "\u{5929}\u{6C14}\u{5730}\u{533A}\u{FF1A}\u{6B63}\u{5728}\u{66F4}\u{65B0}\u{2026}"

        if mode.indexOfSelectedItem == 0 {
            weatherMonitor.useAutomaticLocation { [weak self] result in
                self?.handleWeatherLocationResult(result)
            }
        } else {
            let city = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            weatherMonitor.setManualCity(city) { [weak self] result in
                self?.handleWeatherLocationResult(result)
            }
        }
    }

    private func handleWeatherLocationResult(_ result: Result<WeatherLocation, Error>) {
        refreshWeatherLocationItem()
        switch result {
        case let .success(location):
            Self.toast(
                "\u{5929}\u{6C14}\u{5730}\u{533A}\u{5DF2}\u{66F4}\u{65B0}",
                "\u{5DF2}\u{5207}\u{6362}\u{5230}\u{FF1A}\(location.city)"
            )
        case let .failure(error):
            Self.toast(
                "\u{5929}\u{6C14}\u{5730}\u{533A}\u{66F4}\u{65B0}\u{5931}\u{8D25}",
                error.localizedDescription
            )
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
