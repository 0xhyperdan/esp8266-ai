import Foundation

// Wired (USB serial) transport to the clock, for WiFi networks with client
// isolation - or for skipping WiFi setup entirely. Scans for CH340 and native
// serial ports, handshakes, then pushes the same payloads the device would
// otherwise poll over HTTP, as newline-terminated frames:
//   bridge -> device:  #HELLO   #INFO   #STATUS {json}   #CMD {json}
//                       #STOCK_NAMES_BEGIN {json}
//                       #STOCK_NAMES_CHUNK <seq> <base64>   #STOCK_NAMES_END
//                       #WEATHER {json}   #WEATHER_ASSET_BEGIN {json}
//                       #WEATHER_ASSET_CHUNK <seq> <base64>   #WEATHER_ASSET_END
//   device -> bridge:  #DEVICE {"name":"aiclock","fw":"x.y.z"}
//                       #ACK status
// Device log lines (anything not starting with '#') are ignored.
//
// Set AICLOCK_SERIAL_PORT to pin the bridge to one device. The automatic scan
// remains the default when the variable is absent.
//
// NOTE: quit the app before flashing so the two serial clients do not race.
final class SerialLink {
    private enum StockNamesUploadPhase {
        case waitingReady
        case waitingAcknowledgement(Int)
        case waitingDone
    }

    private struct StockNamesUpload {
        let data: Data
        let revision: Int
        var offset = 0
        var sequence = 0
        var phase = StockNamesUploadPhase.waitingReady
        var deadline = Date().addingTimeInterval(10)
    }

    private enum WeatherAssetKind: String {
        case screen
        case astronaut
    }

    private enum WeatherAssetUploadPhase {
        case waitingReady
        case waitingAcknowledgement(Int)
        case waitingDone
    }

    private struct WeatherAssetUpload {
        let data: Data
        let kind: WeatherAssetKind
        let revision: Int
        let decodedSize: Int
        let frames: Int
        var offset = 0
        var sequence = 0
        var phase = WeatherAssetUploadPhase.waitingReady
        var deadline = Date().addingTimeInterval(15)
    }

    private static let stockNamesChunkSize = 384
    private static let maximumStockNamesBytes = 1 + 5 * StockMonitor.nameW * StockMonitor.nameH * 2
    private static let weatherAssetChunkSize = 768
    private static let maximumWeatherAssetBytes = 256 * 1024

    private let service: StatusService
    private let stockMonitor: StockMonitor
    private let weatherMonitor: WeatherMonitor
    private let featurePreferences: FeaturePreferences
    private let printerStatusProvider: () -> PrinterStatus

    private var fd: Int32 = -1
    private var portPath = ""
    private var linked = false // saw #DEVICE from the clock on this port
    private var dataConfirmed = false // saw a parsed status acknowledgement
    private var lastStatusConfirmedAt = Date.distantPast
    private var displayMode = "weather"
    private var brightness = 100
    private var openedAt = Date.distantPast
    private var lastHelloAt = Date.distantPast
    private var lastStatusAt = Date.distantPast
    private var lastPrinterAt = Date.distantPast
    private var lastInfoAt = Date.distantPast
    private var rxBuf = Data()
    private var timer: Timer?
    private(set) var isRunning = false
    private var stockNamesUpload: StockNamesUpload?
    private var uploadedStockNamesRevision = -1
    private var lastStockNamesUploadAttemptAt = Date.distantPast
    private var weatherAssetUpload: WeatherAssetUpload?
    private var uploadedWeatherScreenRevision = -1
    private var uploadedWeatherAstronautRevision = -1
    private var lastWeatherAssetUploadAttemptAt = Date.distantPast
    private var reportedInfo = DeviceInfo()

    init(service: StatusService, stockMonitor: StockMonitor,
         weatherMonitor: WeatherMonitor,
         featurePreferences: FeaturePreferences = .shared,
         printerStatusProvider: @escaping () -> PrinterStatus = { PrinterBridge.shared.snapshot() }) {
        self.service = service
        self.stockMonitor = stockMonitor
        self.weatherMonitor = weatherMonitor
        self.featurePreferences = featurePreferences
        self.printerStatusProvider = printerStatusProvider
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        // one 250ms tick drives everything: port scan, handshake, reads, pushes
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        timer?.invalidate()
        timer = nil
        closePort()
    }

    var isLinked: Bool { linked }

    var deviceInfo: DeviceInfo? {
        guard linked, dataConfirmed,
              Date().timeIntervalSince(lastStatusConfirmedAt) < 15 else { return nil }

        var info = reportedInfo
        if info.ip.isEmpty { info.ip = portPath }
        info.ssid = "USB"
        info.bridge = "USB serial"
        info.lastUpdateS = Int(Date().timeIntervalSince(lastStatusConfirmedAt))
        if !info.printer.native {
            info.printer = printerStatusProvider()
        }
        return info
    }

    @discardableResult
    func sendCommand(_ command: [String: Any]) -> Bool {
        guard linked,
              JSONSerialization.isValidJSONObject(command),
              let json = try? JSONSerialization.data(withJSONObject: command) else { return false }
        guard send(frame("#CMD ", json)) else { return false }
        if let mode = command["display"] as? String {
            let normalizedMode = DisplayModeDescriptor.normalizedMode(mode)
            displayMode = normalizedMode
            reportedInfo.mode = normalizedMode
            reportedInfo.effective = normalizedMode
            if mode == "weather" {
                uploadedWeatherScreenRevision = -1
                lastStatusAt = .distantPast
            }
        }
        if let level = command["brightness"] as? Int {
            brightness = max(0, min(100, level))
            reportedInfo.brightness = brightness
        }
        if let enabled = command["auto_rotate"] as? Bool {
            reportedInfo.autoRotateEnabled = enabled
        }
        return true
    }


    static func crc32(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                if crc & 1 == 1 {
                    crc = (crc >> 1) ^ 0xEDB8_8320
                } else {
                    crc >>= 1
                }
            }
        }
        return ~crc
    }

    static func isValidStockNamesPayload(_ data: Data) -> Bool {
        guard let count = data.first, count > 0, count <= 5 else { return false }
        let expected = 1 + Int(count) * StockMonitor.nameW * StockMonitor.nameH * 2
        return data.count == expected
    }

    private func tick() {
        if fd < 0 {
            scanAndOpen()
            return
        }
        readPending()
        let now = Date()
        if !linked {
            // handshake: #HELLO every 3s; give up on this port after 30s
            if now.timeIntervalSince(openedAt) > 30 {
                closePort()
                return
            }
            if now.timeIntervalSince(lastHelloAt) > 3 {
                lastHelloAt = now
                send("#HELLO\n".data(using: .utf8)!)
            }
            return
        }

        if let upload = stockNamesUpload, now >= upload.deadline {
            finishStockNamesUpload(success: false)
            return
        }
        if let upload = weatherAssetUpload {
            if now >= upload.deadline {
                finishWeatherAssetUpload(success: false)
            }
            return
        }
        if displayMode == "printer", !reportedInfo.printer.native,
           now.timeIntervalSince(lastPrinterAt) >= 2 {
            lastPrinterAt = now
            send(Self.printerFrame(printerStatusProvider()))
        }
        if now.timeIntervalSince(lastStatusAt) > 5 {
            lastStatusAt = now
            send(Self.statusFrame(service.snapshot()))
            if featurePreferences.isEnabled("stock") {
                send(frame("#STOCK ", stockMonitor.jsonData()))
            }
            if displayMode == "weather" {
                send(frame("#WEATHER ", weatherMonitor.jsonData(now: now)))
                beginWeatherAssetUploadIfNeeded(now: now)
            }
            if featurePreferences.isEnabled("stock") {
                beginStockNamesUploadIfNeeded(now: now)
            }
        }
        if now.timeIntervalSince(lastInfoAt) > 1 {
            lastInfoAt = now
            send(Data("#INFO\n".utf8))
        }
    }

    private func frame(_ prefix: String, _ json: Data) -> Data {
        var d = Data(prefix.utf8)
        d.append(json) // JSONSerialization output is single-line
        d.append(0x0A)
        return d
    }

    static func statusFrame(_ envelope: StatusEnvelope) -> Data {
        var frame = Data("#STATUS ".utf8)
        frame.append(envelope.jsonData())
        frame.append(0x0A)
        return frame
    }

    static func printerFrame(_ status: PrinterStatus) -> Data {
        var frame = Data("#PRINTER ".utf8)
        frame.append(status.jsonData())
        frame.append(0x0a)
        return frame
    }

    // MARK: - port lifecycle

    private func scanAndOpen() {
        if let configuredPort = ProcessInfo.processInfo.environment["AICLOCK_SERIAL_PORT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !configuredPort.isEmpty
        {
            _ = openPort(configuredPort)
            return
        }

        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        let candidates = names.filter(Self.isSupportedSerialPortName).sorted()
        for name in candidates where openPort("/dev/" + name) {
            return
        }
    }

    static func isSupportedSerialPortName(_ name: String) -> Bool {
        name.hasPrefix("cu.usbserial") || name.hasPrefix("cu.wchusbserial") ||
            name.hasPrefix("cu.usbmodem")
    }

    private func openPort(_ path: String) -> Bool {
        let f = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard f >= 0 else { return false }
        var tio = termios()
        tcgetattr(f, &tio)
        cfmakeraw(&tio)
        cfsetspeed(&tio, speed_t(B115200))
        tio.c_cflag |= tcflag_t(CLOCAL | CREAD)
        tio.c_cflag &= ~tcflag_t(HUPCL) // don't hang-up-reset the board on close
        tcsetattr(f, TCSANOW, &tio)
        // Deassert DTR+RTS so the CH340 auto-reset circuit lets the ESP run.
        // TIOCMBIC = _IOW('t', 107, int); TIOCM_DTR|TIOCM_RTS = 0x006.
        var bits: Int32 = 0x006
        _ = ioctl(f, 0x8004_746B, &bits)
        fd = f
        portPath = path
        linked = false
        dataConfirmed = false
        lastStatusConfirmedAt = .distantPast
        displayMode = "auto"
        brightness = 100
        openedAt = Date()
        lastHelloAt = .distantPast
        lastInfoAt = .distantPast
        reportedInfo = DeviceInfo()
        uploadedStockNamesRevision = -1
        lastStockNamesUploadAttemptAt = .distantPast
        stockNamesUpload = nil
        uploadedWeatherScreenRevision = -1
        uploadedWeatherAstronautRevision = -1
        lastWeatherAssetUploadAttemptAt = .distantPast
        weatherAssetUpload = nil
        rxBuf.removeAll()
        FileHandle.standardError.write(Data("[serial] trying \(path)\n".utf8))
        return true
    }

    private func closePort() {
        if fd >= 0 { close(fd) }
        if linked || fd >= 0 {
            FileHandle.standardError.write(Data("[serial] closed \(portPath)\n".utf8))
        }
        fd = -1
        portPath = ""
        linked = false
        dataConfirmed = false
        lastStatusConfirmedAt = .distantPast
        finishStockNamesUpload(success: false)
        finishWeatherAssetUpload(success: false)
    }

    // MARK: - I/O

    @discardableResult
    private func send(_ data: Data) -> Bool {
        guard fd >= 0, !data.isEmpty else { return false }
        var writeError: Int32 = 0
        let wroteAll = data.withUnsafeBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return false }
            var offset = 0
            var wouldBlockRetries = 0
            while offset < data.count {
                let count = write(fd, base.advanced(by: offset), data.count - offset)
                if count > 0 {
                    offset += count
                    wouldBlockRetries = 0
                } else if count < 0, errno == EINTR {
                    continue
                } else if count < 0, errno == EAGAIN, wouldBlockRetries < 100 {
                    wouldBlockRetries += 1
                    usleep(1_000)
                } else {
                    writeError = errno
                    return false
                }
            }
            return true
        }
        if !wroteAll, writeError == ENXIO || writeError == EIO ||
            writeError == EBADF || writeError == ENODEV
        {
            closePort()
        }
        return wroteAll
    }

    private func readPending() {
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n > 0 {
                rxBuf.append(contentsOf: buf[0..<n])
                if rxBuf.count > 16384 { rxBuf.removeAll() } // runaway noise
                continue
            }
            if n == 0 || (n < 0 && errno != EAGAIN) { closePort() } // EOF / unplugged
            break
        }
        while let nl = rxBuf.firstIndex(of: 0x0A) {
            let lineData = rxBuf.prefix(upTo: nl)
            rxBuf.removeSubrange(...nl)
            guard let line = String(data: lineData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) else { continue }
            if handleStockNamesUploadLine(line) {
                continue
            } else if handleWeatherAssetUploadLine(line) {
                continue
            } else if line.hasPrefix("#DEVICE") {
                let payload = line.dropFirst("#DEVICE ".count)
                if let data = String(payload).data(using: .utf8),
                   let info = DeviceClient.decodeInfo(data) {
                    reportedInfo = info
                    let address = info.ip.isEmpty ? portPath : info.ip
                    DeviceClient.registerDevice(address)
                    displayMode = DisplayModeDescriptor.normalizedMode(info.mode)
                    brightness = info.brightness
                    uploadedWeatherAstronautRevision = info.weatherAnimationRevision
                }
                if !linked {
                    linked = true
                    lastStatusAt = .distantPast // push a status immediately
                    FileHandle.standardError.write(Data("[serial] linked \(portPath): \(line)\n".utf8))
                }
            } else if line == "#ACK status" {
                lastStatusConfirmedAt = Date()
                if !dataConfirmed {
                    dataConfirmed = true
                    FileHandle.standardError.write(Data("[serial] status data confirmed by device\n".utf8))
                }
            }
            // anything else is the device's debug log - ignore
        }
    }

    private func beginStockNamesUploadIfNeeded(now: Date) {
        guard linked, fd >= 0, stockNamesUpload == nil,
              weatherAssetUpload == nil,
              now.timeIntervalSince(lastStockNamesUploadAttemptAt) >= 5 else { return }
        let snapshot = stockMonitor.namesV2Snapshot()
        guard snapshot.revision != uploadedStockNamesRevision,
              Self.isValidStockNamesPayload(snapshot.data),
              snapshot.data.count <= Self.maximumStockNamesBytes else { return }

        let metadata: [String: Any] = [
            "revision": snapshot.revision,
            "size": snapshot.data.count,
            "crc32": NSNumber(value: Self.crc32(snapshot.data)),
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: metadata) else { return }
        lastStockNamesUploadAttemptAt = now
        stockNamesUpload = StockNamesUpload(data: snapshot.data, revision: snapshot.revision)
        if !send(frame("#STOCK_NAMES_BEGIN ", json)) {
            finishStockNamesUpload(success: false)
        }
    }

    private func handleStockNamesUploadLine(_ line: String) -> Bool {
        if line == "#STOCK_NAMES_READY" {
            guard var upload = stockNamesUpload,
                  case .waitingReady = upload.phase else { return true }
            upload.deadline = Date().addingTimeInterval(10)
            stockNamesUpload = upload
            sendNextStockNamesChunk()
            return true
        }
        if line.hasPrefix("#STOCK_NAMES_ACK ") {
            let value = line.dropFirst("#STOCK_NAMES_ACK ".count)
            guard let sequence = Int(value), var upload = stockNamesUpload,
                  case let .waitingAcknowledgement(expected) = upload.phase,
                  sequence == expected else { return true }
            upload.offset += min(Self.stockNamesChunkSize, upload.data.count - upload.offset)
            upload.sequence += 1
            upload.deadline = Date().addingTimeInterval(10)
            stockNamesUpload = upload
            sendNextStockNamesChunk()
            return true
        }
        if line == "#STOCK_NAMES_DONE" {
            guard let upload = stockNamesUpload,
                  case .waitingDone = upload.phase else { return true }
            uploadedStockNamesRevision = upload.revision
            FileHandle.standardError.write(Data(
                "[serial] stock names revision \(upload.revision) uploaded\n".utf8))
            finishStockNamesUpload(success: true)
            return true
        }
        if line.hasPrefix("#STOCK_NAMES_ERR") {
            FileHandle.standardError.write(Data("[serial] \(line)\n".utf8))
            finishStockNamesUpload(success: false)
            return true
        }
        return false
    }

    private func sendNextStockNamesChunk() {
        guard var upload = stockNamesUpload else { return }
        if upload.offset >= upload.data.count {
            upload.phase = .waitingDone
            upload.deadline = Date().addingTimeInterval(10)
            stockNamesUpload = upload
            if !send(Data("#STOCK_NAMES_END\n".utf8)) {
                finishStockNamesUpload(success: false)
            }
            return
        }

        let end = min(upload.offset + Self.stockNamesChunkSize, upload.data.count)
        let encoded = upload.data.subdata(in: upload.offset..<end).base64EncodedString()
        upload.phase = .waitingAcknowledgement(upload.sequence)
        upload.deadline = Date().addingTimeInterval(10)
        stockNamesUpload = upload
        if !send(Data("#STOCK_NAMES_CHUNK \(upload.sequence) \(encoded)\n".utf8)) {
            finishStockNamesUpload(success: false)
        }
    }

    private func finishStockNamesUpload(success: Bool) {
        guard stockNamesUpload != nil else { return }
        stockNamesUpload = nil
        if !success {
            FileHandle.standardError.write(Data("[serial] stock name upload failed; retrying later\n".utf8))
        }
    }

    private func beginWeatherAssetUploadIfNeeded(now: Date) {
        guard linked, fd >= 0, displayMode == "weather",
              stockNamesUpload == nil, weatherAssetUpload == nil,
              now.timeIntervalSince(lastWeatherAssetUploadAttemptAt) >= 3 else { return }

        let upload: WeatherAssetUpload?
        if let screen = weatherMonitor.wiredScreenSnapshot(now: now),
           screen.revision != uploadedWeatherScreenRevision {
            upload = WeatherAssetUpload(
                data: screen.encoded,
                kind: .screen,
                revision: screen.revision,
                decodedSize: screen.decodedSize,
                frames: 0
            )
        } else if let astronaut = weatherMonitor.wiredAstronautSnapshot(),
                  astronaut.revision != uploadedWeatherAstronautRevision {
            upload = WeatherAssetUpload(
                data: astronaut.encoded,
                kind: .astronaut,
                revision: astronaut.revision,
                decodedSize: astronaut.decodedSize,
                frames: astronaut.frames
            )
        } else {
            upload = nil
        }
        guard let upload, !upload.data.isEmpty,
              upload.data.count <= Self.maximumWeatherAssetBytes else { return }

        let metadata: [String: Any] = [
            "kind": upload.kind.rawValue,
            "encoding": "rle565",
            "revision": upload.revision,
            "frames": upload.frames,
            "size": upload.data.count,
            "decoded_size": upload.decodedSize,
            "crc32": NSNumber(value: Self.crc32(upload.data)),
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: metadata) else { return }
        lastWeatherAssetUploadAttemptAt = now
        weatherAssetUpload = upload
        FileHandle.standardError.write(Data((
            "[serial] uploading weather \(upload.kind.rawValue) revision \(upload.revision), " +
                "\(upload.data.count)/\(upload.decodedSize) bytes\n"
        ).utf8))
        if !send(frame("#WEATHER_ASSET_BEGIN ", json)) {
            finishWeatherAssetUpload(success: false)
        }
    }

    static func weatherScreenRevision(afterDeviceLine line: String,
                                      current: Int, uploadInProgress: Bool) -> Int {
        line == "#WEATHER_SCREEN_NEEDED" && !uploadInProgress ? -1 : current
    }

    private func handleWeatherAssetUploadLine(_ line: String) -> Bool {
        if line == "#WEATHER_SCREEN_NEEDED" {
            uploadedWeatherScreenRevision = Self.weatherScreenRevision(
                afterDeviceLine: line, current: uploadedWeatherScreenRevision,
                uploadInProgress: weatherAssetUpload != nil
            )
            return true
        }
        if line == "#WEATHER_ASSET_READY" {
            guard var upload = weatherAssetUpload,
                  case .waitingReady = upload.phase else { return true }
            upload.deadline = Date().addingTimeInterval(15)
            weatherAssetUpload = upload
            sendNextWeatherAssetChunk()
            return true
        }
        if line.hasPrefix("#WEATHER_ASSET_ACK ") {
            let value = line.dropFirst("#WEATHER_ASSET_ACK ".count)
            guard let sequence = Int(value), var upload = weatherAssetUpload,
                  case let .waitingAcknowledgement(expected) = upload.phase,
                  sequence == expected else { return true }
            upload.offset += min(Self.weatherAssetChunkSize, upload.data.count - upload.offset)
            upload.sequence += 1
            upload.deadline = Date().addingTimeInterval(15)
            weatherAssetUpload = upload
            sendNextWeatherAssetChunk()
            return true
        }
        if line == "#WEATHER_ASSET_DONE" {
            guard let upload = weatherAssetUpload,
                  case .waitingDone = upload.phase else { return true }
            switch upload.kind {
            case .screen:
                uploadedWeatherScreenRevision = upload.revision
            case .astronaut:
                uploadedWeatherAstronautRevision = upload.revision
            }
            FileHandle.standardError.write(Data(
                "[serial] weather \(upload.kind.rawValue) revision \(upload.revision) uploaded\n".utf8
            ))
            finishWeatherAssetUpload(success: true)
            lastStatusAt = .distantPast
            return true
        }
        if line.hasPrefix("#WEATHER_ASSET_ERR") {
            FileHandle.standardError.write(Data("[serial] \(line)\n".utf8))
            finishWeatherAssetUpload(success: false)
            return true
        }
        return false
    }

    private func sendNextWeatherAssetChunk() {
        guard var upload = weatherAssetUpload else { return }
        if upload.offset >= upload.data.count {
            upload.phase = .waitingDone
            upload.deadline = Date().addingTimeInterval(20)
            weatherAssetUpload = upload
            if !send(Data("#WEATHER_ASSET_END\n".utf8)) {
                finishWeatherAssetUpload(success: false)
            }
            return
        }

        let end = min(upload.offset + Self.weatherAssetChunkSize, upload.data.count)
        let encoded = upload.data.subdata(in: upload.offset..<end).base64EncodedString()
        upload.phase = .waitingAcknowledgement(upload.sequence)
        upload.deadline = Date().addingTimeInterval(15)
        weatherAssetUpload = upload
        if !send(Data("#WEATHER_ASSET_CHUNK \(upload.sequence) \(encoded)\n".utf8)) {
            finishWeatherAssetUpload(success: false)
        }
    }

    private func finishWeatherAssetUpload(success: Bool) {
        guard weatherAssetUpload != nil else { return }
        weatherAssetUpload = nil
        if !success {
            FileHandle.standardError.write(Data(
                "[serial] weather asset upload failed; retrying later\n".utf8
            ))
        }
    }
}
