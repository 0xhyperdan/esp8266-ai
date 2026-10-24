using System.Text.Json;
using AIClockBridge;

var failures = new List<string>();

void Assert(bool condition, string name)
{
    if (!condition) failures.Add(name);
}

var status = new StatusService().Snapshot(musicPlaying: true);
using var statusDocument = JsonDocument.Parse(status);
var statusRoot = statusDocument.RootElement;
Assert(statusRoot.EnumerateObject().Select(property => property.Name).OrderBy(name => name)
    .SequenceEqual(new[] { "music_playing", "ts" }), "status envelope contains only heartbeat fields");
Assert(statusRoot.GetProperty("music_playing").GetBoolean(), "status envelope carries music flag");

foreach (var mode in new[] { "auto", "claude", "codex", "home", "usage", "info", "net", "pomodoro", "unknown" })
{
    Assert(DeviceClient.NormalizeMode(mode) == "weather", $"legacy mode migrates to weather: {mode}");
}
Assert(DeviceClient.NormalizeMode("salary") == "salary", "salary mode is retained");
Assert(DeviceClient.NormalizeMode("printer") == "printer", "native printer status identity is retained without adding unsupported menu controls");

Assert(DeviceClient.IsClockInfo(JsonSerializer.SerializeToElement(new
{
    mode = "weather",
    fw = "1.0.0",
})), "clock discovery accepts minimal status fields");
Assert(!DeviceClient.IsClockInfo(JsonSerializer.SerializeToElement(new
{
    mode = "weather",
})), "clock discovery rejects an incomplete response");

if (failures.Count > 0)
{
    Console.Error.WriteLine($"{failures.Count} bridge tests failed");
    return 1;
}
Console.WriteLine("all bridge tests passed");
return 0;
