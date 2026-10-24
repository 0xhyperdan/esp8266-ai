import Foundation

// Talks to supported AI clocks over HTTP, with USB serial fallbacks for device
// information and controls. Device address persists in defaults.

struct DeviceInfo {
    var printer = PrinterStatus()
    var board = ""
    var ip = ""
    var ssid = ""
    var bridge = ""
    var mode = "weather"    // configured: weather | net | music | stock | salary
    var effective = "weather" // weather may temporarily promote to music
    var showing = ""
    var lastUpdateS = -1    // seconds since the device last got /status data, -1 = never
    var brightness = 100    // backlight 0-100 (0 = off)
    var autoRotateSupported = false
    var autoRotateEnabled = false
    var screenRotation = 0
    var batterySupported = false
    var batteryPresent = false
    var batteryCharging = false
    var batteryLevel = -1
    var batteryVoltageMv = 0
    var weatherAnimationRevision = -1
    var weatherAnimationFrames = 0
    var firmwareVersion = ""
    var otaAvailable = false
    var salaryMonthlyYuan = 0.0
    var salaryStartMin = 9 * 60
    var salaryEndMin = 18 * 60
    var salaryLunchStartMin = 12 * 60
    var salaryLunchEndMin = 13 * 60
    var salaryElapsedS = 0
    var salaryDailyWorkS = 8 * 60 * 60
    var salaryEarnedYuan = 0.0
    var salaryRateYuanPerSecond = 0.0
    var salaryStatus = "CONFIGURE SALARY"
}

struct OTACredentials: Codable, Equatable {
    let username: String
    let password: String
}

enum FirmwareUpdateProgress {
    case uploading(Double)
    case restarting
}

final class FirmwareUploadTask: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate,
    @unchecked Sendable {
    typealias Completion = (Error?) -> Void

    private let progress: (Double) -> Void
    private let completion: Completion
    private var responseData = Data()
    private var session: URLSession?

    init(progress: @escaping (Double) -> Void, completion: @escaping Completion) {
        self.progress = progress
        self.completion = completion
    }

    func start(request: URLRequest, body: Data) {
        let configuration = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        session.uploadTask(with: request, from: body).resume()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        let fraction = min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend))
        DispatchQueue.main.async { self.progress(fraction) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        responseData.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        var result = error
        if result == nil, let response = task.response as? HTTPURLResponse,
           !(200...299).contains(response.statusCode) {
            let message = String(decoding: responseData, as: UTF8.self)
            result = NSError(domain: "DeviceClient", code: response.statusCode,
                             userInfo: [NSLocalizedDescriptionKey:
                                "Device returned HTTP \(response.statusCode): \(message)"])
        }
        session.finishTasksAndInvalidate()
        self.session = nil
        DispatchQueue.main.async { self.completion(result) }
    }
}

final class DeviceClient {
    private static let lastSeenKey = "device_last_seen"
    private static let registry = DeviceRegistry.shared

    static var wiredCommandHandler: (([String: Any]) -> Bool)?
    static var wiredInfoProvider: (() -> DeviceInfo?)?
    private static var activeFirmwareUploads: [UUID: FirmwareUploadTask] = [:]
    private static let pairingScanLock = NSLock()
    private static var pairingScanGeneration = 0
    private static var activePairingSession: URLSession?

    static var host: String {
        get { registry.selectedAddress }
        set { registry.selectedAddress = newValue }
    }

    static var deviceAddresses: [String] {
        var addresses = registry.addresses
        if let wiredAddress = wiredInfoProvider?().flatMap(deviceAddress),
           !addresses.contains(wiredAddress) {
            addresses.append(wiredAddress)
        }
        return addresses
    }

    static func registerDevice(_ address: String) {
        _ = registry.register(address)
    }

    static func selectDevice(_ address: String) {
        registry.selectedAddress = address
    }

    static func removeDevice(_ address: String) {
        registry.remove(address)
    }

    static func displayName(for address: String) -> String {
        if address.hasPrefix("/dev/") {
            return "USB " + URL(fileURLWithPath: address).lastPathComponent
                .replacingOccurrences(of: "cu.", with: "")
        }
        return address
    }

    /// Last LAN address that polled our /status — i.e. the clock itself.
    static var lastSeenIP: String {
        get { UserDefaults.standard.string(forKey: lastSeenKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: lastSeenKey) }
    }

    static var baseURL: URL? {
        baseURL(for: host)
    }

    private static func baseURL(for address: String) -> URL? {
        let h = DeviceRegistry.normalize(address)
        guard !h.isEmpty else { return nil }
        return URL(string: h.hasPrefix("http") ? h : "http://\(h)")
    }

    /// GET /api/info
    static func fetchInfo(completion: @escaping (Result<DeviceInfo, Error>) -> Void) {
        let selected = host
        if let info = selectedWiredInfo(for: selected) {
            DispatchQueue.main.async { completion(.success(info)) }
            return
        }
        fetchLANInfo(address: selected, completion: completion)
    }

    /// GET /api/info over LAN even when a USB device is linked.
    static func fetchLANInfo(completion: @escaping (Result<DeviceInfo, Error>) -> Void) {
        fetchLANInfo(address: host, completion: completion)
    }

    private static func fetchLANInfo(address: String,
                                     completion: @escaping (Result<DeviceInfo, Error>) -> Void) {
        guard let base = baseURL(for: address) else {
            completion(.failure(Self.noHostError))
            return
        }
        var req = URLRequest(url: base.appendingPathComponent("api/info"))
        req.timeoutInterval = 5
        URLSession.shared.dataTask(with: req) { data, _, error in
            var result: Result<DeviceInfo, Error>
            if let error = error {
                result = .failure(error)
            } else if let data = data, let info = decodeInfo(data) {
                result = .success(info)
            } else {
                result = .failure(Self.badResponseError)
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    private static func deviceAddress(_ info: DeviceInfo) -> String? {
        let address = DeviceRegistry.normalize(info.ip)
        return address.isEmpty ? nil : address
    }

    private static func selectedWiredInfo(for address: String) -> DeviceInfo? {
        guard let info = wiredInfoProvider?(), let wiredAddress = deviceAddress(info) else { return nil }
        let selected = DeviceRegistry.normalize(address)
        return selected.isEmpty || selected == wiredAddress ? info : nil
    }

    private static var shouldUseWiredTransport: Bool {
        let selected = DeviceRegistry.normalize(host)
        if selected.isEmpty {
            return wiredInfoProvider != nil || wiredCommandHandler != nil
        }
        return selectedWiredInfo(for: selected) != nil
    }

    static func decodeInfo(_ data: Data) -> DeviceInfo? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var info = DeviceInfo()
        info.printer = PrinterStatus.decode(obj["printer"] as? [String: Any] ?? [:])
        info.board = obj["board"] as? String ?? ""
        info.ip = obj["ip"] as? String ?? ""
        info.ssid = obj["ssid"] as? String ?? ""
        info.bridge = obj["bridge"] as? String ?? ""
        info.mode = DisplayModeDescriptor.normalizedMode(obj["mode"] as? String ?? "weather")
        info.effective = DisplayModeDescriptor.normalizedMode(
            obj["effective"] as? String ?? info.mode
        )
        info.showing = obj["showing"] as? String ?? ""
        info.lastUpdateS = (obj["last_update_s"] as? NSNumber)?.intValue ?? -1
        info.brightness = (obj["brightness"] as? NSNumber)?.intValue ?? 100
        let orientation = obj["orientation"] as? [String: Any]
        info.autoRotateSupported = orientation?["supported"] as? Bool ?? false
        info.autoRotateEnabled = orientation?["auto"] as? Bool ?? false
        info.screenRotation = (orientation?["rotation"] as? NSNumber)?.intValue ?? 0
        let battery = obj["battery"] as? [String: Any]
        info.batterySupported = battery?["supported"] as? Bool ?? false
        info.batteryPresent = battery?["present"] as? Bool ?? false
        info.batteryCharging = battery?["charging"] as? Bool ?? false
        info.batteryLevel = (battery?["level"] as? NSNumber)?.intValue ?? -1
        info.batteryVoltageMv = (battery?["voltage_mv"] as? NSNumber)?.intValue ?? 0
        let weatherAnimation = obj["weather_animation"] as? [String: Any]
        info.weatherAnimationRevision =
            (weatherAnimation?["revision"] as? NSNumber)?.intValue ?? -1
        info.weatherAnimationFrames =
            (weatherAnimation?["frames"] as? NSNumber)?.intValue ?? 0
        info.firmwareVersion = obj["fw"] as? String ?? ""
        info.otaAvailable = obj["ota"] as? Bool ?? false
        let salary = obj["salary"] as? [String: Any]
        info.salaryMonthlyYuan = ((salary?["monthly_fen"] as? NSNumber)?.doubleValue ?? 0) / 100.0
        info.salaryStartMin = (salary?["start_min"] as? NSNumber)?.intValue ?? 9 * 60
        info.salaryEndMin = (salary?["end_min"] as? NSNumber)?.intValue ?? 18 * 60
        info.salaryLunchStartMin = (salary?["lunch_start_min"] as? NSNumber)?.intValue ?? 12 * 60
        info.salaryLunchEndMin = (salary?["lunch_end_min"] as? NSNumber)?.intValue ?? 13 * 60
        info.salaryElapsedS = (salary?["elapsed_s"] as? NSNumber)?.intValue ?? 0
        // Firmwares before daily_work_s: derive it from the schedule so the
        // mirror progress ring stays correct.
        if let daily = (salary?["daily_work_s"] as? NSNumber)?.intValue, daily > 0 {
            info.salaryDailyWorkS = daily
        } else {
            let lunch = max(0, info.salaryLunchEndMin - info.salaryLunchStartMin)
            info.salaryDailyWorkS = max(60, info.salaryEndMin - info.salaryStartMin - lunch) * 60
        }
        info.salaryEarnedYuan = (salary?["earned_yuan"] as? NSNumber)?.doubleValue ?? 0
        info.salaryRateYuanPerSecond = (salary?["rate_yuan_per_second"] as? NSNumber)?.doubleValue ?? 0
        info.salaryStatus = salary?["status"] as? String ?? "CONFIGURE SALARY"
        return info
    }

    /// POST /api/display  mode=weather|net|music|stock|weather|salary
    static func setDisplayMode(_ mode: String, completion: @escaping (Error?) -> Void) {
        if shouldUseWiredTransport, wiredCommandHandler?(["display": mode]) == true {
            completion(nil)
            return
        }
        postForm(path: "api/display", fields: ["mode": mode], completion: completion)
    }

    /// Saves monthly salary and the paid work schedule, then shows the salary page.
    static func configureSalary(monthlyYuan: Double, startMin: Int, endMin: Int,
                               lunchStartMin: Int, lunchEndMin: Int,
                               completion: @escaping (Error?) -> Void) {
        let monthlyText = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), monthlyYuan)
        let salary: [String: Any] = [
            "monthly_fen": max(0, Int((monthlyYuan * 100.0).rounded())),
            "start_min": startMin,
            "end_min": endMin,
            "lunch_start_min": lunchStartMin,
            "lunch_end_min": lunchEndMin,
        ]
        if shouldUseWiredTransport, wiredCommandHandler?(["salary": salary]) == true {
            completion(nil)
            return
        }
        postForm(path: "api/salary", fields: [
            "monthly_yuan": monthlyText,
            "start_min": String(startMin),
            "end_min": String(endMin),
            "lunch_start_min": String(lunchStartMin),
            "lunch_end_min": String(lunchEndMin),
        ], completion: completion)
    }

    /// POST /api/bridge  host=ip:port
    static func setBridgeHost(_ bridgeHost: String, completion: @escaping (Error?) -> Void) {
        postForm(path: "api/bridge", fields: ["host": bridgeHost], completion: completion)
    }

    /// Set brightness. HTTP persists it; wired mode applies it for this boot.
    static func setBrightness(_ level: Int, completion: @escaping (Error?) -> Void) {
        if shouldUseWiredTransport, wiredCommandHandler?(["brightness": level]) == true {
            completion(nil)
            return
        }
        postForm(path: "api/brightness", fields: ["level": String(level)], completion: completion)
    }

    /// Enables or disables the device-owned IMU auto-rotation policy.
    static func setAutoRotate(_ enabled: Bool, completion: @escaping (Error?) -> Void) {
        if shouldUseWiredTransport,
           wiredCommandHandler?(["auto_rotate": enabled]) == true {
            completion(nil)
            return
        }
        postForm(path: "api/orientation", fields: ["auto": enabled ? "1" : "0"],
                 completion: completion)
    }

    /// Uploads a firmware image over the authenticated Web OTA route,
    /// then waits for the device to restart and answer /api/info again.
    static func uploadFirmware(_ firmware: Data, boardID: String,
                               credentials: OTACredentials,
                               progress: @escaping (FirmwareUpdateProgress) -> Void,
                               completion: @escaping (Result<DeviceInfo, Error>) -> Void) {
        guard let base = baseURL else {
            completion(.failure(Self.noHostError))
            return
        }
        guard isValidFirmwareImage(firmware, boardID: boardID) else {
            completion(.failure(NSError(domain: "DeviceClient", code: 10,
                userInfo: [NSLocalizedDescriptionKey:
                    "The selected firmware does not match the connected device."])))
            return
        }

        let boundary = "aiclock-ota-\(UUID().uuidString)"
        var request = URLRequest(url: base.appendingPathComponent("update"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(basicAuthorizationHeader(credentials), forHTTPHeaderField: "Authorization")
        let body = firmwareMultipartBody(firmware, boundary: boundary)
        let identifier = UUID()
        let uploader = FirmwareUploadTask(progress: { fraction in
            progress(.uploading(fraction))
        }, completion: { error in
            activeFirmwareUploads.removeValue(forKey: identifier)
            if let error = error {
                completion(.failure(error))
                return
            }
            progress(.restarting)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                pollAfterFirmwareUpdate(base: base, attemptsRemaining: 45, completion: completion)
            }
        })
        activeFirmwareUploads[identifier] = uploader
        uploader.start(request: request, body: body)
    }

    static func isValidFirmwareImage(_ data: Data, boardID: String = "") -> Bool {
        guard data.count >= 4096, data.first == 0xE9 else { return false }
        let normalized = boardID.lowercased()
        if normalized.contains("esp32-s3") {
            return firmwareChipID(data) == 9
        }
        if normalized.contains("esp8266") {
            return firmwareChipID(data) != 9
        }
        return true
    }

    static func firmwareTargetName(for boardID: String) -> String {
        boardID.lowercased().contains("esp32-s3") ? "ESP32-S3" : "ESP8266"
    }

    private static func firmwareChipID(_ data: Data) -> UInt16? {
        guard data.count >= 14 else { return nil }
        return UInt16(data[12]) | UInt16(data[13]) << 8
    }

    static func basicAuthorizationHeader(_ credentials: OTACredentials) -> String {
        let token = Data("\(credentials.username):\(credentials.password)".utf8).base64EncodedString()
        return "Basic \(token)"
    }

    static func firmwareMultipartBody(_ firmware: Data, boundary: String) -> Data {
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"firmware\"; filename=\"firmware.bin\"\r\n".utf8))
        body.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(firmware)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    private static func pollAfterFirmwareUpdate(base: URL, attemptsRemaining: Int,
                                                completion: @escaping (Result<DeviceInfo, Error>) -> Void) {
        guard attemptsRemaining > 0 else {
            completion(.failure(NSError(domain: "DeviceClient", code: 11,
                userInfo: [NSLocalizedDescriptionKey: "The device did not return after the firmware update."])))
            return
        }
        var request = URLRequest(url: base.appendingPathComponent("api/info"))
        request.timeoutInterval = 1
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data = data, let info = decodeInfo(data) {
                DispatchQueue.main.async { completion(.success(info)) }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    pollAfterFirmwareUpdate(base: base, attemptsRemaining: attemptsRemaining - 1,
                                            completion: completion)
                }
            }
        }.resume()
    }

    // MARK: - internals

    private static func postForm(path: String, fields: [String: String],
                                 completion: @escaping (Error?) -> Void) {
        guard let base = baseURL else {
            completion(Self.noHostError)
            return
        }
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.timeoutInterval = 8
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        req.httpBody = Data(fields.map { k, v in
            "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
        }.joined(separator: "&").utf8)
        run(req, completion: completion)
    }

    private static func run(_ req: URLRequest, completion: @escaping (Error?) -> Void) {
        URLSession.shared.dataTask(with: req) { data, resp, error in
            var err = error
            if err == nil, let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                let msg = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                err = NSError(domain: "DeviceClient", code: http.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: "设备返回 HTTP \(http.statusCode) \(msg)"])
            }
            DispatchQueue.main.async { completion(err) }
        }.resume()
    }

    private static var noHostError: NSError {
        NSError(domain: "DeviceClient", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "未设置设备地址，请先在菜单里填写设备 IP"])
    }

    private static var badResponseError: NSError {
        NSError(domain: "DeviceClient", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "设备响应解析失败"])
    }

    // MARK: - discovery / pairing

    /// Checks whether `ip` answers like our clock (GET /api/info with the
    /// expected JSON shape).
    static func isClockInfo(_ object: [String: Any]) -> Bool {
        object["mode"] is String && object["fw"] is String
    }

    static func verifyDevice(ip: String, timeout: TimeInterval = 2,
                             completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "http://\(ip)/api/info") else {
            completion(false)
            return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        URLSession.shared.dataTask(with: req) { data, _, _ in
            let ok = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                .map(isClockInfo) ?? false
            DispatchQueue.main.async { completion(ok) }
        }.resume()
    }

    /// Finds the clock and pairs (sets `host`). Strategy:
    ///  1. the address that most recently polled our /status (no scanning);
    ///  2. the currently configured host, re-verified;
    ///  3. sweep this Mac's /24 subnet for /api/info (covers a factory-fresh
    ///     device that has WiFi but no bridge configured yet).
    static func autoPair(progress: @escaping (String) -> Void,
                         completion: @escaping (String?) -> Void) {
        var candidates: [String] = []
        if !lastSeenIP.isEmpty { candidates.append(lastSeenIP) }
        let configured = host.split(separator: ":").first.map(String.init) ?? host
        if !configured.isEmpty, !candidates.contains(configured) { candidates.append(configured) }

        func tryNext() {
            guard let ip = candidates.first else {
                scanSubnet(progress: progress, completion: completion)
                return
            }
            candidates.removeFirst()
            progress("验证 \(ip)…")
            verifyDevice(ip: ip) { ok in
                if ok {
                    host = ip
                    completion(ip)
                } else {
                    tryNext()
                }
            }
        }
        tryNext()
    }

    /// Parallel sweep of the local /24 (254 hosts, ~0.8s timeout each,
    /// 32-wide). Only used when the passive route came up empty.
    private static func scanSubnet(progress: @escaping (String) -> Void,
                                   completion: @escaping (String?) -> Void) {
        guard let myIP = localIPv4(),
              let prefixEnd = myIP.range(of: ".", options: .backwards)?.lowerBound else {
            completion(nil)
            return
        }
        let prefix = String(myIP[..<prefixEnd])
        progress("扫描 \(prefix).1-254…")
        let session: URLSession = {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 0.8
            cfg.httpMaximumConnectionsPerHost = 1
            return URLSession(configuration: cfg)
        }()
        pairingScanLock.lock()
        pairingScanGeneration += 1
        let generation = pairingScanGeneration
        let previousSession = activePairingSession
        activePairingSession = session
        pairingScanLock.unlock()
        previousSession?.invalidateAndCancel()
        let group = DispatchGroup()
        let lock = NSLock()
        var found: String?
        let sem = DispatchSemaphore(value: 32)
        DispatchQueue.global(qos: .utility).async {
            for n in 1...254 {
                guard isPairingScanActive(generation) else { break }
                let ip = "\(prefix).\(n)"
                if ip == myIP { continue }
                sem.wait()
                lock.lock()
                let alreadyFound = found != nil
                lock.unlock()
                if alreadyFound { sem.signal(); continue }
                group.enter()
                let task = session.dataTask(with: URL(string: "http://\(ip)/api/info")!) { data, _, _ in
                    let ok = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                        .map(isClockInfo) ?? false
                    if ok, isPairingScanActive(generation) {
                        lock.lock()
                        if found == nil { found = ip }
                        lock.unlock()
                    }
                    sem.signal()
                    group.leave()
                }
                task.resume()
            }
            group.notify(queue: .main) {
                let active = finishPairingScan(generation, session: session)
                guard active else {
                    completion(nil)
                    return
                }
                if let ip = found { host = ip }
                completion(found)
            }
        }
    }

    private static func isPairingScanActive(_ generation: Int) -> Bool {
        pairingScanLock.lock()
        defer { pairingScanLock.unlock() }
        return generation == pairingScanGeneration
    }

    private static func finishPairingScan(_ generation: Int, session: URLSession) -> Bool {
        pairingScanLock.lock()
        let active = generation == pairingScanGeneration
        if active { activePairingSession = nil }
        pairingScanLock.unlock()
        session.finishTasksAndInvalidate()
        return active
    }

    static func cancelPairingActivity() {
        pairingScanLock.lock()
        pairingScanGeneration += 1
        let session = activePairingSession
        activePairingSession = nil
        pairingScanLock.unlock()
        session?.invalidateAndCancel()
        healInFlight = false
    }

    // MARK: - pairing watchdog

    /// Stamped on every device poll of our /status|/music (see main.swift).
    static var devicePollAt = Date.distantPast

    private static var healInFlight = false
    private static var lastHealAttempt = Date.distantPast

    /// Self-healing for the fresh-device chicken-and-egg: after a full flash
    /// erase the clock knows no bridge host, so it never polls us and passive
    /// discovery never fires. When we haven't heard from the device for a few
    /// minutes, actively find it (last-seen IP, configured host, then /24
    /// scan) and, if its bridge is unset or it can't reach the one it has,
    /// point it at this Mac. Called from a 60s timer; the /24 scan is
    /// rate-limited to once per 5 minutes.
    static func healPairingIfNeeded(port: UInt16) {
        guard Date().timeIntervalSince(devicePollAt) > 180 else { return } // device is polling us
        guard !healInFlight, Date().timeIntervalSince(lastHealAttempt) > 300 else { return }
        healInFlight = true
        lastHealAttempt = Date()
        autoPair(progress: { _ in }) { ip in
            guard ip != nil else { healInFlight = false; return }
            fetchInfo { result in
                defer { healInFlight = false }
                guard case let .success(info) = result, let myIP = localIPv4() else { return }
                let expectedBridge = "\(myIP):\(port)"
                guard bridgeNeedsRepair(
                    current: info.bridge,
                    expected: expectedBridge,
                    lastUpdateS: info.lastUpdateS
                ) else { return }
                setBridgeHost(expectedBridge) { error in
                    FileHandle.standardError.write(Data(
                        "[pair] pushed bridge \(expectedBridge) to \(info.ip): \(error.map { "\($0.localizedDescription)" } ?? "ok")\n".utf8))
                }
            }
        }
    }

    static func bridgeNeedsRepair(
        current: String,
        expected: String,
        lastUpdateS: Int
    ) -> Bool {
        current.isEmpty || current != expected || lastUpdateS < 0 || lastUpdateS > 60
    }

    /// LAN IPv4 of this Mac (en0 preferred) — used for one-click "point the
    /// device's bridge at this Mac".
    static func localIPv4() -> String? {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return nil }
        defer { freeifaddrs(addrs) }
        var best: String?
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0,
                  (ifa.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let name = String(cString: ifa.ifa_name)
            let ip = String(cString: host)
            if name == "en0" { return ip }
            if best == nil { best = ip }
        }
        return best
    }
}
