# AIClockBridge for Windows

This Windows tray app pairs with AI Clock devices and serves the retained dashboard endpoints. It uses the same device HTTP API as the Mac bridge.

## Features

- Right-click the tray to:
  - discover/pair devices, set a device address, and open the device web page
  - switch between weather, music, stocks, and salary pages
  - configure stock symbols and point the device bridge at this PC
- Local HTTP service on `0.0.0.0:8765`:
  - `/status`: minimal timestamp and music-playing heartbeat
  - `/music`, `/stock`, `/music/*.raw`, and `/stock/names*.raw`
- Windows Now Playing powers the music page and Tencent quotes power the stock page.

Weather fetching and weather location configuration live in the Mac bridge. The Windows app can still select the device's weather page. Legacy Agent display modes normalize to weather.

## Requirements and build

Windows 10 19041+ / Windows 11 and the [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0) are required:

```powershell
cd windows-app\AIClockBridge
dotnet run
dotnet publish -c Release -r win-x64 --self-contained false
```

The first run may request local-network firewall access. Devices need access to TCP port 8765.

## Regression checks

```powershell
cd windows-app\BridgeTests
dotnet run
```

These checks cover the minimal heartbeat, legacy mode migration, and device discovery responses without obsolete agent fields. Pomodoro controls have been removed. Native printer configuration is available from the ESP32-S3 device web page; the Mac app additionally provides a dedicated menu and preview. WinForms interaction still requires manual validation on Windows.

Settings persist in `%APPDATA%\AIClockBridge\settings.json`.
