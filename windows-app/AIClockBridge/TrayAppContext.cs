using System.Diagnostics;
using System.Drawing;

namespace AIClockBridge;

// Windows tray host. Right-click exposes device controls and dashboard
// configuration served by the local bridge endpoints.
sealed class TrayAppContext : ApplicationContext
{
    readonly NotifyIcon _trayIcon;
    readonly int _port;
    readonly ContextMenuStrip _menu = new();
    readonly ToolStripMenuItem _deviceInfoItem = new("设备：未设置") { Enabled = false };
    readonly Dictionary<string, ToolStripMenuItem> _modeItems = new();
    DeviceInfo _latestDeviceInfo;

    public TrayAppContext(int port)
    {
        _port = port;
        BuildMenu();
        _trayIcon = new NotifyIcon
        {
            Icon = TrayIconFromAsset(),
            Text = "AI Clock Bridge",
            Visible = true,
            ContextMenuStrip = _menu,
        };
        _trayIcon.MouseUp += (_, eventArgs) =>
        {
            if (eventArgs.Button == MouseButtons.Left) ShowAddress();
        };
        _menu.Opening += (_, _) =>
        {
            _ = RefreshDeviceSection();
        };
    }

    static Icon TrayIconFromAsset()
    {
        var assembly = typeof(TrayAppContext).Assembly;
        using var stream = assembly.GetManifestResourceStream("AIClockBridge.Assets.happy-mac.png");
        if (stream == null) return SystemIcons.Application;
        using var bitmap = new Bitmap(stream);
        return Icon.FromHandle(bitmap.GetHicon());
    }

    void BuildMenu()
    {
        _menu.Items.Add(_deviceInfoItem);
        _menu.Items.Add(MakeItem("自动查找并配对设备", async (_, _) => await AutoPairAction()));
        _menu.Items.Add(MakeItem("设置设备地址…", (_, _) => SetDeviceAddress()));
        _menu.Items.Add(MakeItem("打开设备网页", (_, _) => OpenDevicePage()));

        var displayMenu = new ToolStripMenuItem("屏幕显示");
        foreach (var (title, mode) in new[]
        {
            ("天气时钟", "weather"), ("音乐播放", "music"),
            ("股票行情", "stock"), ("工资时钟", "salary"),
        })
        {
            var item = new ToolStripMenuItem(title);
            item.Click += async (_, _) => await SetDisplayMode(mode);
            _modeItems[mode] = item;
            displayMenu.DropDownItems.Add(item);
        }
        _menu.Items.Add(displayMenu);


        _menu.Items.Add(MakeItem("设置自选股…", (_, _) =>
        {
            var input = InputDialog.Show(
                "自选股",
                "逗号分隔的腾讯行情代码：sh/sz=A股、hk=港股、us=美股\n例如 sh600519,hk00700,usAAPL（设备最多显示 4 只）",
                string.Join(",", StockMonitor.Symbols), "sh000001,usAAPL");
            if (input != null)
            {
                StockMonitor.Symbols = input.Split(',',
                    StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
            }
        }));

        _menu.Items.Add(MakeItem("把本机设为设备桥接", async (_, _) => await PointBridgeHere()));
        _menu.Items.Add(new ToolStripSeparator());
        _menu.Items.Add(MakeItem("刷新", (_, _) =>
        {
            _ = RefreshDeviceSection();
        }));
        _menu.Items.Add(MakeItem("桥接服务地址", (_, _) => ShowAddress()));
        _menu.Items.Add(new ToolStripSeparator());
        _menu.Items.Add(MakeItem("退出", (_, _) =>
        {
            _trayIcon.Visible = false;
            Application.Exit();
        }));
    }

    static ToolStripMenuItem MakeItem(string title, EventHandler onClick)
    {
        var item = new ToolStripMenuItem(title);
        item.Click += onClick;
        return item;
    }

    async Task RefreshDeviceSection()
    {
        var host = DeviceClient.Host;
        if (host.Length == 0)
        {
            _deviceInfoItem.Text = "设备：未设置地址";
            foreach (var item in _modeItems.Values) item.Checked = false;
            return;
        }
        _deviceInfoItem.Text = $"设备：{host}（连接中…）";
        DeviceInfo info;
        try
        {
            info = await DeviceClient.FetchInfo();
        }
        catch
        {
            _deviceInfoItem.Text = $"设备：{host}（无法连接）";
            foreach (var item in _modeItems.Values) item.Checked = false;
            var seen = DeviceClient.LastSeenIp;
            if (seen.Length > 0 && !host.StartsWith(seen) && await DeviceClient.VerifyDevice(seen))
            {
                DeviceClient.Host = seen;
                await RefreshDeviceSection();
            }
            return;
        }
        _latestDeviceInfo = info;
        var showing = info.Effective switch
        {
            "music" => "音乐",
            "stock" => "股票",
            "weather" => "天气",
            "printer" => "打印机",
            "salary" => "工资",
            "auto" or "claude" or "codex" or "home" or "usage" or "info" => "天气",
            _ => info.Effective,
        };
        _deviceInfoItem.Text = $"设备：{info.Ip} · 正在显示 {showing}";
        foreach (var (mode, item) in _modeItems) item.Checked = mode == info.Mode;
    }

    async Task AutoPairAction()
    {
        _deviceInfoItem.Text = "设备：正在查找…";
        var ip = await DeviceClient.AutoPair(message => _deviceInfoItem.Text = $"设备：{message}");
        if (ip != null) Toast("配对成功", $"已找到设备并配对：{ip}");
        else Toast("未找到设备", """
            局域网内没有发现 ESP8266 时钟。请确认：
            1. 设备已通电并连上同一个 WiFi（首次使用需通过 AI-Clock-Setup 热点配网）
            2. 路由器未开启“客户端隔离”
            """);
        await RefreshDeviceSection();
    }

    void SetDeviceAddress()
    {
        var input = InputDialog.Show(
            "设备地址",
            "ESP8266 时钟的 IP（设备开机时屏幕上会显示，例如 192.168.1.50）",
            DeviceClient.Host, "192.168.1.50");
        if (input == null) return;
        DeviceClient.Host = input.Trim();
        _ = RefreshDeviceSection();
    }

    void OpenDevicePage()
    {
        var url = DeviceClient.BaseUrl;
        if (url == null)
        {
            SetDeviceAddress();
            return;
        }
        Process.Start(new ProcessStartInfo(url.ToString()) { UseShellExecute = true });
    }

    async Task SetDisplayMode(string mode)
    {
        try
        {
            await DeviceClient.SetDisplayMode(mode);
            await RefreshDeviceSection();
        }
        catch (Exception error)
        {
            Toast("切换失败", error.Message);
        }
    }


    async Task PointBridgeHere()
    {
        var ip = DeviceClient.LocalIPv4();
        if (ip == null)
        {
            Toast("失败", "获取本机局域网 IP 失败");
            return;
        }
        var bridge = $"{ip}:{_port}";
        try
        {
            await DeviceClient.SetBridgeHost(bridge);
            Toast("已设置", $"设备将从 http://{bridge}/status 拉取心跳数据");
        }
        catch (Exception error)
        {
            Toast("设置失败", error.Message);
        }
    }

    void ShowAddress()
    {
        var ip = DeviceClient.LocalIPv4() ?? "<本机局域网IP>";
        Toast("桥接服务地址", $"http://{ip}:{_port}/status\n\n设备端 Bridge host 填：{ip}:{_port}");
    }

    static void Toast(string title, string text) =>
        MessageBox.Show(text, title, MessageBoxButtons.OK, MessageBoxIcon.Information);
}

static class InputDialog
{
    public static string Show(string title, string message, string value, string placeholder)
    {
        using var form = new Form
        {
            Text = title,
            FormBorderStyle = FormBorderStyle.FixedDialog,
            StartPosition = FormStartPosition.CenterScreen,
            MinimizeBox = false,
            MaximizeBox = false,
            ShowInTaskbar = false,
            Font = new Font("Microsoft YaHei UI", 9f),
            ClientSize = new Size(380, 140),
            TopMost = true,
        };
        var label = new Label { Text = message };
        label.SetBounds(14, 12, 352, 40);
        var textBox = new TextBox { Text = value, PlaceholderText = placeholder };
        textBox.SetBounds(14, 58, 352, 24);
        var ok = new Button { Text = "保存", DialogResult = DialogResult.OK };
        ok.SetBounds(196, 96, 80, 28);
        var cancel = new Button { Text = "取消", DialogResult = DialogResult.Cancel };
        cancel.SetBounds(286, 96, 80, 28);
        form.Controls.AddRange(new Control[] { label, textBox, ok, cancel });
        form.AcceptButton = ok;
        form.CancelButton = cancel;
        return form.ShowDialog() == DialogResult.OK ? textBox.Text : null;
    }
}
