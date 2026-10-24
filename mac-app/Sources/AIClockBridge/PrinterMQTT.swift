import Foundation
import CoreFoundation

/// Bounded MQTT 3.1.1 wire codec. No printer control messages are implemented.
enum PrinterMQTT {
    static let maximumPacketBytes = 65_536
    enum Failure: Error { case malformed, tooLarge, rejected }

    static func string(_ value: String) -> Data {
        let bytes = Data(value.utf8)
        precondition(bytes.count <= 65_535)
        return Data([UInt8(bytes.count >> 8), UInt8(bytes.count & 255)]) + bytes
    }

    static func packet(_ header: UInt8, _ body: Data) -> Data {
        var size = body.count
        var result = Data([header])
        repeat {
            var byte = UInt8(size % 128)
            size /= 128
            if size > 0 { byte |= 128 }
            result.append(byte)
        } while size > 0
        result.append(body)
        return result
    }

    static func connect(clientID: String, accessCode: String) -> Data {
        var body = string("MQTT") + Data([4, 0xc2, 0, 30])
        body += string(clientID) + string("bblp") + string(accessCode)
        return packet(0x10, body)
    }

    static func subscribe(serial: String) -> Data {
        packet(0x82, Data([0, 1]) + string("device/\(serial)/report") + Data([0]))
    }

    static func snapshotRequest(serial: String) -> Data {
        let payload = Data(#"{"pushing":{"sequence_id":"1","command":"pushall","version":1,"push_target":1}}"#.utf8)
        return packet(0x30, string("device/\(serial)/request") + payload)
    }

    struct Frame: Equatable { let header: UInt8; let body: Data }

    /// Consume one complete frame, preserving incomplete TCP fragments.
    static func next(_ buffer: inout Data) throws -> Frame? {
        let bytes = [UInt8](buffer)
        guard bytes.count >= 2 else { return nil }
        var size = 0, multiplier = 1, offset = 1
        while true {
            guard offset < bytes.count else { return nil }
            let byte = bytes[offset]
            size += Int(byte & 127) * multiplier
            offset += 1
            if size + offset > maximumPacketBytes { throw Failure.tooLarge }
            if byte & 128 == 0 { break }
            if offset == 5 { throw Failure.malformed }
            multiplier *= 128
        }
        guard bytes.count >= offset + size else { return nil }
        let frame = Frame(header: bytes[0], body: Data(bytes[offset..<(offset + size)]))
        buffer = Data(bytes.dropFirst(offset + size))
        return frame
    }

    static func report(_ frame: Frame, serial: String) throws -> Data? {
        guard frame.header >> 4 == 3 else { return nil }
        let bytes = [UInt8](frame.body)
        guard bytes.count >= 2 else { throw Failure.malformed }
        let topicLength = Int(bytes[0]) * 256 + Int(bytes[1])
        let qos = (frame.header >> 1) & 3
        guard qos == 0, topicLength > 0, bytes.count >= 2 + topicLength else {
            throw Failure.malformed
        }
        guard String(bytes: bytes[2..<(2 + topicLength)], encoding: .utf8)
                == "device/\(serial)/report" else { return nil }
        return Data(bytes.dropFirst(2 + topicLength))
    }
}

/// Bambu reports are deltas: absent/invalid fields never overwrite known data.
struct PrinterReportAccumulator {
    var value = PrinterStatus()
    private var taskID = ""
    private var activeTool = 0

    private static func bounded(_ text: String, bytes: Int) -> String {
        var result = ""
        for character in text {
            let next = String(character)
            if result.utf8.count + next.utf8.count > bytes { break }
            result += next
        }
        return result
    }

    @discardableResult
    mutating func apply(_ data: Data) -> Bool {
        guard data.count <= PrinterMQTT.maximumPacketBytes,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let print = root["print"] as? [String: Any] else { return false }
        func number(_ object: [String: Any], _ key: String,
                    _ range: ClosedRange<Double>) -> Double? {
            guard let n = object[key] as? NSNumber,
                  CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite,
                  range.contains(n.doubleValue) else { return nil }
            return n.doubleValue
        }
        var accepted = false
        let name = (print["subtask_name"] as? String).map { Self.bounded($0, bytes: 127) }
        let nextID = (print["task_id"] as? String).map { Self.bounded($0, bytes: 32) }
            ?? number(print, "task_id", 0...Double(Int32.max)).map { String(Int($0)) }
        let state = (print["gcode_state"] as? String).map { Self.bounded($0, bytes: 19) }
        let starting = state == "RUNNING" || state == "PREPARE"
        if (nextID != nil && nextID != taskID)
            || (name != nil && name != value.job)
            || (starting && ["FINISH", "FAILED", "IDLE"].contains(value.state)) {
            value.progress = nil; value.remainingMinutes = nil
            value.layer = nil; value.totalLayers = nil
            value.state = ""; value.error = ""
            if name == nil { value.job = "" }
        }
        if let nextID { taskID = nextID; accepted = true }
        if let name { value.job = name; accepted = true }
        if let state { value.state = state; accepted = true }
        if let n = number(print, "mc_percent", 0...100), n.rounded() == n { value.progress = Int(n); accepted = true }
        if let n = number(print, "mc_remaining_time", 0...100_000), n.rounded() == n { value.remainingMinutes = Int(n); accepted = true }
        if let n = number(print, "layer_num", 0...100_000), n.rounded() == n { value.layer = Int(n); accepted = true }
        if let n = number(print, "total_layer_num", 0...100_000), n.rounded() == n { value.totalLayers = Int(n); accepted = true }
        if !value.dualNozzle, let n = number(print, "nozzle_temper", 0...500) { value.nozzle = n; accepted = true }
        if let n = number(print, "bed_temper", 0...200) { value.bed = n; accepted = true }
        if let n = number(print, "print_error", 0...Double(UInt32.max)) {
            value.error = n == 0 ? "" : "Printer error \(UInt32(n))"; accepted = true
        }
        let device = print["device"] as? [String: Any]
        if let extruder = (device?["extruder"] ?? print["extruder"]) as? [String: Any] {
            if let n = number(extruder, "state", 0...Double(UInt32.max)) {
                let active = (UInt32(n) >> 4) & 15
                if active <= 1 { activeTool = Int(active); accepted = true }
            }
            let tools = extruder["info"] as? [[String: Any]] ?? []
            if tools.count >= 2 { value.dualNozzle = true }
            for tool in tools {
                guard let id = number(tool, "id", 0...1), id.rounded() == id,
                      let packed = number(tool, "temp", 0...Double(UInt32.max)),
                      packed.rounded() == packed else { continue }
                let current = Double(UInt32(packed) & 0xffff)
                guard current <= 500 else { continue }
                if id == 0 { value.nozzleRight = current }
                else { value.nozzleLeft = current; value.dualNozzle = true }
                accepted = true
            }
            if value.dualNozzle { value.nozzle = activeTool == 0 ? value.nozzleRight : value.nozzleLeft }
        }
        return accepted
    }
}
