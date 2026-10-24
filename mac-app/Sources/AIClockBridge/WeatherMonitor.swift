import AppKit
import Foundation

final class WeatherMonitor {
    struct WiredScreenSnapshot {
        let revision: Int
        let encoded: Data
        let decodedSize: Int
    }

    struct WiredAstronautSnapshot {
        let revision: Int
        let frames: Int
        let encoded: Data
        let decodedSize: Int
    }

    struct Snapshot: Equatable {
        var city = "\u{5357}\u{4EAC}"
        var timeZoneIdentifier = "Asia/Shanghai"
        var condition = "\u{7B49}\u{5F85}\u{5929}\u{6C14}\u{6570}\u{636E}"
        var temperature: Int?
        var humidity: Int?
        var airQualityIndex: Int?
        var weatherCode = 3
        var updatedAt = Date.distantPast
    }

    private struct WeatherValues {
        let temperature: Int
        let humidity: Int
        let weatherCode: Int
    }

    private static let refreshInterval: TimeInterval = 10 * 60
    private static let screenSize = 240
    static let astronautWidth = 72
    static let astronautHeight = 72
    static let astronautFrameCount = 20
    static let astronautAssetRevision = 1
    static let astronautFrameIntervalMilliseconds = 30
    static let clockColonLeft: CGFloat = 88
    static let clockColonTop: CGFloat = 69
    private static let factoryWeatherIcons: [NSImage?] = (0...7).map {
        loadFactoryAsset(name: String($0), extension: "jpeg", subdirectory: "FuBoTV/Weather")
    }
    private static let factoryAstronautFrames: [NSImage?] = (1...astronautFrameCount).map {
        loadFactoryAsset(name: "T\($0)", extension: "jpg",
                         subdirectory: "FuBoTV/Astronaut")
    }
    private static let factoryAstronautRGB565 = makeAstronautRGB565()
    private static let factoryAstronautRLE565: Data = {
        guard factoryAstronautRGB565.count > 2 else { return Data() }
        return encodeRGB565PackBits(factoryAstronautRGB565.dropFirst(2))
    }()
    private static let factoryTemperatureIcon = loadFactoryAsset(
        name: "W0", extension: "jpeg", subdirectory: "FuBoTV/Indicators"
    )
    private static let factoryHumidityIcon = loadFactoryAsset(
        name: "S0", extension: "jpeg", subdirectory: "FuBoTV/Indicators"
    )

    private let lock = NSLock()
    private let session: URLSession
    private let locationStore: WeatherLocationStore
    private let locationResolver: WeatherLocationResolving
    private var current = Snapshot()
    private var revision = 0
    private var locationRequestGeneration = 0
    private var timer: Timer?
    private var tasks: [URLSessionDataTask] = []
    private var cachedScreenRevision = -1
    private var cachedRGB565 = Data()
    private var cachedRLE565 = Data()
    private(set) var isRunning = false

    init(session: URLSession = .shared,
         initialSnapshot: Snapshot = Snapshot(),
         locationStore: WeatherLocationStore = WeatherLocationStore(),
         locationResolver: WeatherLocationResolving = SystemWeatherLocationResolver()) {
        self.session = session
        self.locationStore = locationStore
        self.locationResolver = locationResolver
        current = initialSnapshot
        if initialSnapshot.updatedAt == .distantPast {
            let location = locationStore.configuration.location
            current.city = location.city
            current.timeZoneIdentifier = location.timeZoneIdentifier
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        fetch()
        if locationStore.configuration.mode == .automatic {
            resolveAutomaticLocation(saveMode: false, completion: nil)
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) {
            [weak self] _ in
            self?.fetch()
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        timer?.invalidate()
        timer = nil
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
    }

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func jsonData(now: Date = Date()) -> Data {
        lock.lock()
        let value = current
        let screenRevision = Self.screenRevision(now: now, weatherRevision: revision)
        lock.unlock()
        let dictionary: [String: Any] = [
            "city": value.city,
            "condition": value.condition,
            "temperature_c": value.temperature.map { $0 as Any } ?? NSNull(),
            "humidity_pct": value.humidity.map { $0 as Any } ?? NSNull(),
            "aqi": value.airQualityIndex.map { $0 as Any } ?? NSNull(),
            "aqi_grade": Self.airQualityGrade(value.airQualityIndex),
            "weather_code": value.weatherCode,
            "epoch": Int(now.timeIntervalSince1970),
            "screen_rev": screenRevision,
            "astronaut_rev": Self.astronautAssetRevision,
            "astronaut_frames": Self.astronautFrameCount,
        ]
        return (try? JSONSerialization.data(withJSONObject: dictionary)) ?? Data("{}".utf8)
    }

    /// The base frame sent to devices. Seconds are deliberately omitted: the
    /// firmware draws that rectangle locally with Font 4 and owns its cadence.
    func screenRGB565(now: Date = Date()) -> Data {
        ensureScreen(now: now)
        lock.lock()
        defer { lock.unlock() }
        return cachedRGB565
    }

    func wiredScreenSnapshot(now: Date = Date()) -> WiredScreenSnapshot? {
        ensureScreen(now: now)
        lock.lock()
        defer { lock.unlock() }
        guard cachedScreenRevision >= 0,
              cachedRGB565.count == Self.screenSize * Self.screenSize * 2,
              !cachedRLE565.isEmpty else { return nil }
        return WiredScreenSnapshot(
            revision: cachedScreenRevision,
            encoded: cachedRLE565,
            decodedSize: cachedRGB565.count
        )
    }

    func screenImage(now: Date = Date()) -> NSImage? {
        lock.lock()
        let value = current
        lock.unlock()
        return Self.renderScreen(
            snapshot: value,
            now: now,
            includeAstronaut: true,
            includeSeconds: true
        )?.image
    }

    func astronautRGB565() -> Data {
        Self.factoryAstronautRGB565
    }

    func wiredAstronautSnapshot() -> WiredAstronautSnapshot? {
        guard Self.factoryAstronautRGB565.count > 2,
              !Self.factoryAstronautRLE565.isEmpty else { return nil }
        return WiredAstronautSnapshot(
            revision: Self.astronautAssetRevision,
            frames: Self.astronautFrameCount,
            encoded: Self.factoryAstronautRLE565,
            decodedSize: Self.factoryAstronautRGB565.count
        )
    }

    /// Pixel-oriented PackBits. A control byte with bit 7 set repeats one
    /// RGB565 pixel; otherwise it prefixes a literal sequence. Both forms
    /// encode 1...128 pixels and preserve the existing big-endian wire order.
    static func encodeRGB565PackBits<D: DataProtocol>(_ input: D) -> Data {
        let bytes = Array(input)
        guard !bytes.isEmpty, bytes.count.isMultiple(of: 2) else { return Data() }
        let pixelCount = bytes.count / 2
        func pixelEquals(_ lhs: Int, _ rhs: Int) -> Bool {
            bytes[lhs * 2] == bytes[rhs * 2] && bytes[lhs * 2 + 1] == bytes[rhs * 2 + 1]
        }
        func runLength(at start: Int) -> Int {
            var count = 1
            while start + count < pixelCount,
                  count < 128,
                  pixelEquals(start, start + count) {
                count += 1
            }
            return count
        }

        var output = Data()
        output.reserveCapacity(bytes.count / 2)
        var index = 0
        while index < pixelCount {
            let run = runLength(at: index)
            if run >= 3 {
                output.append(0x80 | UInt8(run - 1))
                output.append(bytes[index * 2])
                output.append(bytes[index * 2 + 1])
                index += run
                continue
            }

            let literalStart = index
            index += run
            while index < pixelCount, index - literalStart < 128 {
                let nextRun = runLength(at: index)
                if nextRun >= 3 { break }
                if index - literalStart + nextRun > 128 { break }
                index += nextRun
            }
            let literalCount = index - literalStart
            output.append(UInt8(literalCount - 1))
            output.append(contentsOf: bytes[(literalStart * 2)..<(index * 2)])
        }
        return output
    }

    var locationConfiguration: WeatherLocationConfiguration {
        locationStore.configuration
    }

    func setManualCity(_ city: String,
                       completion: @escaping (Result<WeatherLocation, Error>) -> Void) {
        locationRequestGeneration += 1
        let generation = locationRequestGeneration
        locationResolver.resolveCity(city) { [weak self] result in
            guard let self, generation == self.locationRequestGeneration else { return }
            switch result {
            case let .success(location):
                self.locationStore.save(mode: .manual, location: location)
                self.apply(location: location)
                completion(.success(location))
            case let .failure(error):
                completion(.failure(error))
            }
        }
    }

    func useAutomaticLocation(
        completion: @escaping (Result<WeatherLocation, Error>) -> Void
    ) {
        resolveAutomaticLocation(saveMode: true, completion: completion)
    }

    static func parseWeather(data: Data) -> (temperature: Int, humidity: Int, code: Int)? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = object["current"] as? [String: Any],
              let temperature = (current["temperature_2m"] as? NSNumber)?.doubleValue,
              let humidity = (current["relative_humidity_2m"] as? NSNumber)?.doubleValue,
              let code = (current["weather_code"] as? NSNumber)?.intValue else {
            return nil
        }
        return (Int(temperature.rounded()), Int(humidity.rounded()), code)
    }

    static func parseAirQuality(data: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = object["current"] as? [String: Any],
              let value = (current["us_aqi"] as? NSNumber)?.doubleValue else {
            return nil
        }
        return Int(value.rounded())
    }

    static func condition(for weatherCode: Int) -> String {
        switch weatherCode {
        case 0:
            return "\u{6674}"
        case 1:
            return "\u{6674}\u{95F4}\u{591A}\u{4E91}"
        case 2:
            return "\u{591A}\u{4E91}"
        case 3:
            return "\u{9634}"
        case 45, 48:
            return "\u{96FE}"
        case 51, 53, 55, 56, 57:
            return "\u{6BDB}\u{6BDB}\u{96E8}"
        case 61, 63, 65, 66, 67:
            return "\u{96E8}"
        case 71, 73, 75, 77:
            return "\u{96EA}"
        case 80, 81, 82:
            return "\u{9635}\u{96E8}"
        case 85, 86:
            return "\u{9635}\u{96EA}"
        case 95, 96, 99:
            return "\u{96F7}\u{9635}\u{96E8}"
        default:
            return "\u{5929}\u{6C14}\u{66F4}\u{65B0}\u{4E2D}"
        }
    }

    static func airQualityGrade(_ value: Int?) -> String {
        guard let value else { return "--" }
        switch value {
        case ...50:
            return "\u{4F18}"
        case ...100:
            return "\u{826F}"
        case ...150:
            return "\u{8F7B}\u{5EA6}"
        case ...200:
            return "\u{4E2D}\u{5EA6}"
        case ...300:
            return "\u{91CD}\u{5EA6}"
        default:
            return "\u{4E25}\u{91CD}"
        }
    }

    static func screenRevision(now: Date, weatherRevision: Int) -> Int {
        Int(now.timeIntervalSince1970 / 60) * 16 + weatherRevision % 16
    }

    static var factoryAssetsAvailable: Bool {
        factoryWeatherIcons.allSatisfy { $0 != nil }
            && factoryAstronautFrames.allSatisfy { $0 != nil }
            && factoryTemperatureIcon != nil
            && factoryHumidityIcon != nil
    }

    static func factoryWeatherIconIndex(for weatherCode: Int) -> Int {
        switch weatherCode {
        case 0:
            return 0
        case 1:
            return 1
        case 2, 3:
            return 2
        case 45, 48:
            return 7
        case 51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 80, 81, 82:
            return 3
        case 71, 73, 75, 77, 85, 86:
            return 5
        case 95, 96, 99:
            return 4
        default:
            return 6
        }
    }

    private func fetch() {
        let location = locationStore.configuration.location
        guard isRunning,
              let weatherURL = Self.weatherURL(for: location),
              let airURL = Self.airQualityURL(for: location) else {
            return
        }
        tasks.forEach { $0.cancel() }
        tasks.removeAll()

        let group = DispatchGroup()
        let resultLock = NSLock()
        var weather: WeatherValues?
        var airQuality: Int?

        group.enter()
        let weatherTask = session.dataTask(with: weatherURL) { data, _, _ in
            if let data, let parsed = Self.parseWeather(data: data) {
                resultLock.lock()
                weather = WeatherValues(
                    temperature: parsed.temperature,
                    humidity: parsed.humidity,
                    weatherCode: parsed.code
                )
                resultLock.unlock()
            }
            group.leave()
        }

        group.enter()
        let airTask = session.dataTask(with: airURL) { data, _, _ in
            if let data, let parsed = Self.parseAirQuality(data: data) {
                resultLock.lock()
                airQuality = parsed
                resultLock.unlock()
            }
            group.leave()
        }

        tasks = [weatherTask, airTask]
        weatherTask.resume()
        airTask.resume()
        group.notify(queue: .main) { [weak self] in
            guard let self, self.isRunning else { return }
            resultLock.lock()
            let fetchedWeather = weather
            let fetchedAirQuality = airQuality
            resultLock.unlock()
            self.apply(weather: fetchedWeather, airQuality: fetchedAirQuality)
        }
    }

    private func apply(weather: WeatherValues?, airQuality: Int?) {
        guard weather != nil || airQuality != nil else { return }
        lock.lock()
        if let weather {
            current.temperature = weather.temperature
            current.humidity = weather.humidity
            current.weatherCode = weather.weatherCode
            current.condition = Self.condition(for: weather.weatherCode)
        }
        if let airQuality {
            current.airQualityIndex = airQuality
        }
        current.updatedAt = Date()
        revision += 1
        cachedScreenRevision = -1
        lock.unlock()
    }

    private func resolveAutomaticLocation(
        saveMode: Bool,
        completion: ((Result<WeatherLocation, Error>) -> Void)?
    ) {
        locationRequestGeneration += 1
        let generation = locationRequestGeneration
        if saveMode {
            locationStore.save(mode: .automatic)
        }
        locationResolver.resolveAutomatic { [weak self] result in
            guard let self, generation == self.locationRequestGeneration,
                  self.locationStore.configuration.mode == .automatic else { return }
            switch result {
            case let .success(location):
                self.locationStore.save(mode: .automatic, location: location)
                self.apply(location: location)
            case .failure:
                break
            }
            completion?(result)
        }
    }

    private func apply(location: WeatherLocation) {
        lock.lock()
        current.city = location.city
        current.timeZoneIdentifier = location.timeZoneIdentifier
        revision += 1
        cachedScreenRevision = -1
        lock.unlock()
        fetch()
    }

    private func ensureScreen(now: Date) {
        lock.lock()
        let screenRevision = Self.screenRevision(now: now, weatherRevision: revision)
        if cachedScreenRevision == screenRevision {
            lock.unlock()
            return
        }
        let value = current
        lock.unlock()

        guard let rendered = Self.renderScreen(
            snapshot: value,
            now: now,
            includeAstronaut: Self.factoryAstronautRGB565.isEmpty,
            includeSeconds: false
        ) else { return }
        lock.lock()
        cachedScreenRevision = screenRevision
        cachedRGB565 = rendered.rgb565
        cachedRLE565 = Self.encodeRGB565PackBits(rendered.rgb565)
        lock.unlock()
    }

    static func weatherURL(for location: WeatherLocation) -> URL? {
        dataURL(
            host: "api.open-meteo.com",
            path: "/v1/forecast",
            location: location,
            current: "temperature_2m,relative_humidity_2m,weather_code"
        )
    }

    static func airQualityURL(for location: WeatherLocation) -> URL? {
        dataURL(
            host: "air-quality-api.open-meteo.com",
            path: "/v1/air-quality",
            location: location,
            current: "us_aqi"
        )
    }

    private static func dataURL(host: String, path: String,
                                location: WeatherLocation, current: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(location.latitude)),
            URLQueryItem(name: "longitude", value: String(location.longitude)),
            URLQueryItem(name: "current", value: current),
            URLQueryItem(name: "timezone", value: "auto"),
        ]
        return components.url
    }

    private static func renderScreen(
        snapshot: Snapshot,
        now: Date,
        includeAstronaut: Bool,
        includeSeconds: Bool
    )
        -> (image: NSImage, rgb565: Data)?
    {
        let width = screenSize
        let height = screenSize
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)

        drawHeader(snapshot: snapshot, context: context)
        drawClock(snapshot: snapshot, now: now, includeSeconds: includeSeconds)
        drawEnvironment(snapshot: snapshot, context: context)
        if includeAstronaut {
            drawAstronaut(now: now)
        }

        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage(),
              let rgb565 = rgb565Data(context: context, width: width, height: height) else {
            return nil
        }
        return (NSImage(cgImage: image, size: NSSize(width: width, height: height)), rgb565)
    }

    private static func drawHeader(snapshot: Snapshot, context: CGContext) {
        drawText(snapshot.city, top: 14, left: 18, width: 78, height: 34,
                 font: cjkFont(ofSize: 25, semibold: true), color: .white)

        let grade = airQualityGrade(snapshot.airQualityIndex)
        let pillColor = airQualityColor(snapshot.airQualityIndex)
        context.setFillColor(pillColor.cgColor)
        let pill = topRect(x: 99, y: 15, width: 58, height: 29)
        context.addPath(CGPath(roundedRect: pill, cornerWidth: 6, cornerHeight: 6,
                               transform: nil))
        context.fillPath()
        drawText(grade, top: 17, left: 99, width: 58, height: 25,
                 font: cjkFont(ofSize: grade.count > 1 ? 15 : 20, semibold: false),
                 color: NSColor(white: 0.15, alpha: 1), alignment: .center)

        drawWeatherIcon(code: snapshot.weatherCode, context: context)
        let summary = "\u{4ECA}\u{65E5}" + snapshot.condition
        drawText(summary, top: 50, left: 8, width: 158, height: 30,
                 font: cjkFont(ofSize: 19, semibold: true), color: .white)
    }

    private static func drawClock(snapshot: Snapshot, now: Date, includeSeconds: Bool) {
        let calendar = Calendar(identifier: .gregorian)
        let timeZone = TimeZone(identifier: snapshot.timeZoneIdentifier)
            ?? TimeZone(identifier: WeatherLocation.fallback.timeZoneIdentifier)!
        let components = calendar.dateComponents(in: timeZone, from: now)
        let hour = String(format: "%02d", components.hour ?? 0)
        let minute = String(format: "%02d", components.minute ?? 0)
        let second = String(format: "%02d", components.second ?? 0)
        let timeFont = NSFont.monospacedDigitSystemFont(ofSize: 65, weight: .bold)
        let orange = NSColor(calibratedRed: 1.0, green: 0.61, blue: 0.25, alpha: 1)
        drawClockText(hour, top: 76, left: 5, font: timeFont, color: .white)
        drawClockText(
            ":",
            top: clockColonTop,
            left: clockColonLeft,
            font: timeFont,
            color: orange
        )
        drawClockText(minute, top: 76, left: 101, font: timeFont, color: orange)
        if includeSeconds {
            drawText(second, top: 103, left: 198, width: 37, height: 32,
                     font: .monospacedDigitSystemFont(ofSize: 25, weight: .bold),
                     color: .white)
        }

        let month = components.month ?? 1
        let day = components.day ?? 1
        let weekday = ["", "\u{65E5}", "\u{4E00}", "\u{4E8C}", "\u{4E09}",
                       "\u{56DB}", "\u{4E94}", "\u{516D}"][components.weekday ?? 1]
        let date = "\(month)\u{6708}\(day)\u{65E5}"
        drawText(date, top: 153, left: 10, width: 112, height: 33,
                 font: cjkFont(ofSize: 24, semibold: true), color: .white)
        drawText("\u{5468}" + weekday, top: 155, left: 125, width: 42, height: 30,
                 font: cjkFont(ofSize: 20, semibold: true), color: .white)
    }

    private static func drawEnvironment(snapshot: Snapshot, context: CGContext) {
        drawThermometer(context: context, centerX: 25, centerY: 202)
        drawMeter(context: context, top: 193,
                  color: NSColor(calibratedRed: 0.95, green: 0.24, blue: 0.48, alpha: 1))
        let temperature = snapshot.temperature.map { "\($0)\u{00B0}C" } ?? "--\u{00B0}C"
        drawText(temperature, top: 189, left: 112, width: 56, height: 27,
                 font: .monospacedDigitSystemFont(ofSize: 22, weight: .bold), color: .white)

        drawHumidityDrop(context: context, centerX: 25, centerY: 229)
        drawMeter(context: context, top: 220,
                  color: NSColor(calibratedRed: 0.18, green: 0.88, blue: 0.66, alpha: 1))
        let humidity = snapshot.humidity.map { "\($0)%" } ?? "--%"
        drawText(humidity, top: 216, left: 112, width: 56, height: 25,
                 font: .monospacedDigitSystemFont(ofSize: 22, weight: .bold), color: .white)
    }

    private static func drawWeatherIcon(code: Int, context: CGContext) {
        let index = factoryWeatherIconIndex(for: code)
        if index < factoryWeatherIcons.count,
           let image = factoryWeatherIcons[index]
        {
            drawFactoryAsset(image, in: topRect(x: 164, y: 6, width: 76, height: 76))
            return
        }

        let sunColor = NSColor(calibratedRed: 1.0, green: 0.70, blue: 0.20, alpha: 1)
        context.setFillColor(sunColor.cgColor)
        context.fillEllipse(in: topRect(x: 187, y: 13, width: 31, height: 31))
        context.setStrokeColor(sunColor.cgColor)
        context.setLineWidth(2)
        for angle in stride(from: 0.0, to: Double.pi * 2, by: Double.pi / 4) {
            let x1 = 202.5 + cos(angle) * 20
            let y1 = 28.5 + sin(angle) * 20
            let x2 = 202.5 + cos(angle) * 25
            let y2 = 28.5 + sin(angle) * 25
            context.move(to: topPoint(x: x1, y: y1))
            context.addLine(to: topPoint(x: x2, y: y2))
        }
        context.strokePath()

        let cloudy = code != 0
        if cloudy {
            context.setFillColor(NSColor(calibratedRed: 0.72, green: 0.85, blue: 0.96,
                                         alpha: 1).cgColor)
            context.fillEllipse(in: topRect(x: 163, y: 28, width: 39, height: 29))
            context.fillEllipse(in: topRect(x: 182, y: 25, width: 34, height: 34))
            context.fill(topRect(x: 166, y: 39, width: 58, height: 20))
        }
        if [51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 80, 81, 82, 95, 96, 99]
            .contains(code)
        {
            context.setStrokeColor(NSColor.systemBlue.cgColor)
            context.setLineWidth(2)
            for x in [177.0, 191.0, 205.0, 219.0] {
                context.move(to: topPoint(x: x, y: 62))
                context.addLine(to: topPoint(x: x - 3, y: 69))
            }
            context.strokePath()
        }
    }

    private static func drawThermometer(context: CGContext, centerX: CGFloat,
                                        centerY: CGFloat)
    {
        if let factoryTemperatureIcon {
            drawFactoryAsset(
                factoryTemperatureIcon,
                in: topRect(x: centerX - 10, y: centerY - 10, width: 20, height: 20)
            )
            return
        }

        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(3)
        context.strokeEllipse(in: topRect(x: centerX - 6, y: centerY + 5,
                                          width: 12, height: 12))
        context.stroke(topRect(x: centerX - 3, y: centerY - 13, width: 6, height: 21))
        context.setFillColor(NSColor(calibratedRed: 0.95, green: 0.24, blue: 0.48,
                                     alpha: 1).cgColor)
        context.fillEllipse(in: topRect(x: centerX - 3, y: centerY + 8,
                                        width: 6, height: 6))
    }

    private static func drawHumidityDrop(context: CGContext, centerX: CGFloat,
                                         centerY: CGFloat)
    {
        if let factoryHumidityIcon {
            drawFactoryAsset(
                factoryHumidityIcon,
                in: topRect(x: centerX - 10, y: centerY - 10, width: 20, height: 20)
            )
            return
        }

        let path = CGMutablePath()
        path.move(to: topPoint(x: centerX, y: centerY - 14))
        path.addCurve(to: topPoint(x: centerX, y: centerY + 11),
                      control1: topPoint(x: centerX - 15, y: centerY),
                      control2: topPoint(x: centerX - 10, y: centerY + 11))
        path.addCurve(to: topPoint(x: centerX, y: centerY - 14),
                      control1: topPoint(x: centerX + 10, y: centerY + 11),
                      control2: topPoint(x: centerX + 15, y: centerY))
        context.setFillColor(NSColor(calibratedRed: 0.18, green: 0.88, blue: 0.66,
                                     alpha: 1).cgColor)
        context.addPath(path)
        context.fillPath()
    }

    private static func drawMeter(context: CGContext, top: CGFloat, color: NSColor) {
        context.setStrokeColor(NSColor(white: 0.9, alpha: 1).cgColor)
        context.setLineWidth(3)
        context.move(to: topPoint(x: 48, y: top + 9))
        context.addLine(to: topPoint(x: 108, y: top + 9))
        context.strokePath()
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(5)
        context.move(to: topPoint(x: 50, y: top + 9))
        context.addLine(to: topPoint(x: 92, y: top + 9))
        context.strokePath()
    }

    private static func drawAstronaut(now: Date) {
        let milliseconds = Int(now.timeIntervalSince1970 * 1_000)
        let frameIndex =
            milliseconds / astronautFrameIntervalMilliseconds % factoryAstronautFrames.count
        if let image = factoryAstronautFrames[frameIndex] {
            drawFactoryAsset(
                image,
                in: topRect(x: 168, y: 168, width: CGFloat(astronautWidth),
                            height: CGFloat(astronautHeight))
            )
            return
        }

        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: 208, y: 28)
        context.rotate(by: -0.35)
        context.setStrokeColor(NSColor(white: 0.8, alpha: 0.8).cgColor)
        context.setLineWidth(2)
        context.strokeEllipse(in: CGRect(x: -12, y: 12, width: 22, height: 22))
        context.stroke(CGRect(x: -13, y: -5, width: 24, height: 20))
        context.move(to: CGPoint(x: -13, y: 8))
        context.addLine(to: CGPoint(x: -23, y: 15))
        context.move(to: CGPoint(x: 11, y: 8))
        context.addLine(to: CGPoint(x: 20, y: 17))
        context.move(to: CGPoint(x: -7, y: -5))
        context.addLine(to: CGPoint(x: -11, y: -15))
        context.move(to: CGPoint(x: 5, y: -5))
        context.addLine(to: CGPoint(x: 11, y: -15))
        context.strokePath()
        context.restoreGState()
    }

    private static func makeAstronautRGB565() -> Data {
        guard factoryAstronautFrames.count == astronautFrameCount,
              factoryAstronautFrames.allSatisfy({ $0 != nil }) else {
            return Data()
        }
        var result = Data(capacity:
            2 + astronautFrameCount * astronautWidth * astronautHeight * 2)
        result.append(UInt8(astronautAssetRevision))
        result.append(UInt8(astronautFrameCount))
        for image in factoryAstronautFrames {
            guard let image,
                  let context = CGContext(
                    data: nil,
                    width: astronautWidth,
                    height: astronautHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: astronautWidth * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else {
                return Data()
            }
            context.setFillColor(NSColor.black.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: astronautWidth, height: astronautHeight))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            drawFactoryAsset(
                image,
                in: CGRect(x: 0, y: 0, width: astronautWidth, height: astronautHeight)
            )
            NSGraphicsContext.restoreGraphicsState()
            guard let frame = rgb565Data(
                context: context,
                width: astronautWidth,
                height: astronautHeight
            ) else {
                return Data()
            }
            result.append(frame)
        }
        return result
    }

    private static func rgb565Data(context: CGContext, width: Int, height: Int) -> Data? {
        guard let bytes = context.data else { return nil }
        let pixels = bytes.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var rgb565 = Data(capacity: width * height * 2)
        for index in 0..<(width * height) {
            let red = UInt16(pixels[index * 4] & 0xF8)
            let green = UInt16(pixels[index * 4 + 1] & 0xFC)
            let blue = UInt16(pixels[index * 4 + 2] >> 3)
            let value = (red << 8) | (green << 3) | blue
            rgb565.append(UInt8((value >> 8) & 0xFF))
            rgb565.append(UInt8(value & 0xFF))
        }
        return rgb565
    }

    private static func loadFactoryAsset(name: String, extension fileExtension: String,
                                         subdirectory: String) -> NSImage?
    {
        let bundle = Bundle.aiClockResources
        let url = bundle.url(
            forResource: name,
            withExtension: fileExtension,
            subdirectory: subdirectory
        ) ?? bundle.url(forResource: name, withExtension: fileExtension)
        guard let url else { return nil }
        return NSImage(contentsOf: url)
    }

    private static func drawFactoryAsset(_ image: NSImage, in rect: CGRect) {
        image.draw(
            in: rect,
            from: NSRect(origin: .zero, size: image.size),
            operation: .sourceOver,
            fraction: 1
        )
    }

    private static func cjkFont(ofSize size: CGFloat, semibold: Bool) -> NSFont {
        let names = semibold
            ? ["PingFangSC-Semibold", "PingFang SC Semibold"]
            : ["PingFangSC-Regular", "PingFang SC"]
        for name in names {
            if let font = NSFont(name: name, size: size) { return font }
        }
        return .systemFont(ofSize: size, weight: semibold ? .semibold : .regular)
    }

    private static func drawText(
        _ value: String,
        top: CGFloat,
        left: CGFloat,
        width: CGFloat,
        height: CGFloat,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment = .left
    ) {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = .byTruncatingTail
        (value as NSString).draw(
            in: NSRect(x: left, y: CGFloat(screenSize) - top - height,
                       width: width, height: height),
            withAttributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: style,
            ]
        )
    }

    private static func drawClockText(_ value: String, top: CGFloat, left: CGFloat,
                                      font: NSFont, color: NSColor)
    {
        (value as NSString).draw(
            at: NSPoint(x: left, y: CGFloat(screenSize) - top - font.ascender),
            withAttributes: [
                .font: font,
                .foregroundColor: color,
            ]
        )
    }

    private static func topRect(x: CGFloat, y: CGFloat, width: CGFloat,
                                height: CGFloat) -> CGRect
    {
        CGRect(x: x, y: CGFloat(screenSize) - y - height, width: width, height: height)
    }

    private static func topPoint(x: CGFloat, y: CGFloat) -> CGPoint {
        CGPoint(x: x, y: CGFloat(screenSize) - y)
    }

    private static func airQualityColor(_ value: Int?) -> NSColor {
        guard let value else { return NSColor.darkGray }
        switch value {
        case ...50:
            return NSColor(calibratedRed: 0.28, green: 0.95, blue: 0.35, alpha: 1)
        case ...100:
            return NSColor.systemYellow
        case ...150:
            return NSColor.systemOrange
        default:
            return NSColor.systemRed
        }
    }
}
