using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text.Json;

namespace AIClockBridge;

// Talks to the ESP8266 clock's own HTTP API for display, bridge, brightness,
// and display controls. Device address persists in Settings.

class DeviceInfo
{
    public string Ip = "";
    public string Ssid = "";
    public string Bridge = "";
    public string Mode = "weather";    // configured dashboard mode
    public string Effective = "weather"; // weather may temporarily promote to music
    public string Showing = "";
    public int LastUpdateS = -1;       // seconds since the device last got /status data, -1 = never
    public int Brightness = 100;       // backlight 0-100 (0 = off)
}

class DeviceException : Exception
{
    public DeviceException(string message) : base(message) { }
}

static class DeviceClient
{
    const string HostKey = "device_host";
    const string LastSeenKey = "device_last_seen";
    static readonly string[] RetainedModes =
    {
        "weather", "music", "stock", "salary", "printer",
    };

    public static string NormalizeMode(string mode) =>
        RetainedModes.Contains(mode) ? mode : "weather";

    // per-request CancellationTokenSources carry the timeouts (5s info, 8s
    // posts), so the client itself must not impose a shorter global one
    static readonly HttpClient Http = new() { Timeout = Timeout.InfiniteTimeSpan };

    public static string Host
    {
        get => Settings.Get(HostKey);
        set => Settings.Set(HostKey, value);
    }

    /// Last LAN address that polled our /status — i.e. the clock itself.
    public static string LastSeenIp
    {
        get => Settings.Get(LastSeenKey);
        set => Settings.Set(LastSeenKey, value);
    }

    public static Uri BaseUrl
    {
        get
        {
            var h = Host.Trim();
            if (h.Length == 0) return null;
            return Uri.TryCreate(h.StartsWith("http") ? h : $"http://{h}", UriKind.Absolute,
                out var uri) ? uri : null;
        }
    }

    static Uri Resolve(string path)
    {
        var b = BaseUrl ?? throw new DeviceException("未设置设备地址，请先在菜单里填写设备 IP");
        return new Uri(b, path);
    }

    /// GET /api/info
    public static async Task<DeviceInfo> FetchInfo()
    {
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        string body;
        try
        {
            body = await Http.GetStringAsync(Resolve("api/info"), cts.Token);
        }
        catch (DeviceException) { throw; }
        catch (Exception e)
        {
            throw new DeviceException($"无法连接设备：{e.Message}");
        }
        try
        {
            using var doc = JsonDocument.Parse(body);
            var root = doc.RootElement;
            var info = new DeviceInfo
            {
                Ip = Str(root, "ip"),
                Ssid = Str(root, "ssid"),
                Bridge = Str(root, "bridge"),
                Mode = NormalizeMode(Str(root, "mode", "weather")),
                LastUpdateS = Int(root, "last_update_s", -1),
                Brightness = Int(root, "brightness", 100),
                Showing = Str(root, "showing"),
            };
            info.Effective = NormalizeMode(Str(root, "effective", info.Mode));
            return info;
        }
        catch (Exception)
        {
            throw new DeviceException("设备响应解析失败");
        }
    }

    /// POST /api/display  mode=weather|music|stock|salary
    public static Task SetDisplayMode(string mode) =>
        PostForm("api/display", new() { ["mode"] = mode });

    /// POST /api/bridge  host=ip:port
    public static Task SetBridgeHost(string bridgeHost) =>
        PostForm("api/bridge", new() { ["host"] = bridgeHost });

    /// POST /api/brightness  level=0-100 (0 = backlight off); device persists it
    public static Task SetBrightness(int level) =>
        PostForm("api/brightness", new() { ["level"] = level.ToString() });

    // MARK: - internals

    static async Task PostForm(string path, Dictionary<string, string> fields)
    {
        var url = Resolve(path);
        using var content = new FormUrlEncodedContent(fields);
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(8));
        HttpResponseMessage resp;
        try
        {
            resp = await Http.PostAsync(url, content, cts.Token);
        }
        catch (Exception e)
        {
            throw new DeviceException($"请求失败：{e.Message}");
        }
        using (resp) await ThrowUnlessOk(resp);
    }

    static async Task ThrowUnlessOk(HttpResponseMessage resp)
    {
        if (resp.IsSuccessStatusCode) return;
        var msg = "";
        try { msg = await resp.Content.ReadAsStringAsync(); } catch { }
        throw new DeviceException($"设备返回 HTTP {(int)resp.StatusCode} {msg}");
    }

    static string Str(JsonElement o, string k, string dflt = "")
        => o.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String
            ? v.GetString() : dflt;

    static int Int(JsonElement o, string k, int dflt = 0)
        => o.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.Number
            ? (int)v.GetDouble() : dflt;

    static bool Bool(JsonElement o, string k)
        => o.TryGetProperty(k, out var v)
            && (v.ValueKind == JsonValueKind.True || v.ValueKind == JsonValueKind.False)
            && v.GetBoolean();

    // MARK: - discovery / pairing

    /// Checks whether `ip` answers like our clock (GET /api/info with the
    /// expected JSON shape).
    public static bool IsClockInfo(JsonElement root) =>
        root.TryGetProperty("mode", out var mode)
        && mode.ValueKind == JsonValueKind.String
        && root.TryGetProperty("fw", out var firmware)
        && firmware.ValueKind == JsonValueKind.String;

    public static async Task<bool> VerifyDevice(string ip, double timeoutSeconds = 2)
    {
        try
        {
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(timeoutSeconds));
            var body = await Http.GetStringAsync($"http://{ip}/api/info", cts.Token);
            using var doc = JsonDocument.Parse(body);
            return IsClockInfo(doc.RootElement);
        }
        catch
        {
            return false;
        }
    }

    /// Finds the clock and pairs (sets Host). Strategy:
    ///  1. the address that most recently polled our /status (no scanning);
    ///  2. the currently configured host, re-verified;
    ///  3. sweep this PC's /24 subnet for /api/info (covers a factory-fresh
    ///     device that has WiFi but no bridge configured yet).
    public static async Task<string> AutoPair(Action<string> progress)
    {
        var candidates = new List<string>();
        if (LastSeenIp.Length > 0) candidates.Add(LastSeenIp);
        var configured = Host.Split(':')[0];
        if (configured.Length > 0 && !candidates.Contains(configured)) candidates.Add(configured);

        foreach (var ip in candidates)
        {
            progress($"验证 {ip}…");
            if (await VerifyDevice(ip))
            {
                Host = ip;
                return ip;
            }
        }
        return await ScanSubnet(progress);
    }

    /// Parallel sweep of the local /24 (254 hosts, ~0.8s timeout each,
    /// 32-wide). Only used when the passive route came up empty.
    static async Task<string> ScanSubnet(Action<string> progress)
    {
        var myIp = LocalIPv4();
        var dot = myIp?.LastIndexOf('.') ?? -1;
        if (myIp == null || dot < 0) return null;
        var prefix = myIp[..dot];
        progress($"扫描 {prefix}.1-254…");

        using var sem = new SemaphoreSlim(32);
        string found = null;
        var tasks = new List<Task>();
        for (int n = 1; n <= 254; n++)
        {
            var ip = $"{prefix}.{n}";
            if (ip == myIp) continue;
            tasks.Add(Task.Run(async () =>
            {
                await sem.WaitAsync();
                try
                {
                    if (Volatile.Read(ref found) != null) return;
                    if (await VerifyDevice(ip, 0.8))
                        Interlocked.CompareExchange(ref found, ip, null);
                }
                finally
                {
                    sem.Release();
                }
            }));
        }
        await Task.WhenAll(tasks);
        if (found != null) Host = found;
        return found;
    }

    // MARK: - pairing watchdog

    /// Stamped on every device poll of our /status|/music (see Program.cs).
    public static DateTime DevicePollAt = DateTime.MinValue;

    static bool _healInFlight;
    static DateTime _lastHealAttempt = DateTime.MinValue;

    /// Self-healing for the fresh-device chicken-and-egg: after a full flash
    /// erase the clock knows no bridge host, so it never polls us and passive
    /// discovery never fires. When we haven't heard from the device for a few
    /// minutes, actively find it (last-seen IP, configured host, then /24
    /// scan) and, if its bridge is unset or it can't reach the one it has,
    /// point it at this PC. Called from a 60s timer; the /24 scan is
    /// rate-limited to once per 5 minutes.
    public static async Task HealPairingIfNeeded(int port)
    {
        if (DateTime.UtcNow - DevicePollAt < TimeSpan.FromMinutes(3)) return; // device is polling us
        if (_healInFlight || DateTime.UtcNow - _lastHealAttempt < TimeSpan.FromMinutes(5)) return;
        _healInFlight = true;
        _lastHealAttempt = DateTime.UtcNow;
        try
        {
            if (await AutoPair(_ => { }) == null) return;
            var info = await FetchInfo();
            var myIp = LocalIPv4();
            if (myIp == null) return;
            var stale = info.LastUpdateS < 0 || info.LastUpdateS > 60;
            if (info.Bridge.Length == 0 || stale)
            {
                await SetBridgeHost($"{myIp}:{port}");
                Console.Error.WriteLine($"[pair] pushed bridge {myIp}:{port} to {info.Ip}");
            }
        }
        catch (DeviceException)
        {
            // device vanished mid-heal; next tick retries
        }
        finally
        {
            _healInFlight = false;
        }
    }

    /// LAN IPv4 of this PC — used for one-click "point the device's bridge at
    /// this machine". Prefers an interface that has a default gateway.
    public static string LocalIPv4()
    {
        string best = null;
        try
        {
            foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (nic.OperationalStatus != OperationalStatus.Up) continue;
                if (nic.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
                var props = nic.GetIPProperties();
                var hasGateway = props.GatewayAddresses
                    .Any(g => g.Address?.AddressFamily == AddressFamily.InterNetwork);
                foreach (var addr in props.UnicastAddresses)
                {
                    if (addr.Address.AddressFamily != AddressFamily.InterNetwork) continue;
                    if (IPAddress.IsLoopback(addr.Address)) continue;
                    var ip = addr.Address.ToString();
                    if (hasGateway) return ip;
                    best ??= ip;
                }
            }
        }
        catch
        {
            // fall through
        }
        return best;
    }
}
