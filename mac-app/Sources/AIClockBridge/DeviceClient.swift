import Foundation

// Talks to the ESP8266 clock over HTTP, with USB serial fallbacks for device
// information, controls, and pet uploads. Device address persists in defaults.

struct DeviceInfo {
    var ip = ""
    var ssid = ""
    var bridge = ""
    var mode = "auto"       // configured: auto | claude | codex | net | music
    var effective = "auto"  // what's actually on screen (AUTO may promote to music)
    var showing = ""
    var lastUpdateS = -1    // seconds since the device last got /status data, -1 = never
    var spriteRev = 0       // bumped by the device on animation change
    var brightness = 100    // backlight 0-100 (0 = off)
    var firmwareVersion = ""
    var otaAvailable = false
    var spriteUploadState = ""
    var spriteUploadSlot = ""
    var spriteUploadError = ""
    var claudeCustomSprite = false
    var codexCustomSprite = false
    var claudeW = 111, claudeH = 120
    var codexW = 120, codexH = 120
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
    private static let hostKey = "device_host"
    private static let lastSeenKey = "device_last_seen"

    static var wiredCommandHandler: (([String: Any]) -> Bool)?
    static var wiredInfoProvider: (() -> DeviceInfo?)?
    static var wiredPetUploadHandler: ((Data, String, @escaping (Error?) -> Void) -> Bool)?
    private static var activeFirmwareUploads: [UUID: FirmwareUploadTask] = [:]

    static var host: String {
        get { UserDefaults.standard.string(forKey: hostKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: hostKey) }
    }

    /// Last LAN address that polled our /status — i.e. the clock itself.
    static var lastSeenIP: String {
        get { UserDefaults.standard.string(forKey: lastSeenKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: lastSeenKey) }
    }

    static var baseURL: URL? {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty else { return nil }
        return URL(string: h.hasPrefix("http") ? h : "http://\(h)")
    }

    /// GET /api/info
    static func fetchInfo(completion: @escaping (Result<DeviceInfo, Error>) -> Void) {
        if let info = wiredInfoProvider?() {
            DispatchQueue.main.async { completion(.success(info)) }
            return
        }
        fetchLANInfo(completion: completion)
    }

    /// GET /api/info over LAN even when a USB device is linked.
    static func fetchLANInfo(completion: @escaping (Result<DeviceInfo, Error>) -> Void) {
        guard let base = baseURL else {
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

    static func decodeInfo(_ data: Data) -> DeviceInfo? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var info = DeviceInfo()
        info.ip = obj["ip"] as? String ?? ""
        info.ssid = obj["ssid"] as? String ?? ""
        info.bridge = obj["bridge"] as? String ?? ""
        info.mode = obj["mode"] as? String ?? "auto"
        info.effective = obj["effective"] as? String ?? info.mode
        info.showing = obj["showing"] as? String ?? ""
        info.lastUpdateS = (obj["last_update_s"] as? NSNumber)?.intValue ?? -1
        info.spriteRev = (obj["sprite_rev"] as? NSNumber)?.intValue ?? 0
        info.brightness = (obj["brightness"] as? NSNumber)?.intValue ?? 100
        info.firmwareVersion = obj["fw"] as? String ?? ""
        info.otaAvailable = obj["ota"] as? Bool ?? false
        let upload = obj["sprite_upload"] as? [String: Any]
        info.spriteUploadState = upload?["state"] as? String ?? ""
        info.spriteUploadSlot = upload?["slot"] as? String ?? ""
        info.spriteUploadError = upload?["error"] as? String ?? ""
        let claude = obj["claude"] as? [String: Any]
        let codex = obj["codex"] as? [String: Any]
        info.claudeCustomSprite = claude?["custom_sprite"] as? Bool ?? false
        info.codexCustomSprite = codex?["custom_sprite"] as? Bool ?? false
        info.claudeW = (claude?["w"] as? NSNumber)?.intValue ?? 111
        info.claudeH = (claude?["h"] as? NSNumber)?.intValue ?? 120
        info.codexW = (codex?["w"] as? NSNumber)?.intValue ?? 120
        info.codexH = (codex?["h"] as? NSNumber)?.intValue ?? 120
        return info
    }

    /// POST /api/display  mode=auto|claude|codex|net|music
    static func setDisplayMode(_ mode: String, completion: @escaping (Error?) -> Void) {
        if wiredCommandHandler?(["display": mode]) == true {
            completion(nil)
            return
        }
        postForm(path: "api/display", fields: ["mode": mode], completion: completion)
    }

    /// POST /api/bridge  host=ip:port
    static func setBridgeHost(_ bridgeHost: String, completion: @escaping (Error?) -> Void) {
        postForm(path: "api/bridge", fields: ["host": bridgeHost], completion: completion)
    }

    /// Set brightness. HTTP persists it; wired mode applies it for this boot.
    static func setBrightness(_ level: Int, completion: @escaping (Error?) -> Void) {
        if wiredCommandHandler?(["brightness": level]) == true {
            completion(nil)
            return
        }
        postForm(path: "api/brightness", fields: ["level": String(level)], completion: completion)
    }

    /// POST /sprite/{claude|codex} multipart GIF upload. WiFi firmware decodes
    /// after releasing HTTP memory; USB reports completion after direct decode.
    static func uploadGif(_ gif: Data, slot: String, completion: @escaping (Error?) -> Void) {
        if wiredPetUploadHandler?(gif, slot, completion) == true {
            return
        }
        guard let base = baseURL else {
            completion(Self.noHostError)
            return
        }
        var req = URLRequest(url: base.appendingPathComponent("sprite/\(slot)"))
        req.httpMethod = "POST"
        req.timeoutInterval = 60 // on-device decode takes a few seconds
        let boundary = "aiclock-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"pet.gif\"\r\n".utf8))
        body.append(Data("Content-Type: image/gif\r\n\r\n".utf8))
        body.append(gif)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        req.httpBody = body
        run(req) { error in
            guard error == nil else {
                completion(error)
                return
            }
            waitForSpriteUpload(slot: slot, deadline: Date().addingTimeInterval(90),
                                completion: completion)
        }
    }

    /// Uploads an ESP8266 firmware image over the authenticated Web OTA route,
    /// then waits for the device to restart and answer /api/info again.
    static func uploadFirmware(_ firmware: Data, credentials: OTACredentials,
                               progress: @escaping (FirmwareUpdateProgress) -> Void,
                               completion: @escaping (Result<DeviceInfo, Error>) -> Void) {
        guard let base = baseURL else {
            completion(.failure(Self.noHostError))
            return
        }
        guard isValidFirmwareImage(firmware) else {
            completion(.failure(NSError(domain: "DeviceClient", code: 10,
                userInfo: [NSLocalizedDescriptionKey: "The selected file is not an ESP8266 firmware image."])))
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

    static func isValidFirmwareImage(_ data: Data) -> Bool {
        data.count >= 4096 && data.first == 0xE9
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

    /// POST /sprite/{claude|codex}/reset — back to the compiled-in animation.
    static func resetSprite(slot: String, completion: @escaping (Error?) -> Void) {
        postForm(path: "sprite/\(slot)/reset", fields: [:], completion: completion)
    }

    /// GET /sprite/{claude|codex}/raw — the animation the device is actually
    /// using, wire format [1 byte frame count][RGB565 big-endian frames...].
    static func fetchSpriteRaw(slot: String, completion: @escaping (Result<Data, Error>) -> Void) {
        guard let base = baseURL else {
            completion(.failure(Self.noHostError))
            return
        }
        var req = URLRequest(url: base.appendingPathComponent("sprite/\(slot)/raw"))
        req.timeoutInterval = 30
        URLSession.shared.dataTask(with: req) { data, resp, error in
            var result: Result<Data, Error>
            if let error = error {
                result = .failure(error)
            } else if let data = data, (resp as? HTTPURLResponse)?.statusCode == 200, data.count > 1 {
                result = .success(data)
            } else {
                result = .failure(Self.badResponseError)
            }
            DispatchQueue.main.async { completion(result) }
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

    private static func waitForSpriteUpload(slot: String, deadline: Date,
                                            completion: @escaping (Error?) -> Void) {
        guard Date() < deadline else {
            completion(NSError(domain: "DeviceClient", code: 12,
                userInfo: [NSLocalizedDescriptionKey: "The device did not finish decoding the pet in time."]))
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
            fetchLANInfo { result in
                switch result {
                case let .success(info):
                    // Firmware before 0.5.3 completed decoding inside the upload request.
                    if info.spriteUploadState.isEmpty {
                        completion(nil)
                    } else if info.spriteUploadSlot == slot, info.spriteUploadState == "succeeded" {
                        completion(nil)
                    } else if info.spriteUploadSlot == slot, info.spriteUploadState == "failed" {
                        let reason = info.spriteUploadError.isEmpty ? "unknown decode error" : info.spriteUploadError
                        completion(NSError(domain: "DeviceClient", code: 13,
                            userInfo: [NSLocalizedDescriptionKey: "The device could not decode the pet: \(reason)"]))
                    } else {
                        waitForSpriteUpload(slot: slot, deadline: deadline, completion: completion)
                    }
                case .failure:
                    // The single-core ESP8266 cannot answer HTTP while decoding. Retry until it is free.
                    waitForSpriteUpload(slot: slot, deadline: deadline, completion: completion)
                }
            }
        }
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
                .map { $0["mode"] is String && $0["sprite_rev"] != nil } ?? false
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
        let group = DispatchGroup()
        let lock = NSLock()
        var found: String?
        let sem = DispatchSemaphore(value: 32)
        DispatchQueue.global(qos: .utility).async {
            for n in 1...254 {
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
                        .map { $0["mode"] is String && $0["sprite_rev"] != nil } ?? false
                    if ok {
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
                if let ip = found { host = ip }
                completion(found)
            }
        }
    }

    // MARK: - pairing watchdog

    /// Stamped on every device poll of our /status|/net|/music (see main.swift).
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
                let stale = info.lastUpdateS < 0 || info.lastUpdateS > 60
                guard info.bridge.isEmpty || stale else { return }
                setBridgeHost("\(myIP):\(port)") { error in
                    FileHandle.standardError.write(Data(
                        "[pair] pushed bridge \(myIP):\(port) to \(info.ip): \(error.map { "\($0.localizedDescription)" } ?? "ok")\n".utf8))
                }
            }
        }
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
