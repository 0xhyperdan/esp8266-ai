namespace AIClockBridge;

// Entry point. Runs tray-only and serves the retained clock dashboard endpoints.
static class Program
{
    const int Port = 8765;

    [STAThread]
    static void Main(string[] args)
    {
        ApplicationConfiguration.Initialize();
        var service = new StatusService();
        var nowPlaying = new NowPlayingMonitor();
        nowPlaying.Start();
        var stockMonitor = new StockMonitor();
        stockMonitor.Start();

        var server = new MiniHttpServer(Port,
            routes: new()
            {
                ["/"] = () => service.Snapshot(nowPlaying.Snapshot.Playing),
                ["/status"] = () => service.Snapshot(nowPlaying.Snapshot.Playing),
                ["/music"] = () => nowPlaying.ToJson(),
                ["/stock"] = () => stockMonitor.ToJson(),
            },
            binaryRoutes: new()
            {
                ["/music/cover.raw"] = () => nowPlaying.CoverRgb565,
                ["/music/text.raw"] = () => nowPlaying.TextRgb565,
                ["/stock/names.raw"] = () => stockMonitor.NamesRgb565,
                ["/stock/names-v2.raw"] = () => stockMonitor.NamesV2Rgb565,
            });

        server.OnRequest = (path, ip) =>
        {
            if (path is not ("/status" or "/music" or "/stock")) return;
            if (ip is "127.0.0.1" or "::1" || ip.Length == 0) return;
            DeviceClient.DevicePollAt = DateTime.UtcNow;
            DeviceClient.LastSeenIp = ip;
            if (DeviceClient.Host.Length == 0) DeviceClient.Host = ip;
        };
        using var pairingWatchdog = new System.Threading.Timer(
            _ => _ = DeviceClient.HealPairingIfNeeded(Port), null,
            TimeSpan.FromSeconds(60), TimeSpan.FromSeconds(60));

        try
        {
            server.Start();
            Console.Error.WriteLine($"[bridge] serving /status on 0.0.0.0:{Port}");
        }
        catch (Exception error)
        {
            Console.Error.WriteLine($"[bridge] failed to bind port {Port}: {error.Message}");
        }

        using var context = new TrayAppContext(Port);
        Application.Run(context);
    }
}
