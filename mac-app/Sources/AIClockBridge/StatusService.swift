import Foundation

/// Thread-safe facade for the minimal `/status` heartbeat.
final class StatusService {
    var musicPlayingProvider: (() -> Bool)?

    func snapshot() -> StatusEnvelope {
        StatusEnvelope(musicPlaying: musicPlayingProvider?() ?? false)
    }
}
