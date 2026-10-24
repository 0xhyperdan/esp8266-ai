# Development

This repository contains the ESP8266 / ESP32-S3 firmware and the macOS / Windows bridge apps. Retained user-facing pages are weather, music, stocks, and salary. Device administration covers multi-device pairing, Wi-Fi or USB transport, brightness, web OTA, IMU auto-rotation, and battery awareness.

```text
firmware/       Arduino firmware and PlatformIO environments
mac-app/        Swift menu-bar app and XCTest suite
windows-app/    WinForms tray app and focused bridge tests
docs/images/    Retained weather and feature artwork
```

## Status heartbeat

HTTP `GET /status` and USB `#STATUS` use the same minimal envelope:

```json
{
  "ts": 1780000000,
  "music_playing": false
}
```

`ts` anchors device-owned salary timing, and `music_playing` lets the default weather page temporarily promote to the music page. The firmware acknowledges a valid USB heartbeat with `#ACK status`. No agent state, task data, quota fields, pet settings, or lifecycle metadata are transmitted.

Legacy `auto`, `claude`, `codex`, `home`, `usage`, `info`, `net`, and `pomodoro` display values normalize to `weather` on macOS, Windows, over HTTP, and over USB. Bridge clients normalize unknown reported modes to weather; invalid device HTTP commands still return 400.

## Mac app

Printer telemetry is documented in [PRINTER.md](PRINTER.md). ESP32-S3 owns its
TLS MQTT connection; ESP8266 receives normalized full snapshots from Mac over
HTTP `/printer` or USB `#PRINTER`. The Mac owns the MQTT connection in that mode
and stores access codes only in Keychain. `/api/info.printer.supported` gates the
printer menu and preview; `printer.native` selects device or Mac configuration.
Pomodoro routes, commands, state, persistence code, and renderers are removed.

```bash
cd mac-app
swift run
swift test --disable-sandbox
swift build -c release --disable-sandbox
```

The app serves `/status`, `/music`, `/stock`, `/weather`, and their RGB565/compressed assets. It discovers multiple devices, mirrors the selected screen, controls brightness/pages/salary, configures weather and stocks, uploads firmware, and uses USB serial when a compatible port is linked. Sleep notifications pause monitors and wake notifications resume them.

Focused regression tests cover legacy mode migration, minimal status serialization, the USB `#STATUS` line format, clock discovery, weather assets, device transport, and sleep/wake behavior.

## Windows app

```powershell
cd windows-app\AIClockBridge
dotnet run
dotnet publish -c Release -r win-x64 --self-contained false

cd ..\BridgeTests
dotnet run
```

The tray app pairs and controls devices, switches retained pages, manages stocks, and serves `/status`, `/music`, `/stock`, and their music/stock binary assets. Weather data and location configuration are provided by the Mac bridge; the Windows app can still select the device's weather page.

`BridgeTests` covers the minimal heartbeat envelope, mode migration, and minimal `/api/info` discovery. WinForms behavior still requires a Windows host for manual release validation.

## Firmware

```bash
cd firmware
pio run -e nodemcuv2
pio run -e fubotv-usb
pio run -e waveshare-s3-touch-lcd-154
```

- `nodemcuv2`: SD2 / MG01 ESP8266 with Wi-Fi or CH340 USB.
- `fubotv-usb`: disables Wi-Fi, provisioning, and the web server; receives bridge data over serial.
- `waveshare-s3-touch-lcd-154`: Waveshare ESP32-S3-Touch-LCD-1.54 with QMI8658 rotation, touch, battery monitoring, 16 MB flash, and PSRAM.

The firmware owns salary configuration, brightness persistence, weather animation state, Wi-Fi provisioning, and password-protected OTA. ESP32-S3 battery and IMU state remain available through `/api/info`.

## Device HTTP API

Bridge-facing endpoints:

| Method | Path | Purpose |
|---|---|---|
| GET | `/status` | Minimal timestamp/music heartbeat |
| GET | `/music`, `/stock`, `/weather` | Feature payloads |
| GET | `/music/*.raw`, `/stock/names*.raw`, `/weather/*.raw` | RGB565/compressed assets |

Device administration:

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/info` | Device identity, transport, mode, hardware, salary, battery, orientation, OTA |
| POST | `/api/display` | `mode=weather,music,stock,salary,printer`; printer is native on ESP32-S3 and Mac-bridged on ESP8266; legacy Agent, `net`, and `pomodoro` modes migrate to weather |
| POST | `/api/bridge` | `host=ip:port` |
| POST | `/api/brightness` | `level=0..100` |
| POST | `/api/orientation` | `auto=true/false` when IMU is available |
| POST | `/api/salary` | Configure salary and paid schedule |

Agent app-server clients, session watchers, pet uploads, dual-provider mirrors, quota renderers, and removed-agent protocol libraries are intentionally absent.
