import AppKit
import CoreFoundation

/// Read-only printer telemetry. Missing fields remain unknown, never zero.
struct PrinterStatus: Equatable {
    var native = true
    var supported = false
    var configured = false
    var enabled = false
    var connected = false
    var stale = false
    var state = ""
    var job = ""
    var error = ""
    var progress: Int?
    var remainingMinutes: Int?
    var layer: Int?
    var totalLayers: Int?
    var nozzle: Double?
    var nozzleLeft: Double?
    var nozzleRight: Double?
    var dualNozzle = false
    var bed: Double?

    static func decode(_ object: [String: Any]) -> PrinterStatus {
        var value = PrinterStatus()
        value.native = object["native"] as? Bool ?? (object["source"] as? String != "bridge")
        value.supported = object["supported"] as? Bool ?? false
        value.configured = object["configured"] as? Bool ?? false
        value.enabled = object["enabled"] as? Bool ?? false
        value.connected = object["connected"] as? Bool ?? false
        value.stale = object["stale"] as? Bool ?? false
        value.state = String((object["state"] as? String ?? "").prefix(20))
        value.job = String((object["job"] as? String ?? "").prefix(128))
        value.error = String((object["error"] as? String ?? "").prefix(96))
        func number(_ key: String, range: ClosedRange<Double>) -> Double? {
            guard let number = object[key] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite,
                  range.contains(number.doubleValue) else { return nil }
            return number.doubleValue
        }
        value.progress = number("progress", range: 0...100).map(Int.init)
        value.remainingMinutes = number("remaining_min", range: 0...100_000).map(Int.init)
        value.layer = number("layer", range: 0...100_000).map(Int.init)
        value.totalLayers = number("total_layers", range: 0...100_000).map(Int.init)
        value.nozzle = number("nozzle_c", range: 0...500)
        value.nozzleLeft = number("nozzle_left_c", range: 0...500)
        value.nozzleRight = number("nozzle_right_c", range: 0...500)
        value.dualNozzle = object["dual_nozzle"] as? Bool ?? false
        value.bed = number("bed_c", range: 0...200)
        return value
    }

    var statusText: String {
        if !supported { return "设备不支持打印机显示" }
        if !configured { return "未配置打印机" }
        if !enabled { return "监控已关闭" }
        if !connected { return "打印机离线" }
        if stale { return "数据已过期" }
        switch state {
        case "RUNNING": return "正在打印"
        case "PREPARE": return "准备打印"
        case "PAUSE": return "已暂停"
        case "FINISH": return "打印完成"
        case "FAILED": return "打印失败"
        case "IDLE": return "空闲"
        default: return state.isEmpty ? "等待打印机数据" : state
        }
    }

    var remainingText: String {
        guard let minutes = remainingMinutes else { return "--" }
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    /// A bounded public snapshot: never includes printer identity or access code.
    func jsonData() -> Data {
        func bounded(_ text: String, bytes: Int) -> String {
            var result = ""
            for character in text {
                let next = String(character)
                if result.utf8.count + next.utf8.count > bytes { break }
                result += next
            }
            return result
        }
        var object: [String: Any] = [
            "supported": supported, "native": native, "source": native ? "native" : "bridge",
            "configured": configured, "enabled": enabled, "connected": connected,
            "stale": stale, "state": bounded(state, bytes: 19), "job": bounded(job, bytes: 127),
            "error": bounded(error, bytes: 95), "dual_nozzle": dualNozzle,
        ]
        if let progress { object["progress"] = progress }
        if let remainingMinutes { object["remaining_min"] = remainingMinutes }
        if let layer, let totalLayers, layer <= totalLayers {
            object["layer"] = layer
            object["total_layers"] = totalLayers
        }
        if let nozzle { object["nozzle_c"] = nozzle }
        if let nozzleLeft { object["nozzle_left_c"] = nozzleLeft }
        if let nozzleRight { object["nozzle_right_c"] = nozzleRight }
        if let bed { object["bed_c"] = bed }
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }
}

enum PrinterScene {
    /// Draw in the mirror's normalized 240-point, top-left coordinate system.
    static func draw(_ value: PrinterStatus, deviceOnline: Bool = true) {
        func text(_ string: String, x: CGFloat, y: CGFloat, size: CGFloat,
                  color: NSColor = .white, width: CGFloat = 220) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            (string as NSString).draw(in: NSRect(x: x, y: y, width: width, height: size + 8),
                withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold),
                                 .foregroundColor: color, .paragraphStyle: paragraph])
        }
        let accent: NSColor = !deviceOnline || !value.connected || value.stale
            ? .systemOrange : value.state == "FAILED" ? .systemRed
            : value.state == "PAUSE" ? .systemYellow : .systemGreen
        text("BAMBU", x: 12, y: 10, size: 20)
        text(deviceOnline ? value.statusText : "设备离线", x: 12, y: 40, size: 14,
             color: accent)
        text(!value.connected && !value.error.isEmpty ? value.error
             : value.job.isEmpty ? "打印机状态" : value.job, x: 12, y: 62, size: 12)
        let track = NSRect(x: 12, y: 90, width: 216, height: 8)
        NSColor.darkGray.setFill()
        NSBezierPath(roundedRect: track, xRadius: 4, yRadius: 4).fill()
        if let progress = value.progress, progress > 0 {
            accent.setFill()
            NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY,
                                           width: track.width * CGFloat(progress) / 100,
                                           height: track.height), xRadius: 4, yRadius: 4).fill()
        }
        text(value.progress.map { "\($0)%" } ?? "--%", x: 12, y: 105, size: 36)
        text("剩余 \(value.remainingText)", x: 12, y: 154, size: 13, width: 110)
        text("层 \(value.layer.map(String.init) ?? "--")/\(value.totalLayers.map(String.init) ?? "--")",
             x: 125, y: 154, size: 13, width: 110)
        func temperature(_ current: Double?) -> String {
            guard let current else { return "--" }
            return "\(Int(current))°C"
        }
        text("喷嘴", x: 12, y: 187, size: 12, color: .lightGray)
        text("热床", x: 130, y: 187, size: 12, color: .lightGray)
        if value.dualNozzle {
            let left = value.nozzleLeft.map { String(Int($0)) } ?? "--"
            let right = value.nozzleRight.map { String(Int($0)) } ?? "--"
            text("L\(left) R\(right)", x: 12, y: 207, size: 13, width: 115)
        } else {
            text(temperature(value.nozzle), x: 12, y: 207, size: 17, width: 112)
        }
        text(temperature(value.bed), x: 130, y: 207, size: 17, width: 108)
    }
}
