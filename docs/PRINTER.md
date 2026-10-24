# Bambu printer monitor

## Scope

The Waveshare ESP32-S3-Touch-LCD-1.54 firmware connects directly to one Bambu
printer on the same trusted LAN. Monitoring does not require the Mac bridge or
a USB data connection. Weather, music, stocks, salary, battery, rotation, and OTA
remain separate features. Pomodoro has been removed rather than hidden.

ESP8266 devices use the Mac app as the LAN MQTT client and receive compact
telemetry over Wi-Fi or USB. The Mac must remain awake with AIClockBridge running.
The small device does not allocate a TLS/MQTT client or receive printer credentials.
Windows does not implement this bridge.

This implementation covers LAN Direct, not Bambu Cloud account login, cloud-only
printers, camera streaming, AMS management, printer controls, or smart plugs.
Printer firmware must expose its local MQTT interface. Compatibility still needs
verification with the user's actual printer and firmware.

## Configuration

Build with a local `firmware/include/ota_secrets.h` created from the example
header and unique OTA credentials. This ignored file also authenticates printer
configuration. Without it, configuration writes are intentionally disabled;
there is no unauthenticated setup fallback.

1. Connect the ESP32-S3 and printer to the same trusted network.
2. Find the printer's local IP, serial number, and LAN Access Code in its network
   settings. Some printer firmware requires Developer Mode for local telemetry.
3. In AIClockBridge, select the ESP32-S3 device and open **打印机设置…** from
   the menu-bar context menu. The device page is also available at `/printer`.
4. Authenticate using the device's existing OTA credentials. Enter the printer
   details and explicitly accept its self-signed LAN TLS certificate.
5. Saving an enabled configuration selects the **打印机** display page. Configured
   devices restore that page after boot without waiting for the Mac bridge.
   The configuration page's monitoring
   switch disconnects the MQTT client when disabled; clearing configuration also
   removes the stored access code.

### ESP8266 configuration

1. Update both the Mac app and the matching ESP8266 firmware from this checkout.
2. Select the ESP8266 in the menu-bar app and choose **打印机设置…**.
3. Enter the printer's private IPv4, serial number, and LAN Access Code locally.
   A blank access code preserves it only for the same host and serial number.
4. Enable monitoring. If needed, explicitly consent to the printer's self-signed
   TLS certificate only on a trusted LAN. Saving selects the printer page.
5. Disable monitoring in the same dialog to disconnect, or use **清除配置** to
   remove the credentials from Keychain. Mac sleep disconnects; wake resumes only
   when monitoring is enabled.

Non-secret bridge configuration is in Mac preferences. The access code is in
macOS Keychain, not preferences, HTTP status, USB frames, or device flash.
Changing printer identity removes the previous saved access code. The dialog
never displays an existing access code. A trusted-LAN HTTP `/printer` endpoint
contains telemetry only; no configuration writes or credential reads are exposed.
Do not expose the bridge server to the public internet.

AIClockBridge offers the printer page when the selected device reports
`printer.supported=true`. The report identifies `source=bridge,native=false` on
ESP8266 and `source=native,native=true` on ESP32-S3. Old firmware must be updated
before the new menu becomes available. After 60 seconds without bridge snapshots,
ESP8266 marks data stale/offline rather than treating the last state as live.

## Display and freshness

The page shows state, job name, progress, remaining minutes, layers, nozzle
temperature, and bed temperature. Unknown values appear as `--`.
Chinese job names are available in the Mac preview; the device's built-in font
uses a generic job label when a job name is not printable ASCII.

MQTT reports are incremental: missing fields preserve previous known values,
not zero. A changed job resets job-specific counters. A connected socket with
no fresh print data is not treated as an idle printer. Stale/offline indicators
remain distinct from actual `IDLE` state. Reconnection is bounded and runs off
the UI thread.

## Protocol

- TLS MQTT port: `8883`; username: `bblp`.
- Subscribe: `device/<serial>/report`.
- The only publication is `pushing.command=pushall` to
  `device/<serial>/request`, requesting a status snapshot.
- No pause, resume, stop, G-code, heater, light, or print-start commands exist.
- `/api/info` includes a read-only `printer` object; `/api/printer` returns the
  same object. Neither returns the access code.
- `/api/printer/config` requires OTA authentication and returns non-secret
  configuration only.
- Configuration POSTs require OTA authentication, JSON, and
  `X-AIClock-Config: 1`. This custom header is intentional: a cross-origin HTML
  form cannot silently change printer credentials.

## Security boundaries

The device management page uses HTTP, including Basic authentication and setup
data. Only configure it on a trusted LAN; never expose it through public port
forwarding. The printer connection is encrypted, but its self-signed certificate
is not identity-verified. This requires explicit consent; it does not prevent
an attacker already present on the trusted LAN from impersonating a printer.

The access code is stored locally on the ESP32-S3 filesystem, not in Mac
preferences or public status responses. Flash encryption is not enabled by this
feature: someone with physical flash access can recover local credentials.

## Reference

Protocol behavior was studied from the local
[BambuHelper](https://github.com/Keralots/BambuHelper) checkout, especially
`src/bambu_mqtt.cpp`, `include/bambu_state.h`, and its LAN Direct documentation.
The integration uses a new minimal monitor and UI; it does not copy the full
application or its graphic assets. MQTT transport uses PubSubClient 2.8.
