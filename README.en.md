<p align="center">
  <img src="docs/images/logo.svg" width="72" alt="logo">
</p>

<h1 align="center">AI Mac Mini Screen</h1>

<p align="center">A 240×240 weather and desktop dashboard — ESP8266 / ESP32-S3 · open hardware</p>

<p align="center">
  <a href="README.md">中文</a> · English
</p>

<p align="center">
  <a href="https://mac.qust.me">Website</a> ·
  <a href="https://mac.qust.me/#flash">Web flasher</a> ·
  <a href="https://github.com/pengchujin/esp8266-ai/releases/latest">Downloads</a>
</p>

<p align="center">
  <img src="docs/images/hero.jpg" width="640" alt="AI Mac mini screen">
</p>

This retro mini-TV defaults to a weather clock and can switch between music, stocks, and salary pages. The Mac bridge supports Wi-Fi and USB; Windows currently supports Wi-Fi only and does not provide weather data or location. The device retains provisioning, web administration, brightness, OTA, battery status, and IMU rotation; the Mac bridge supports multiple devices.

## Features

| | |
|---|---|
| <img src="docs/images/weather-clock.png" width="240" alt="Weather clock"> | **FuBoTV weather clock**<br>Reuses the factory weather, humidity, and astronaut artwork to show weather, air quality, date/time, temperature, and humidity. macOS supports automatic location or a manual city; the device ticks seconds locally. |
| <img src="docs/images/music.jpg" width="360" alt="Music playback"> | **Now-playing display**<br>Album art, title, artist, and progress stay in sync. Music temporarily replaces the default weather page and returns when playback stops. |

Also included:

- **Stocks**: the Mac fetches Tencent quotes and the device renders up to five symbols with prices and percentage changes; localized names use a compressed binary transport.
- **Salary clock**: converts monthly salary using 21.75 statutory working days, with workday and lunch schedule settings; lunch and weekends pause automatically.
- **Device administration**: remembered multi-device addresses and automatic pairing, brightness, bridge address, web OTA, ESP32-S3 battery status, and IMU auto-rotation.

## Getting started

You need an SD2 mini-TV board ([open hardware](https://oshwhub.com/q21182889/sd2), also available [pre-assembled](https://mobile.yangkeduo.com/goods.html?ps=OuPjGMWE82)) and a USB **data** cable.

1. Open the [web flasher](https://mac.qust.me/#flash) in Chrome or Edge and flash the device.
2. On first boot, join the `AI-Clock-Setup` hotspot and configure home Wi-Fi at `192.168.4.1`.
3. Install the macOS or Windows bridge from [Releases](https://github.com/pengchujin/esp8266-ai/releases/latest).

On macOS, left-click the menu-bar icon for the live mirror and brightness slider. Right-click for device selection, page switching, feature toggles, weather location, stocks, salary settings, bridge address, and OTA updates. The Windows tray provides device discovery/control, page switching, stocks, and bridge settings.

Devices on the same LAN are discovered and paired automatically. The Mac bridge uses USB serial when connected, which works around AP client isolation or avoids Wi-Fi setup entirely. The bridge keeps a minimal `/status` heartbeat containing only a timestamp and music-playing flag; legacy `auto`, `claude`, `codex`, `home`, `usage`, `info`, `net`, and `pomodoro` display modes safely migrate to the default weather page.

When the Mac sleeps, the bridge pauses media, stock, and weather polling and resumes after wake. The ESP32-S3 build supports battery indication and IMU auto-rotation, and the device web page provides password-protected OTA updates.

See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for hardware, API, and build details or [windows-app/README.md](windows-app/README.md) for Windows notes.

## Bambu printer monitor (ESP8266 / ESP32-S3)

Waveshare ESP32-S3-Touch-LCD-1.54 supports one LAN MQTT printer independently
of the Mac. This local-source feature requires matching builds from this checkout;
the changes have not been published to upstream releases or its web flasher.
It displays progress, remaining time, layers, nozzle and bed
temperatures, including X2D dual-nozzle telemetry. Use **打印机设置…** in the Mac
menu-bar context menu and authenticate with the device's OTA credentials.
Never put printer access codes in chat or Git.

This is LAN read-only monitoring, not cloud login, camera streaming, or printer
control. ESP8266 receives compact telemetry through the Mac bridge over Wi-Fi
or USB; the Mac must remain awake with the app running. Its printer credentials
are stored only in macOS Keychain. Use the native Mac settings dialog to enable
monitoring and explicitly opt into trusted-LAN self-signed TLS if needed.
Windows does not implement this printer bridge. Pomodoro has been removed from all
firmware and desktop code. See [printer setup and security](docs/PRINTER.md).
Real-printer connectivity and physical-screen behavior remain to be verified.
