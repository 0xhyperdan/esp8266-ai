import AppKit

// Live "mirror" of the ESP8266 screen, shown in a popover from the menu-bar
// icon. Not a video stream: the Mac re-renders the same scene from the same
// StatusService snapshot and /api/info identity used by the device.

// MARK: - the 240x240 replica view

private func decodeCover(_ data: Data, w: Int, h: Int) -> CGImage? {
    let frameBytes = w * h * 2
    guard data.count >= frameBytes else { return nil }
    let bytes = [UInt8](data)
    var rgba = [UInt8](repeating: 255, count: w * h * 4)
    var src = 0
    for p in 0..<(w * h) {
        let value = (UInt16(bytes[src]) << 8) | UInt16(bytes[src + 1])
        src += 2
        rgba[p * 4 + 0] = UInt8((value >> 11) & 0x1F) << 3
        rgba[p * 4 + 1] = UInt8((value >> 5) & 0x3F) << 2
        rgba[p * 4 + 2] = UInt8((value & 0x1F) << 3)
    }
    guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
    return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                   bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false,
                   intent: .defaultIntent)
}

final class MirrorView: NSView {
    var printerMode = false
    var printerStatus = PrinterStatus()
    // scene state, all in the device's 240x240 logical coordinates
    var deviceOK = false
    var stockMode = false
    var stockRows: [StockMonitor.Row] = []
    var weatherMode = false
    var weatherImage: NSImage?
    var salaryMode = false
    var salaryEarnedYuan = 0.0
    var salaryRateYuanPerSecond = 0.0
    var salaryDailyWorkS = 8 * 60 * 60
    var salaryStatus = "CONFIGURE SALARY"
    var salaryElapsedS = 0
    var musicMode = false
    var musicTitle = ""
    var musicArtist = ""
    var musicElapsed: Double = 0
    var musicDuration: Double = 0
    var musicPlaying = false
    var musicCover: CGImage?

    override var isFlipped: Bool { true } // draw in the panel's top-left origin

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let scale = bounds.width / 240.0
        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)

        // panel background
        let panel = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 240, height: 240),
                                 xRadius: 10, yRadius: 10)
        NSColor.black.setFill()
        panel.fill()
        panel.addClip()

        if printerMode {
            PrinterScene.draw(printerStatus, deviceOnline: deviceOK)
            ctx.restoreGState()
            return
        }
        if musicMode {
            drawMusicScene(ctx)
            ctx.restoreGState()
            return
        }
        if stockMode {
            drawStockScene()
            ctx.restoreGState()
            return
        }
        if weatherMode {
            if let weatherImage {
                var proposedRect = NSRect(origin: .zero, size: weatherImage.size)
                if let image = weatherImage.cgImage(
                    forProposedRect: &proposedRect,
                    context: NSGraphicsContext.current,
                    hints: nil
                ) {
                    let rect = CGRect(x: 0, y: 0, width: 240, height: 240)
                    ctx.saveGState()
                    ctx.interpolationQuality = .none
                    // Core Graphics images are bottom-up inside this flipped view.
                    ctx.translateBy(x: 0, y: rect.midY)
                    ctx.scaleBy(x: 1, y: -1)
                    ctx.translateBy(x: 0, y: -rect.midY)
                    ctx.draw(image, in: rect)
                    ctx.restoreGState()
                }
            }
            ctx.restoreGState()
            return
        }
        if salaryMode {
            drawSalaryScene()
            ctx.restoreGState()
            return
        }

        if let weatherImage {
            var proposedRect = NSRect(origin: .zero, size: weatherImage.size)
            if let image = weatherImage.cgImage(
                forProposedRect: &proposedRect,
                context: NSGraphicsContext.current,
                hints: nil
            ) {
                ctx.saveGState()
                ctx.interpolationQuality = .none
                ctx.translateBy(x: 0, y: 120)
                ctx.scaleBy(x: 1, y: -1)
                ctx.translateBy(x: 0, y: -120)
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: 240, height: 240))
                ctx.restoreGState()
            }
        }

        if !deviceOK {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let overlay: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14, weight: .bold),
                .foregroundColor: NSColor.systemRed,
                .paragraphStyle: style,
            ]
            ("设备离线" as NSString).draw(in: NSRect(x: 0, y: 60, width: 240, height: 20),
                                          withAttributes: overlay)
        }
        ctx.restoreGState()
    }

    private func drawMusicScene(_ ctx: CGContext) {
        let coverRect = CGRect(x: 56, y: 16, width: 128, height: 128)
        if let musicCover {
            ctx.saveGState()
            ctx.interpolationQuality = .none
            ctx.translateBy(x: 0, y: coverRect.midY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.translateBy(x: 0, y: -coverRect.midY)
            ctx.draw(musicCover, in: coverRect)
            ctx.restoreGState()
        } else {
            ctx.setFillColor(NSColor.darkGray.cgColor)
            ctx.fill(coverRect)
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            ("No Art" as NSString).draw(in: NSRect(x: 56, y: 72, width: 128, height: 20), withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.lightGray,
                .paragraphStyle: style,
            ])
        }

        let titleStyle = NSMutableParagraphStyle()
        titleStyle.alignment = .center
        titleStyle.lineBreakMode = .byTruncatingTail
        let title = musicTitle.isEmpty ? "No Music" : musicTitle
        (title as NSString).draw(in: NSRect(x: 12, y: 154, width: 216, height: 24), withAttributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .bold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: titleStyle,
        ])
        (musicArtist as NSString).draw(in: NSRect(x: 12, y: 178, width: 216, height: 20), withAttributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.lightGray,
            .paragraphStyle: titleStyle,
        ])

        let bar = CGRect(x: 20, y: 210, width: 200, height: 8)
        ctx.setFillColor(NSColor.darkGray.cgColor)
        ctx.fill(bar)
        let frac = musicDuration > 0 ? max(0, min(1, musicElapsed / musicDuration)) : 0
        ctx.setFillColor((musicPlaying ? NSColor.systemGreen : NSColor.gray).cgColor)
        ctx.fill(CGRect(x: bar.minX, y: bar.minY, width: bar.width * frac, height: bar.height))
    }


    // Salary scene mirrors the firmware's poster-style page: black sky, gold
    // coin with ¥, big gold amount, muted rate caption, gold progress bar.
    private func drawSalaryScene() {
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        let gold = NSColor(red: 1.0, green: 207 / 255, blue: 77 / 255, alpha: 1)
        let goldDim = NSColor(red: 200 / 255, green: 151 / 255, blue: 31 / 255, alpha: 1)
        let mark = NSColor(red: 138 / 255, green: 90 / 255, blue: 20 / 255, alpha: 1)
        let muted = NSColor(red: 151 / 255, green: 160 / 255, blue: 181 / 255, alpha: 1)
        let track = NSColor(red: 44 / 255, green: 53 / 255, blue: 80 / 255, alpha: 1)
        let active = salaryStatus == "EARNING NOW"
        let progress = max(0, min(1, Double(salaryElapsedS) / Double(max(1, salaryDailyWorkS))))

        let statusNames = [
            "EARNING NOW": "计薪中",
            "LUNCH BREAK - PAUSED": "午休暂停",
            "WEEKEND - PAUSED": "周末暂停",
            "BEFORE WORK": "上班前",
            "WORKDAY COMPLETE": "已下班",
            "CONFIGURE SALARY": "请先配置薪资",
            "WAITING FOR CLOCK": "等待时钟",
        ]
        let statusText = statusNames[salaryStatus] ?? salaryStatus
        let configured = salaryStatus != "CONFIGURE SALARY"

        ("每秒进账" as NSString).draw(in: NSRect(x: 0, y: 8, width: 240, height: 22), withAttributes: [
            .font: NSFont.systemFont(ofSize: 16, weight: .semibold),
            .foregroundColor: NSColor.white, .paragraphStyle: center,
        ])

        // gold coin with a ¥ mark, same geometry as the firmware's r=30 coin
        let coinCenter = NSPoint(x: 120, y: 64)
        let coin = NSBezierPath(ovalIn: NSRect(x: coinCenter.x - 30, y: coinCenter.y - 30, width: 60, height: 60))
        goldDim.setFill(); coin.fill()
        let face = NSBezierPath(ovalIn: NSRect(x: coinCenter.x - 27, y: coinCenter.y - 27, width: 54, height: 54))
        gold.setFill(); face.fill()
        let ring = NSBezierPath(ovalIn: NSRect(x: coinCenter.x - 21, y: coinCenter.y - 21, width: 42, height: 42))
        ring.lineWidth = 1.5; goldDim.setStroke(); ring.stroke()
        let yen = NSBezierPath()
        yen.lineWidth = 2
        yen.lineCapStyle = .round
        yen.move(to: NSPoint(x: coinCenter.x - 11, y: coinCenter.y - 13))
        yen.line(to: NSPoint(x: coinCenter.x, y: coinCenter.y - 3))
        yen.move(to: NSPoint(x: coinCenter.x + 11, y: coinCenter.y - 13))
        yen.line(to: NSPoint(x: coinCenter.x, y: coinCenter.y - 3))
        yen.move(to: NSPoint(x: coinCenter.x, y: coinCenter.y - 3))
        yen.line(to: NSPoint(x: coinCenter.x, y: coinCenter.y + 14))
        mark.setStroke(); yen.stroke()
        mark.setFill()
        NSRect(x: coinCenter.x - 10, y: coinCenter.y + 2, width: 20, height: 2).fill()
        NSRect(x: coinCenter.x - 10, y: coinCenter.y + 7, width: 20, height: 2).fill()

        let amount = salaryEarnedYuan > 0 ? String(format: "%.2f", salaryEarnedYuan)
            : (configured ? "0.00" : "--")
        let amountText = NSMutableAttributedString(
            string: "\(amount) 元",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 36, weight: .medium),
                .foregroundColor: gold,
                .paragraphStyle: center,
            ])
        amountText.addAttributes(
            [.font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: gold],
            range: NSRange(location: amountText.length - 2, length: 2))
        amountText.draw(in: NSRect(x: 0, y: 98, width: 240, height: 48))

        let rate = salaryRateYuanPerSecond > 0 ? String(format: "+%.4f", salaryRateYuanPerSecond) : "--"
        ("每秒 \(rate) 元" as NSString).draw(in: NSRect(x: 0, y: 150, width: 240, height: 18),
                                          withAttributes: [
                                            .font: NSFont.systemFont(ofSize: 13),
                                            .foregroundColor: muted, .paragraphStyle: center,
                                          ])

        let barRect = NSRect(x: 28, y: 174, width: 184, height: 8)
        track.setFill()
        NSBezierPath(roundedRect: barRect, xRadius: 4, yRadius: 4).fill()
        if progress > 0 {
            let fillWidth = max(8, CGFloat(progress) * barRect.width)
            gold.setFill()
            NSBezierPath(roundedRect: NSRect(x: barRect.origin.x, y: barRect.origin.y,
                                             width: min(fillWidth, barRect.width), height: barRect.height),
                         xRadius: 4, yRadius: 4).fill()
        }

        if configured {
            ("已挣 \(Int((progress * 100).rounded()))%" as NSString).draw(
                in: NSRect(x: 0, y: 188, width: 240, height: 20), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                    .foregroundColor: NSColor.white, .paragraphStyle: center,
                ])
        }
        (statusText as NSString).draw(in: NSRect(x: 0, y: 211, width: 240, height: 18), withAttributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: active ? gold : muted, .paragraphStyle: center,
        ])
    }

    // Stock watchlist, same compact rows as the firmware: grey name on the left,
    // code on the right, big white price, and colored change.
    private func drawStockScene() {
        let grey = NSColor(white: 0.55, alpha: 1)
        let nameFont = NSFont.systemFont(ofSize: 13, weight: .medium)
        let codeFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        let valueFont = NSFont.monospacedSystemFont(ofSize: 17, weight: .bold)
        if stockRows.isEmpty {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            ("未配置自选股\n右键菜单 → 设置自选股…" as NSString).draw(
                in: NSRect(x: 0, y: 104, width: 240, height: 40), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 11), .foregroundColor: grey,
                    .paragraphStyle: style,
                ])
            return
        }
        for (i, row) in stockRows.prefix(5).enumerated() {
            let rowHeight = 220 / max(1, min(5, stockRows.count))
            let y0 = CGFloat(4 + i * rowHeight + (rowHeight - 44) / 2)
            let nameStyle = NSMutableParagraphStyle()
            nameStyle.lineBreakMode = .byTruncatingTail
            (row.name as NSString).draw(
                in: NSRect(x: 14, y: y0, width: 156, height: 17), withAttributes: [
                    .font: nameFont, .foregroundColor: grey, .paragraphStyle: nameStyle,
                ])
            let codeStyle = NSMutableParagraphStyle()
            codeStyle.alignment = .right
            (row.code as NSString).draw(
                in: NSRect(x: 174, y: y0, width: 52, height: 17), withAttributes: [
                    .font: codeFont, .foregroundColor: grey, .paragraphStyle: codeStyle,
                ])
            (row.price as NSString).draw(at: NSPoint(x: 14, y: y0 + 18), withAttributes: [
                .font: valueFont, .foregroundColor: NSColor.white,
            ])
            let pctColor = row.up > 0 ? NSColor(calibratedRed: 1, green: 0.23, blue: 0.19, alpha: 1)
                : (row.up < 0 ? NSColor(calibratedRed: 0, green: 0.85, blue: 0.2, alpha: 1)
                              : NSColor.lightGray)
            let style = NSMutableParagraphStyle()
            style.alignment = .right
            (row.pct as NSString).draw(
                in: NSRect(x: 120, y: y0 + 18, width: 106, height: 22), withAttributes: [
                    .font: valueFont, .foregroundColor: pctColor, .paragraphStyle: style,
                ])
        }
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        ("\u{80A1}\u{7968}" as NSString).draw(
            in: NSRect(x: 0, y: 224, width: 240, height: 12), withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 8, weight: .medium),
                .foregroundColor: grey, .paragraphStyle: center,
            ])
    }

}

// MARK: - popover controller

final class MirrorPopoverController: NSObject, NSPopoverDelegate {
    private let nowPlaying: NowPlayingMonitor
    private let stockMonitor: StockMonitor
    private let weatherMonitor: WeatherMonitor
    private let popover = NSPopover()
    private let mirror = MirrorView()
    private let deviceControl = NSSegmentedControl(labels: [],
                                                   trackingMode: .selectOne, target: nil, action: nil)
    private let modeControl = NSSegmentedControl(labels: [],
                                                 trackingMode: .selectOne, target: nil, action: nil)
    private var selectableModes: [String]
    private var enabledModes: [String] = []
    private let statusLabel = NSTextField(labelWithString: "连接设备中…")
    private let brightnessSlider = NSSlider(value: 100, minValue: 0, maxValue: 100,
                                            target: nil, action: nil)
    private let brightnessValueLabel = NSTextField(labelWithString: "100%")
    // Drag streams many slider events; posts to the single-threaded ESP8266 web
    // server are throttled mid-drag and the final value always flushes on mouse-up.
    private var pendingBrightness: Int?
    private var lastBrightnessSentAt = Date.distantPast

    private var pollTimer: Timer?
    private var weatherAnimationTimer: Timer?
    private var lastInfo: DeviceInfo?
    private var deviceAddresses: [String] = []
    private weak var contentContainer: NSView?
    private var singleDeviceTopConstraint: NSLayoutConstraint?
    private var multipleDeviceTopConstraint: NSLayoutConstraint?

    init(nowPlaying: NowPlayingMonitor,
         stockMonitor: StockMonitor, weatherMonitor: WeatherMonitor,
         enabledOptionalModes: [String]) {
        self.nowPlaying = nowPlaying
        self.stockMonitor = stockMonitor
        self.weatherMonitor = weatherMonitor
        self.enabledModes = enabledOptionalModes
        self.selectableModes = DisplayModeDescriptor.selectableModes(
            enabledOptionalModes: enabledOptionalModes
        )
        super.init()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = makeContent()
    }

    private func makeContent() -> NSViewController {
        let vc = NSViewController()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 316, height: 424))
        contentContainer = container

        deviceControl.target = self
        deviceControl.action = #selector(deviceChanged)
        deviceControl.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        deviceControl.segmentStyle = .rounded
        deviceControl.isHidden = true

        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.font = NSFont.systemFont(ofSize: 11)
        configureModeControl()
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.lineBreakMode = .byTruncatingMiddle

        brightnessSlider.target = self
        brightnessSlider.action = #selector(brightnessChanged)
        brightnessSlider.isContinuous = true
        brightnessValueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        brightnessValueLabel.textColor = .secondaryLabelColor
        brightnessValueLabel.alignment = .right
        let brightnessIcon = NSImageView(image: NSImage(systemSymbolName: "sun.max.fill",
                                                        accessibilityDescription: "亮度") ?? NSImage())
        brightnessIcon.contentTintColor = .secondaryLabelColor

        for v in [deviceControl, mirror, modeControl, brightnessIcon, brightnessSlider,
                  brightnessValueLabel, statusLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
        }
        let singleDeviceTop = mirror.topAnchor.constraint(equalTo: container.topAnchor, constant: 14)
        let multipleDeviceTop = mirror.topAnchor.constraint(equalTo: deviceControl.bottomAnchor, constant: 8)
        singleDeviceTopConstraint = singleDeviceTop
        multipleDeviceTopConstraint = multipleDeviceTop
        NSLayoutConstraint.activate([
            deviceControl.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            deviceControl.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            deviceControl.widthAnchor.constraint(equalToConstant: 288),
            singleDeviceTop,
            mirror.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            mirror.widthAnchor.constraint(equalToConstant: 288),
            mirror.heightAnchor.constraint(equalToConstant: 288),
            modeControl.topAnchor.constraint(equalTo: mirror.bottomAnchor, constant: 12),
            modeControl.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            modeControl.widthAnchor.constraint(equalToConstant: 288),
            brightnessIcon.centerYAnchor.constraint(equalTo: brightnessSlider.centerYAnchor),
            brightnessIcon.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            brightnessSlider.topAnchor.constraint(equalTo: modeControl.bottomAnchor, constant: 10),
            brightnessSlider.leadingAnchor.constraint(equalTo: brightnessIcon.trailingAnchor, constant: 8),
            brightnessSlider.trailingAnchor.constraint(equalTo: brightnessValueLabel.leadingAnchor, constant: -8),
            brightnessValueLabel.centerYAnchor.constraint(equalTo: brightnessSlider.centerYAnchor),
            brightnessValueLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            brightnessValueLabel.widthAnchor.constraint(equalToConstant: 40),
            statusLabel.topAnchor.constraint(equalTo: brightnessSlider.bottomAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            statusLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
        ])
        vc.view = container
        return vc
    }

    private func refreshDeviceControl() {
        let addresses = DeviceClient.deviceAddresses
        configureDeviceControl(addresses: addresses, selectedAddress: DeviceClient.host)
    }

    private func configureDeviceControl(addresses: [String], selectedAddress: String) {
        guard addresses != deviceAddresses else {
            deviceControl.selectedSegment = addresses.firstIndex(of: selectedAddress) ?? 0
            return
        }
        deviceAddresses = addresses
        deviceControl.segmentCount = addresses.count
        let width = addresses.isEmpty ? 0 : 288.0 / CGFloat(addresses.count)
        for (index, address) in addresses.enumerated() {
            deviceControl.setLabel(DeviceClient.displayName(for: address), forSegment: index)
            deviceControl.setToolTip(address, forSegment: index)
            deviceControl.setWidth(width, forSegment: index)
        }
        deviceControl.selectedSegment = addresses.firstIndex(of: selectedAddress) ?? 0

        let multiple = addresses.count > 1
        deviceControl.isHidden = !multiple
        singleDeviceTopConstraint?.isActive = !multiple
        multipleDeviceTopConstraint?.isActive = multiple
        let size = NSSize(width: 316, height: multiple ? 454 : 424)
        contentContainer?.frame.size = size
        popover.contentViewController?.preferredContentSize = size
        popover.contentSize = size
    }

    #if DEBUG
    func prepareDesignQASnapshot(addresses: [String], selectedAddress: String) -> NSView {
        configureDeviceControl(addresses: addresses, selectedAddress: selectedAddress)
        guard let view = popover.contentViewController?.view else {
            preconditionFailure("Popover content view is unavailable")
        }
        view.layoutSubtreeIfNeeded()
        return view
    }
    #endif

    func updateEnabledFeatures(_ enabledOptionalModes: [String]) {
        enabledModes = enabledOptionalModes
        selectableModes = DisplayModeDescriptor.selectableModes(
            enabledOptionalModes: enabledOptionalModes,
            printerSupported: lastInfo?.printer.supported ?? false
        )
        configureModeControl()
    }

    private func configureModeControl() {
        let selectedMode = lastInfo.map { DisplayModeDescriptor.normalizedMode($0.mode) }
        modeControl.segmentCount = selectableModes.count
        let preferredWidth = selectableModes.reduce(0.0) { total, mode in
            total + (DisplayModeDescriptor.descriptor(for: mode)?.preferredWidth ?? 36)
        }
        let widthScale = preferredWidth > 0 ? 288.0 / preferredWidth : 1
        for (index, mode) in selectableModes.enumerated() {
            guard let descriptor = DisplayModeDescriptor.descriptor(for: mode) else { continue }
            modeControl.setLabel(descriptor.segmentTitle, forSegment: index)
            modeControl.setWidth(descriptor.preferredWidth * widthScale, forSegment: index)
        }
        modeControl.selectedSegment = selectedMode.flatMap(selectableModes.firstIndex(of:)) ?? 0
    }

    // MARK: - brightness slider

    @objc private func brightnessChanged() {
        let level = Int(brightnessSlider.doubleValue.rounded())
        brightnessValueLabel.stringValue = "\(level)%"
        let isFinal = NSApp.currentEvent.map { $0.type != .leftMouseDragged } ?? true
        pendingBrightness = level
        if !isFinal && Date().timeIntervalSince(lastBrightnessSentAt) < 0.25 { return }
        flushBrightness()
    }

    private func flushBrightness() {
        guard let level = pendingBrightness else { return }
        pendingBrightness = nil
        lastBrightnessSentAt = Date()
        DeviceClient.setBrightness(level) { _ in }
    }

    func toggle(relativeTo button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
                refreshDeviceControl()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            startTimers()
            tick()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        stopTimers()
    }

    func prepareForSystemSleep() {
        stopTimers()
        if popover.isShown { popover.performClose(nil) }
    }

    private func stopTimers() {
        pollTimer?.invalidate()
        weatherAnimationTimer?.invalidate()
        pollTimer = nil
        weatherAnimationTimer = nil
    }

    private func startTimers() {
        pollTimer?.invalidate()
        weatherAnimationTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        weatherAnimationTimer = Timer.scheduledTimer(
            withTimeInterval: Double(WeatherMonitor.astronautFrameIntervalMilliseconds) / 1000,
            repeats: true
        ) { [weak self] _ in
            guard let self, self.popover.isShown, self.mirror.weatherMode else { return }
            self.mirror.weatherImage = self.weatherMonitor.screenImage()
            self.mirror.needsDisplay = true
        }
    }

    private func tick() {
        refreshDeviceControl()
        let requestedAddress = DeviceClient.host
        DeviceClient.fetchInfo { [weak self] result in
            guard let self = self, self.popover.isShown,
                  requestedAddress == DeviceClient.host else { return }
            switch result {
            case let .success(info):
                let changedPrinterSupport = self.lastInfo?.printer.supported != info.printer.supported
                self.lastInfo = info
                if changedPrinterSupport { self.updateEnabledFeatures(self.enabledModes) }
                self.mirror.deviceOK = true
                self.applyScene(info)
                self.syncBrightness(info)
                let selectedMode = DisplayModeDescriptor.normalizedMode(info.mode)
                self.modeControl.selectedSegment =
                    self.selectableModes.firstIndex(of: selectedMode) ?? 0
                let modeText = info.mode == "music" ? "音乐播放"
                    : info.mode == "stock" ? "股票行情"
                    : info.mode == "weather"
                        ? "\u{5929}\u{6C14}\u{65F6}\u{949F}"
                    : info.mode == "printer" ? "打印机状态"
                    : info.mode == "salary" ? "工资进账" : "固定显示"
                self.statusLabel.stringValue = "\(info.ip) · \(modeText) · 数据 \(info.bridge)"
            case .failure:
                self.mirror.deviceOK = false
                self.mirror.needsDisplay = true
                self.statusLabel.stringValue = requestedAddress.isEmpty
                    ? "未设置设备地址（右键菜单 → 添加设备地址）" : "无法连接 \(requestedAddress)"
            }
        }
    }

    /// Follow the device's reported brightness (changed via its web page or
    /// another client) — but never while the user is mid-adjustment here.
    private func syncBrightness(_ info: DeviceInfo) {
        guard pendingBrightness == nil,
              Date().timeIntervalSince(lastBrightnessSentAt) > 2 else { return }
        brightnessSlider.doubleValue = Double(info.brightness)
        brightnessValueLabel.stringValue = "\(info.brightness)%"
    }

    /// Mirrors the effective device page from the same host snapshot.
    private func applyScene(_ info: DeviceInfo) {
        mirror.printerMode = info.effective == "printer"
        mirror.printerStatus = info.printer
        // Mirror what is actually on the device screen; the default weather
        // page can still be temporarily promoted to music by the heartbeat.
        mirror.musicMode = info.effective == "music"
        mirror.stockMode = info.effective == "stock"
        mirror.weatherMode = info.effective == "weather"
        mirror.salaryMode = info.effective == "salary"
        if mirror.weatherMode {
            mirror.weatherImage = weatherMonitor.screenImage()
            mirror.needsDisplay = true
            return
        }
        if mirror.salaryMode {
            mirror.salaryEarnedYuan = info.salaryEarnedYuan
            mirror.salaryRateYuanPerSecond = info.salaryRateYuanPerSecond
            mirror.salaryDailyWorkS = info.salaryDailyWorkS
            mirror.salaryElapsedS = info.salaryElapsedS
            mirror.salaryStatus = info.salaryStatus
            mirror.needsDisplay = true
            return
        }
        if mirror.stockMode {
            mirror.stockRows = stockMonitor.snapshot
            mirror.needsDisplay = true
            return
        }
        if mirror.musicMode {
            let s = nowPlaying.snapshot
            mirror.musicTitle = s.title
            mirror.musicArtist = s.artist
            mirror.musicElapsed = s.elapsed
            mirror.musicDuration = s.duration
            mirror.musicPlaying = s.playing
            mirror.musicCover = decodeCover(nowPlaying.coverRGB565, w: 128, h: 128)
            mirror.needsDisplay = true
            return
        }
        mirror.weatherMode = true
        mirror.weatherImage = weatherMonitor.screenImage()
        mirror.needsDisplay = true
    }

    @objc private func modeChanged() {
        guard selectableModes.indices.contains(modeControl.selectedSegment) else { return }
        let mode = selectableModes[modeControl.selectedSegment]
        statusLabel.stringValue = "正在切换…"
        DeviceClient.setDisplayMode(mode) { [weak self] error in
            guard let self else { return }
            if error != nil {
                let confirmedMode = self.lastInfo.map {
                    DisplayModeDescriptor.normalizedMode($0.mode)
                } ?? "weather"
                self.modeControl.selectedSegment =
                    self.selectableModes.firstIndex(of: confirmedMode) ?? 0
                self.mirror.deviceOK = false
                self.mirror.needsDisplay = true
                self.statusLabel.stringValue = DeviceClient.host.isEmpty
                    ? "切换失败：未设置设备地址"
                    : "切换失败：无法连接 \(DeviceClient.host)"
                return
            }
            self.tick()
        }
    }

    @objc private func deviceChanged() {
        guard deviceAddresses.indices.contains(deviceControl.selectedSegment) else { return }
        DeviceClient.selectDevice(deviceAddresses[deviceControl.selectedSegment])
        lastInfo = nil
        pendingBrightness = nil
        mirror.deviceOK = false
        statusLabel.stringValue = "连接 \(DeviceClient.host)…"
        tick()
    }
}
