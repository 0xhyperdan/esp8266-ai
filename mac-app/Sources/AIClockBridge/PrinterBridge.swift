import Foundation
import Network
import Security

struct PrinterBridgeConfiguration: Codable, Equatable {
    var host = ""
    var serial = ""
    var enabled = false
    var allowSelfSigned = false

    var identity: String { "\(host)/\(serial)" }
    var isValid: Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4,
              parts.allSatisfy({ part in
                  guard let n = Int(part) else { return false }
                  return (0...255).contains(n) && String(n) == part
              })
        else { return false }
        let octets = parts.compactMap { Int($0) }
        let privateLAN = octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168)
        return privateLAN && (1...32).contains(serial.utf8.count)
            && serial.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0)
                || (97...122).contains($0) || $0 == 45 }
    }

    static func validCode(_ code: String) -> Bool {
        (8...64).contains(code.utf8.count) && code.utf8.allSatisfy { (33...126).contains($0) }
    }
}

protocol PrinterCredentialStore {
    func read(identity: String) throws -> String?
    func save(_ value: String, identity: String) throws
    func delete(identity: String) throws
}

struct PrinterKeychain: PrinterCredentialStore {
    private let service = "me.qust.aiclockbridge.printer-lan"
    private func query(_ identity: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: identity]
    }
    func read(identity: String) throws -> String? {
        var attributes = query(identity)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { throw PrinterBridgeError.keychain }
        return value
    }
    func save(_ value: String, identity: String) throws {
        let attributes = [kSecValueData as String: Data(value.utf8)]
        let status = SecItemUpdate(query(identity) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var entry = query(identity)
            entry.merge(attributes) { _, new in new }
            entry[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(entry as CFDictionary, nil) == errSecSuccess else { throw PrinterBridgeError.keychain }
        } else if status != errSecSuccess { throw PrinterBridgeError.keychain }
    }
    func delete(identity: String) throws {
        let status = SecItemDelete(query(identity) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw PrinterBridgeError.keychain }
    }
}

enum PrinterBridgeError: LocalizedError {
    case configuration, codeRequired, keychain
    var errorDescription: String? {
        switch self {
        case .configuration: return "请填写有效的局域网 IPv4 和打印机序列号。"
        case .codeRequired: return "请填写 8–64 位访问码；只有同一台打印机可留空保留。"
        case .keychain: return "无法访问 Mac 钥匙串，配置未完成。"
        }
    }
}

/// One serial queue owns the MQTT session and telemetry. Stop invalidates all callbacks.
final class PrinterBridge: RuntimeActivity {
    static let shared = PrinterBridge()
    private static let configurationKey = "printerLANBridgeConfigurationV1"
    private let defaults: UserDefaults
    private let credentials: PrinterCredentialStore
    private let queue = DispatchQueue(label: "AIClockBridge.printer-lan")
    private var config: PrinterBridgeConfiguration
    private var running = false
    private var connection: NWConnection?
    private var timer: DispatchSourceTimer?
    private var generation: UInt64 = 0
    private var buffer = Data()
    private var accumulator = PrinterReportAccumulator()
    private var phase = 0 // 0 disconnected, 1 TLS/connect, 2 CONNACK, 3 SUBACK, 4 reports
    private var deadline = Date.distantFuture
    private var reconnectAt = Date.distantFuture
    private var retryDelay: TimeInterval = 5
    private var lastDataAt: Date?
    private var lastSentAt = Date.distantPast
    private var lastPushAt = Date.distantPast
    private var pingAt: Date?

    init(defaults: UserDefaults = .standard, credentials: PrinterCredentialStore = PrinterKeychain()) {
        self.defaults = defaults
        self.credentials = credentials
        config = defaults.data(forKey: Self.configurationKey)
            .flatMap { try? JSONDecoder().decode(PrinterBridgeConfiguration.self, from: $0) }
            ?? PrinterBridgeConfiguration()
        if !config.isValid { config.enabled = false }
    }

    var configuration: PrinterBridgeConfiguration { queue.sync { config } }

    func configure(_ next: PrinterBridgeConfiguration, accessCode: String) throws {
        guard next.isValid else { throw PrinterBridgeError.configuration }
        try queue.sync {
            let previous = config
            if !accessCode.isEmpty {
                guard PrinterBridgeConfiguration.validCode(accessCode) else { throw PrinterBridgeError.codeRequired }
                try credentials.save(accessCode, identity: next.identity)
            } else {
                guard next.identity == previous.identity,
                      let saved = try credentials.read(identity: next.identity),
                      PrinterBridgeConfiguration.validCode(saved) else { throw PrinterBridgeError.codeRequired }
            }
            // Do not leave an abandoned printer's access code behind.
            if previous.isValid && previous.identity != next.identity {
                do { try credentials.delete(identity: previous.identity) }
                catch {
                    try? credentials.delete(identity: next.identity)
                    throw error
                }
            }
            disconnect()
            timer?.cancel(); timer = nil
            config = next
            defaults.set(try JSONEncoder().encode(next), forKey: Self.configurationKey)
            accumulator = PrinterReportAccumulator()
            lastDataAt = nil
            retryDelay = 5
            reconnectAt = Date()
            if running && next.enabled { startTimer(); connect() }
        }
    }

    func forget() throws {
        try queue.sync {
            try credentials.delete(identity: config.identity)
            disconnect()
            timer?.cancel(); timer = nil
            config = PrinterBridgeConfiguration()
            defaults.removeObject(forKey: Self.configurationKey)
            accumulator = PrinterReportAccumulator()
            lastDataAt = nil
        }
    }

    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            reconnectAt = Date()
            if config.enabled && config.isValid { startTimer() }
        }
    }

    func stop() {
        queue.sync {
            running = false
            timer?.cancel(); timer = nil
            disconnect()
        }
    }

    func snapshot(now: Date = Date()) -> PrinterStatus {
        queue.sync {
            var value = accumulator.value
            value.supported = true; value.native = false
            value.configured = config.isValid
            value.enabled = config.enabled
            value.connected = running && phase == 4
            value.stale = lastDataAt.map { now.timeIntervalSince($0) >= 60 } ?? false
            if !value.configured {
                value.error = "Not configured"
            } else if !value.enabled {
                value.error = "Disabled"
            } else if !running {
                value.error = "Printer monitor stopped"
            } else if !value.connected {
                if value.error.isEmpty { value.error = "Disconnected" }
            } else if lastDataAt == nil {
                value.error = "Waiting for printer data"
            } else if value.stale {
                value.error = "Printer data is stale"
            }
            return value
        }
    }

    func jsonData() -> Data { snapshot().jsonData() }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1)
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    private func tick() {
        guard running && config.enabled && config.isValid else { return }
        let now = Date()
        if phase == 0 {
            if now >= reconnectAt { connect() }
        } else if phase < 4 {
            if now >= deadline { fail("打印机握手超时") }
        } else if let pingAt, now.timeIntervalSince(pingAt) > 10 {
            fail("打印机心跳超时")
        } else {
            if now.timeIntervalSince(lastSentAt) >= 20 && pingAt == nil {
                self.pingAt = now
                send(PrinterMQTT.packet(0xc0, Data()))
            }
            if now.timeIntervalSince(lastPushAt) >= 60 {
                lastPushAt = now
                send(PrinterMQTT.snapshotRequest(serial: config.serial))
            }
        }
    }

    private func connect() {
        guard running && config.enabled && config.isValid else { return }
        let code: String
        do {
            guard let saved = try credentials.read(identity: config.identity),
                  PrinterBridgeConfiguration.validCode(saved) else { throw PrinterBridgeError.codeRequired }
            code = saved
        } catch { fail("无法读取打印机访问码，请检查钥匙串设置"); return }
        generation &+= 1
        let token = generation
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        if config.allowSelfSigned {
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in
                complete(true) // Explicit per-printer trusted-LAN consent only.
            }, queue)
        }
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        let session = NWConnection(host: NWEndpoint.Host(config.host), port: 8883, using: parameters)
        connection = session
        phase = 1; deadline = Date().addingTimeInterval(10)
        session.stateUpdateHandler = { [weak self, weak session] state in
            guard let self, let session, self.generation == token, self.connection === session else { return }
            switch state {
            case .ready:
                self.phase = 2; self.deadline = Date().addingTimeInterval(10)
                self.send(PrinterMQTT.connect(clientID: "aiclock-" + UUID().uuidString.prefix(12), accessCode: code))
                self.receive(session, token: token)
            case .failed: self.fail("无法连接打印机，请检查网络、访问码和局域网权限")
            case .waiting: self.fail("打印机网络不可达")
            default: break
            }
        }
        session.start(queue: queue)
    }

    private func receive(_ session: NWConnection, token: UInt64) {
        session.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self, weak session] data, _, complete, error in
            guard let self, let session, self.generation == token, self.connection === session else { return }
            do {
                if let data {
                    guard self.buffer.count + data.count <= PrinterMQTT.maximumPacketBytes + 8192 else { throw PrinterMQTT.Failure.tooLarge }
                    self.buffer.append(data)
                    while let frame = try PrinterMQTT.next(&self.buffer) { try self.handle(frame) }
                }
                if error != nil || complete { self.fail("打印机连接已断开") }
                else { self.receive(session, token: token) }
            } catch { self.fail("打印机返回无效或不支持的 MQTT 数据") }
        }
    }

    private func handle(_ frame: PrinterMQTT.Frame) throws {
        let body = [UInt8](frame.body)
        switch frame.header {
        case 0x20:
            guard phase == 2, body.count == 2, body[0] == 0, body[1] == 0 else { throw PrinterMQTT.Failure.rejected }
            phase = 3; deadline = Date().addingTimeInterval(10)
            send(PrinterMQTT.subscribe(serial: config.serial))
        case 0x90:
            guard phase == 3, body == [0, 1, 0] else { throw PrinterMQTT.Failure.rejected }
            phase = 4; retryDelay = 5
            accumulator.value.error = ""
            lastPushAt = Date()
            send(PrinterMQTT.snapshotRequest(serial: config.serial))
        case 0xd0:
            guard body.isEmpty else { throw PrinterMQTT.Failure.malformed }
            pingAt = nil
        default:
            if frame.header >> 4 == 3 {
                guard phase == 3 || phase == 4 else { throw PrinterMQTT.Failure.malformed }
                if let report = try PrinterMQTT.report(frame, serial: config.serial), accumulator.apply(report) {
                    lastDataAt = Date()
                }
            }
        }
    }

    private func send(_ data: Data) {
        guard let session = connection else { return }
        lastSentAt = Date()
        let token = generation
        session.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self, self.generation == token else { return }
            if error != nil { self.fail("发送打印机状态请求失败") }
        })
    }

    private func disconnect() {
        generation &+= 1
        connection?.stateUpdateHandler = nil
        connection?.cancel(); connection = nil
        phase = 0; buffer.removeAll(keepingCapacity: false); pingAt = nil
    }

    private func fail(_ message: String) {
        disconnect()
        accumulator.value.error = message
        reconnectAt = Date().addingTimeInterval(retryDelay)
        retryDelay = min(retryDelay * 2, 60)
    }
}
