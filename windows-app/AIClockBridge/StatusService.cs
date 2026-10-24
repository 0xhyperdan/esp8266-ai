using System.Text.Json;

namespace AIClockBridge;

/// Minimal heartbeat consumed by the clock over HTTP and USB.
sealed class StatusService
{
    public string Snapshot(bool musicPlaying) =>
        JsonSerializer.Serialize(new
        {
            ts = DateTimeOffset.UtcNow.ToUnixTimeSeconds(),
            music_playing = musicPlaying,
        });
}
