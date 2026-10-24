import AppKit

// Entry point. Runs as an "accessory" app (menu-bar only, no Dock icon, no main
// window) and starts the /status HTTP server that the ESP8266 clock polls.
if CommandLine.arguments.count >= 3,
   CommandLine.arguments[1] == "--render-weather-preview" {
    let output = URL(fileURLWithPath: CommandLine.arguments[2])
    let preview = WeatherMonitor.Snapshot(
        city: "\u{5357}\u{4EAC}",
        condition: "\u{591A}\u{4E91}\u{8F6C}\u{96F7}\u{9635}\u{96E8}",
        temperature: 33,
        humidity: 57,
        airQualityIndex: 42,
        weatherCode: 95,
        updatedAt: Date()
    )
    let monitor = WeatherMonitor(initialSnapshot: preview)
    guard let image = monitor.screenImage(),
          let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("weather preview rendering failed\n".utf8))
        exit(1)
    }
    do {
        try png.write(to: output, options: .atomic)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("weather preview write failed: \(error)\n".utf8))
        exit(1)
    }
}

let port: UInt16 = 8765
let service = StatusService()
let featurePreferences = FeaturePreferences.shared
let nowPlaying = NowPlayingMonitor()
service.musicPlayingProvider = {
    featurePreferences.isEnabled("music") && nowPlaying.snapshot.playing
}

let stockMonitor = StockMonitor()
let weatherMonitor = WeatherMonitor()
let printerBridge = PrinterBridge.shared

// Wired fallback: if the clock is plugged in over USB, push status down
// the serial line (works around AP client isolation; no WiFi setup needed).
let serialLink = SerialLink(
    service: service,
    stockMonitor: stockMonitor,
    weatherMonitor: weatherMonitor,
    printerStatusProvider: { printerBridge.snapshot() }
)
DeviceClient.wiredCommandHandler = { serialLink.sendCommand($0) }
DeviceClient.wiredInfoProvider = { serialLink.deviceInfo }

let server = HTTPServer(port: port, routes: [
    "/": { service.snapshot().jsonData() },
    "/status": { service.snapshot().jsonData() },
    "/music": { nowPlaying.jsonData() },
    "/stock": { stockMonitor.jsonData() },
    "/weather": { weatherMonitor.jsonData() },
    "/printer": { printerBridge.jsonData() },
], binaryRoutes: [
    "/music/cover.raw": { nowPlaying.coverRGB565 },
    "/music/text.raw": { nowPlaying.textRGB565 },
    "/stock/names.raw": { stockMonitor.namesRGB565() },
    "/stock/names-v2.raw": { stockMonitor.namesV2RGB565() },
    "/weather/screen.raw": { weatherMonitor.screenRGB565() },
    "/weather/astronaut.raw": { weatherMonitor.astronautRGB565() },
])
// Passive discovery: the clock polls us, so its source IP identifies it.
// Remember it (for auto-pairing / DHCP-change self-healing) and adopt it
// outright when no device is configured yet.
server.onRequest = { path, ip in
    guard path == "/status" || path == "/music" || path == "/stock"
            || path == "/weather" || path == "/weather/screen.raw"
            || path == "/weather/astronaut.raw" || path == "/printer",
          ip != "127.0.0.1", ip != "::1", !ip.isEmpty else { return }
    DeviceClient.devicePollAt = Date()
    DeviceClient.lastSeenIP = ip
    DeviceClient.registerDevice(ip)
}
do {
    try server.start()
    FileHandle.standardError.write(Data("[bridge] serving /status on 0.0.0.0:\(port)\n".utf8))
} catch {
    FileHandle.standardError.write(Data("[bridge] failed to bind port \(port): \(error)\n".utf8))
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let runtime = AppRuntimeController(
    featurePreferences: featurePreferences,
    alwaysOnActivities: [serialLink, printerBridge],
    featureActivities: [
        "music": nowPlaying,
        "stock": stockMonitor,
        "weather": weatherMonitor,
    ],
    pairingAction: { DeviceClient.healPairingIfNeeded(port: port) },
    cancelPairingAction: { DeviceClient.cancelPairingActivity() }
)
// The installed LaunchAgent can run headless so the bridge remains available
// for the clock without registering a macOS menu-bar item.
let menuBar: MenuBarController?
if ProcessInfo.processInfo.environment["AICLOCK_HEADLESS"] == "1" {
    menuBar = nil
} else {
    menuBar = MenuBarController(nowPlaying: nowPlaying, stockMonitor: stockMonitor,
                                weatherMonitor: weatherMonitor, port: port,
                                featurePreferences: featurePreferences,
                                featureConfigurationChanged: {
                                    runtime.applyFeatureConfiguration()
                                })
}
runtime.onWillSleep = { [weak menuBar] in menuBar?.systemWillSleep() }
runtime.onDidWake = { [weak menuBar] in menuBar?.systemDidWake() }
runtime.start()
_ = menuBar // retain
_ = runtime
app.run()
