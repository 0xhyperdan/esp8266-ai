import Foundation

/// Minimal device heartbeat. The timestamp keeps device-owned clocks aligned and
/// `musicPlaying` lets the default weather page temporarily promote to music.
struct StatusEnvelope: Equatable {
    var timestamp: Int
    var musicPlaying: Bool

    init(timestamp: Int = Int(Date().timeIntervalSince1970),
         musicPlaying: Bool = false) {
        self.timestamp = timestamp
        self.musicPlaying = musicPlaying
    }

    func jsonData() -> Data {
        let object: [String: Any] = [
            "ts": timestamp,
            "music_playing": musicPlaying,
        ]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }
}
