import AppKit

// Entry point. Runs as an "accessory" app (menu-bar only, no Dock icon, no main
// window) and starts the /status HTTP server that the ESP8266 clock polls.
// Headless smoke test for the petdex -> RGB565 -> device pipeline (same code the
// pet picker window uses): AIClockBridge --test-pet <slug> <claude|codex> <host> [state]
if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == "--test-pet" {
    let slug = CommandLine.arguments[2]
    let slot = CommandLine.arguments[3]
    if CommandLine.arguments.count >= 5 { DeviceClient.host = CommandLine.arguments[4] }
    let size = slot == "claude" ? (w: 111, h: 120) : (w: 120, h: 120)
    let stateID = CommandLine.arguments.count >= 6 ? CommandLine.arguments[5] : "running"
    guard let state = PetdexService.states.first(where: { $0.id == stateID }) else {
        print("unknown pet state: \(stateID)"); exit(1)
    }
    PetdexService.loadManifest { result in
        guard case let .success(pets) = result, let pet = pets.first(where: { $0.slug == slug }) else {
            print("manifest load failed or slug not found"); exit(1)
        }
        print("pet: \(pet.displayName) \(pet.spritesheetUrl)")
        PetdexService.downloadSpritesheet(pet) { result in
            guard case let .success(sheet) = result else { print("sheet download failed"); exit(1) }
            print("sheet: \(sheet.width)x\(sheet.height)")
            guard let animation = PetdexService.buildAnimation(sheet: sheet, state: state,
                                                               targetW: size.w, targetH: size.h) else {
                print("animation build failed"); exit(1)
            }
            print("sprite: \(animation.sprite.count) bytes, uploading to \(DeviceClient.host) slot \(slot)...")
            DeviceClient.uploadPet(animation.sprite, fallbackGif: animation.gif, slot: slot) { error in
                print(error.map { "upload failed: \($0.localizedDescription)" } ?? "upload ok")
                exit(error == nil ? 0 : 1)
            }
        }
    }
    RunLoop.main.run() // completions land on the main queue; exit() above ends us
    exit(0)
}

let port: UInt16 = 8765
let service = StatusService()
let usage = UsageFetcher()
let featurePreferences = FeaturePreferences.shared
service.usage = usage
let netMonitor = NetSpeedMonitor()
let nowPlaying = NowPlayingMonitor()
service.musicPlayingProvider = {
    featurePreferences.isEnabled("music") && nowPlaying.snapshot.playing
}

let stockMonitor = StockMonitor()

// Wired fallback: if the clock is plugged in over USB, push status/net down
// the serial line (works around AP client isolation; no WiFi setup needed).
let serialLink = SerialLink(service: service, netMonitor: netMonitor, stockMonitor: stockMonitor)
DeviceClient.wiredCommandHandler = { serialLink.sendCommand($0) }
DeviceClient.wiredInfoProvider = { serialLink.deviceInfo }
DeviceClient.wiredPetUploadHandler = { data, slot, format, completion in
    serialLink.uploadPet(data, slot: slot, format: format, completion: completion)
}

let server = HTTPServer(port: port, routes: [
    "/": { service.snapshot().jsonData() },
    "/status": { service.snapshot().jsonData() },
    "/net": {
        let stats = SystemStatsMonitor.shared.snapshot()
        return netMonitor.jsonData(cpu: stats.cpu, mem: stats.mem)
    },
    "/music": { nowPlaying.jsonData() },
    "/stock": { stockMonitor.jsonData() },
], binaryRoutes: [
    "/music/cover.raw": { nowPlaying.coverRGB565 },
    "/music/text.raw": { nowPlaying.textRGB565 },
    "/stock/names.raw": { stockMonitor.namesRGB565() },
    "/stock/names-v2.raw": { stockMonitor.namesV2RGB565() },
], postRoutes: [
    // Claude Code / Codex hooks push lifecycle events here (see README §7):
    // curl -d '{"agent":"claude","event":"PreToolUse"}' http://127.0.0.1:8765/event
    "/event": { body in
        if let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let agent = obj["agent"] as? String, let event = obj["event"] as? String {
            service.recordEvent(agent: agent, event: event, message: obj["message"] as? String)
            return Data("{\"ok\":true}".utf8)
        }
        return Data("{\"ok\":false}".utf8)
    },
])
// Passive discovery: the clock polls us, so its source IP identifies it.
// Remember it (for auto-pairing / DHCP-change self-healing) and adopt it
// outright when no device is configured yet.
server.onRequest = { path, ip in
    guard path == "/status" || path == "/net" || path == "/music",
          ip != "127.0.0.1", ip != "::1", !ip.isEmpty else { return }
    DeviceClient.devicePollAt = Date()
    DeviceClient.lastSeenIP = ip
    if DeviceClient.host.isEmpty { DeviceClient.host = ip }
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
    alwaysOnActivities: [usage, serialLink],
    featureActivities: ["net": netMonitor, "music": nowPlaying, "stock": stockMonitor],
    pairingAction: { DeviceClient.healPairingIfNeeded(port: port) },
    cancelPairingAction: { DeviceClient.cancelPairingActivity() }
)
let menuBar = MenuBarController(service: service, usage: usage, netMonitor: netMonitor,
                                nowPlaying: nowPlaying, stockMonitor: stockMonitor, port: port,
                                featurePreferences: featurePreferences,
                                featureConfigurationChanged: {
                                    runtime.applyFeatureConfiguration()
                                })
runtime.onWillSleep = { [weak menuBar] in menuBar?.systemWillSleep() }
runtime.onDidWake = { [weak menuBar] in menuBar?.systemDidWake() }
runtime.start()
_ = menuBar // retain
_ = runtime
app.run()
