import Foundation

// Wired (USB serial) transport to the clock, for WiFi networks with client
// isolation - or for skipping WiFi setup entirely. Scans for CH340-style
// serial ports, handshakes, then pushes the same payloads the device would
// otherwise poll over HTTP, as newline-terminated frames:
//   bridge -> device:  #HELLO   #STATUS {json}   #NET {json}   #CMD {json}
//                       #PET_BEGIN {json}   #PET_CHUNK <seq> <base64>   #PET_END
//   device -> bridge:  #DEVICE {"name":"aiclock","fw":"x.y.z"}
//                       #ACK status   #PET_READY   #PET_ACK <seq>   #PET_DONE
// Device log lines (anything not starting with '#') are ignored.
//
// Set AICLOCK_SERIAL_PORT to pin the bridge to one device. The automatic scan
// remains the default when the variable is absent.
//
// NOTE: quit the app before flashing so the two serial clients do not race.
final class SerialLink {
    private enum PetUploadPhase {
        case waitingReady
        case waitingAcknowledgement(Int)
        case waitingDone
    }

    private struct PetUpload {
        let data: Data
        let slot: String
        let completion: (Error?) -> Void
        var offset = 0
        var sequence = 0
        var phase = PetUploadPhase.waitingReady
        var deadline = Date().addingTimeInterval(10)
    }

    private static let petChunkSize = 384
    private static let maximumPetBytes = 384 * 1024

    private let service: StatusService
    private let netMonitor: NetSpeedMonitor
    private let stockMonitor: StockMonitor

    private var fd: Int32 = -1
    private var portPath = ""
    private var linked = false // saw #DEVICE from the clock on this port
    private var dataConfirmed = false // saw a parsed status acknowledgement
    private var lastStatusConfirmedAt = Date.distantPast
    private var displayMode = "auto"
    private var brightness = 100
    private var showing = "claude"
    private var openedAt = Date.distantPast
    private var lastHelloAt = Date.distantPast
    private var lastStatusAt = Date.distantPast
    private var lastNetAt = Date.distantPast
    private var rxBuf = Data()
    private var timer: Timer?
    private var petUpload: PetUpload?
    private var claudeCustomSprite = false
    private var codexCustomSprite = false

    init(service: StatusService, netMonitor: NetSpeedMonitor, stockMonitor: StockMonitor) {
        self.service = service
        self.netMonitor = netMonitor
        self.stockMonitor = stockMonitor
    }

    func start() {
        // one 250ms tick drives everything: port scan, handshake, reads, pushes
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    var isLinked: Bool { linked }

    var deviceInfo: DeviceInfo? {
        guard linked, dataConfirmed,
              Date().timeIntervalSince(lastStatusConfirmedAt) < 15 else { return nil }

        let snapshot = service.snapshot()
        if displayMode == "claude" || displayMode == "codex" {
            showing = displayMode
        } else if snapshot.claude.needsInput != snapshot.codex.needsInput {
            showing = snapshot.claude.needsInput ? "claude" : "codex"
        } else {
            let claudeWorking = snapshot.claude.status == "working"
            let codexWorking = snapshot.codex.status == "working"
            if claudeWorking != codexWorking {
                showing = claudeWorking ? "claude" : "codex"
            }
        }

        var info = DeviceInfo()
        info.ip = portPath
        info.ssid = "USB"
        info.bridge = "USB serial"
        info.mode = displayMode
        info.effective = displayMode
        info.showing = showing
        info.lastUpdateS = Int(Date().timeIntervalSince(lastStatusConfirmedAt))
        info.brightness = brightness
        info.claudeCustomSprite = claudeCustomSprite
        info.codexCustomSprite = codexCustomSprite
        return info
    }

    @discardableResult
    func sendCommand(_ command: [String: Any]) -> Bool {
        guard linked,
              JSONSerialization.isValidJSONObject(command),
              let json = try? JSONSerialization.data(withJSONObject: command) else { return false }
        guard send(frame("#CMD ", json)) else { return false }
        if let mode = command["display"] as? String {
            displayMode = mode
        }
        if let level = command["brightness"] as? Int {
            brightness = max(0, min(100, level))
        }
        return true
    }

    @discardableResult
    func uploadPet(_ data: Data, slot: String, completion: @escaping (Error?) -> Void) -> Bool {
        guard linked, fd >= 0 else { return false }
        guard slot == "claude" || slot == "codex" else {
            completion(Self.petUploadError(code: 1, message: "Unsupported pet slot"))
            return true
        }
        guard !data.isEmpty, data.count <= Self.maximumPetBytes else {
            completion(Self.petUploadError(code: 2, message: "Pet GIF must be between 1 byte and 384 KB"))
            return true
        }
        guard petUpload == nil else {
            completion(Self.petUploadError(code: 3, message: "Another pet upload is already running"))
            return true
        }

        let metadata: [String: Any] = [
            "slot": slot,
            "size": data.count,
            "crc32": NSNumber(value: Self.crc32(data)),
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: metadata) else {
            completion(Self.petUploadError(code: 4, message: "Could not encode pet metadata"))
            return true
        }

        petUpload = PetUpload(data: data, slot: slot, completion: completion)
        if !send(frame("#PET_BEGIN ", json)) {
            finishPetUpload(error: Self.petUploadError(code: 5, message: "Could not write to the USB device"))
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
        if let upload = petUpload {
            if now >= upload.deadline {
                finishPetUpload(error: Self.petUploadError(code: 6, message: "USB pet upload timed out"))
            }
            return
        }
        if now.timeIntervalSince(lastStatusAt) > 5 {
            lastStatusAt = now
            send(frame("#STATUS ", service.snapshot().jsonData()))
            send(frame("#STOCK ", stockMonitor.jsonData()))
        }
        if now.timeIntervalSince(lastNetAt) > 2 {
            lastNetAt = now
            let stats = SystemStatsMonitor.shared.snapshot()
            send(frame("#NET ", netMonitor.jsonData(cpu: stats.cpu, mem: stats.mem)))
        }
    }

    private func frame(_ prefix: String, _ json: Data) -> Data {
        var d = Data(prefix.utf8)
        d.append(json) // JSONSerialization output is single-line
        d.append(0x0A)
        return d
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
        let candidates = names.filter {
            $0.hasPrefix("cu.usbserial") || $0.hasPrefix("cu.wchusbserial")
        }.sorted()
        for name in candidates where openPort("/dev/" + name) {
            return
        }
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
        showing = "claude"
        claudeCustomSprite = false
        codexCustomSprite = false
        openedAt = Date()
        lastHelloAt = .distantPast
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
        finishPetUpload(error: Self.petUploadError(code: 7, message: "USB device disconnected during pet upload"))
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
            if handlePetUploadLine(line) {
                continue
            } else if line.hasPrefix("#DEVICE") {
                if !linked {
                    linked = true
                    lastStatusAt = .distantPast // push a status immediately
                    lastNetAt = .distantPast
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

    private func handlePetUploadLine(_ line: String) -> Bool {
        if line == "#PET_READY" {
            guard var upload = petUpload, case .waitingReady = upload.phase else { return true }
            upload.deadline = Date().addingTimeInterval(10)
            petUpload = upload
            sendNextPetChunk()
            return true
        }
        if line.hasPrefix("#PET_ACK ") {
            let value = line.dropFirst("#PET_ACK ".count)
            guard let sequence = Int(value), var upload = petUpload,
                  case let .waitingAcknowledgement(expected) = upload.phase,
                  sequence == expected else { return true }
            upload.offset += min(Self.petChunkSize, upload.data.count - upload.offset)
            upload.sequence += 1
            upload.deadline = Date().addingTimeInterval(10)
            petUpload = upload
            sendNextPetChunk()
            return true
        }
        if line == "#PET_PROCESSING" {
            guard var upload = petUpload, case .waitingDone = upload.phase else { return true }
            upload.deadline = Date().addingTimeInterval(60)
            petUpload = upload
            return true
        }
        if line.hasPrefix("#PET_DONE") {
            guard let upload = petUpload, case .waitingDone = upload.phase else { return true }
            if upload.slot == "claude" {
                claudeCustomSprite = true
            } else {
                codexCustomSprite = true
            }
            finishPetUpload(error: nil)
            return true
        }
        if line.hasPrefix("#PET_ERR") {
            let reason = line.dropFirst("#PET_ERR".count).trimmingCharacters(in: .whitespaces)
            finishPetUpload(error: Self.petUploadError(
                code: 8,
                message: reason.isEmpty ? "The device rejected the pet upload" : "Device rejected pet upload: \(reason)"
            ))
            return true
        }
        return false
    }

    private func sendNextPetChunk() {
        guard var upload = petUpload else { return }
        if upload.offset >= upload.data.count {
            upload.phase = .waitingDone
            upload.deadline = Date().addingTimeInterval(60)
            petUpload = upload
            if !send(Data("#PET_END\n".utf8)) {
                finishPetUpload(error: Self.petUploadError(code: 9, message: "Could not finish the USB pet upload"))
            }
            return
        }

        let end = min(upload.offset + Self.petChunkSize, upload.data.count)
        let encoded = upload.data.subdata(in: upload.offset..<end).base64EncodedString()
        upload.phase = .waitingAcknowledgement(upload.sequence)
        upload.deadline = Date().addingTimeInterval(10)
        petUpload = upload
        if !send(Data("#PET_CHUNK \(upload.sequence) \(encoded)\n".utf8)) {
            finishPetUpload(error: Self.petUploadError(code: 10, message: "Could not send a USB pet chunk"))
        }
    }

    private func finishPetUpload(error: Error?) {
        guard let upload = petUpload else { return }
        petUpload = nil
        DispatchQueue.main.async {
            upload.completion(error)
        }
    }

    private static func petUploadError(code: Int, message: String) -> NSError {
        NSError(domain: "SerialLink.PetUpload", code: code,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
