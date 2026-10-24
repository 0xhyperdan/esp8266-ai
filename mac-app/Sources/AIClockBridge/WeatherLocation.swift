import CoreLocation
import Foundation

enum WeatherLocationMode: String {
    case automatic
    case manual
}

struct WeatherLocation: Equatable {
    var city: String
    var latitude: Double
    var longitude: Double
    var timeZoneIdentifier: String

    static let fallback = WeatherLocation(
        city: "\u{5357}\u{4EAC}",
        latitude: 32.0603,
        longitude: 118.7969,
        timeZoneIdentifier: "Asia/Shanghai"
    )
}

struct WeatherLocationConfiguration: Equatable {
    var mode: WeatherLocationMode
    var location: WeatherLocation
}

final class WeatherLocationStore {
    private enum Key {
        static let mode = "weather.location.mode"
        static let city = "weather.location.city"
        static let latitude = "weather.location.latitude"
        static let longitude = "weather.location.longitude"
        static let timeZone = "weather.location.timeZone"
        static let hasCoordinates = "weather.location.hasCoordinates"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var configuration: WeatherLocationConfiguration {
        let mode = WeatherLocationMode(rawValue: defaults.string(forKey: Key.mode) ?? "")
            ?? .automatic
        guard defaults.bool(forKey: Key.hasCoordinates) else {
            return WeatherLocationConfiguration(mode: mode, location: .fallback)
        }
        let location = WeatherLocation(
            city: defaults.string(forKey: Key.city) ?? WeatherLocation.fallback.city,
            latitude: defaults.double(forKey: Key.latitude),
            longitude: defaults.double(forKey: Key.longitude),
            timeZoneIdentifier: defaults.string(forKey: Key.timeZone)
                ?? WeatherLocation.fallback.timeZoneIdentifier
        )
        return WeatherLocationConfiguration(mode: mode, location: location)
    }

    func save(mode: WeatherLocationMode, location: WeatherLocation? = nil) {
        defaults.set(mode.rawValue, forKey: Key.mode)
        guard let location else { return }
        defaults.set(location.city, forKey: Key.city)
        defaults.set(location.latitude, forKey: Key.latitude)
        defaults.set(location.longitude, forKey: Key.longitude)
        defaults.set(location.timeZoneIdentifier, forKey: Key.timeZone)
        defaults.set(true, forKey: Key.hasCoordinates)
    }
}

protocol WeatherLocationResolving: AnyObject {
    func resolveAutomatic(completion: @escaping (Result<WeatherLocation, Error>) -> Void)
    func resolveCity(_ city: String,
                     completion: @escaping (Result<WeatherLocation, Error>) -> Void)
}

enum WeatherLocationError: LocalizedError {
    case locationServicesDisabled
    case permissionDenied
    case locationUnavailable
    case cityNotFound

    var errorDescription: String? {
        switch self {
        case .locationServicesDisabled:
            return "\u{7CFB}\u{7EDF}\u{5B9A}\u{4F4D}\u{670D}\u{52A1}\u{672A}\u{5F00}\u{542F}"
        case .permissionDenied:
            return "\u{672A}\u{83B7}\u{5F97}\u{5B9A}\u{4F4D}\u{6743}\u{9650}\u{FF0C}\u{8BF7}\u{5728}\u{7CFB}\u{7EDF}\u{8BBE}\u{7F6E}\u{7684}\u{201C}\u{9690}\u{79C1}\u{4E0E}\u{5B89}\u{5168}\u{6027} \u{2192} \u{5B9A}\u{4F4D}\u{670D}\u{52A1}\u{201D}\u{4E2D}\u{5141}\u{8BB8} AIClockBridge"
        case .locationUnavailable:
            return "\u{6682}\u{65F6}\u{65E0}\u{6CD5}\u{83B7}\u{53D6}\u{5F53}\u{524D}\u{4F4D}\u{7F6E}"
        case .cityNotFound:
            return "\u{672A}\u{627E}\u{5230}\u{8BE5}\u{57CE}\u{5E02}\u{FF0C}\u{8BF7}\u{6362}\u{4E00}\u{4E2A}\u{66F4}\u{5B8C}\u{6574}\u{7684}\u{540D}\u{79F0}"
        }
    }
}

final class SystemWeatherLocationResolver: NSObject, WeatherLocationResolving,
                                           CLLocationManagerDelegate {
    private lazy var locationManager: CLLocationManager = {
        let manager = CLLocationManager()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        return manager
    }()
    private let geocoder = CLGeocoder()
    private var automaticCompletion: ((Result<WeatherLocation, Error>) -> Void)?

    func resolveAutomatic(completion: @escaping (Result<WeatherLocation, Error>) -> Void) {
        DispatchQueue.main.async {
            guard CLLocationManager.locationServicesEnabled() else {
                completion(.failure(WeatherLocationError.locationServicesDisabled))
                return
            }
            self.automaticCompletion = completion
            switch self.locationManager.authorizationStatus {
            case .notDetermined:
                self.locationManager.requestWhenInUseAuthorization()
            case .authorizedAlways, .authorized:
                self.locationManager.requestLocation()
            case .denied, .restricted:
                self.finishAutomatic(.failure(WeatherLocationError.permissionDenied))
            @unknown default:
                self.finishAutomatic(.failure(WeatherLocationError.locationUnavailable))
            }
        }
    }

    func resolveCity(_ city: String,
                     completion: @escaping (Result<WeatherLocation, Error>) -> Void) {
        let query = city.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            completion(.failure(WeatherLocationError.cityNotFound))
            return
        }
        geocoder.cancelGeocode()
        geocoder.geocodeAddressString(
            query,
            in: nil,
            preferredLocale: Locale(identifier: "zh-Hans")
        ) { placemarks, error in
            DispatchQueue.main.async {
                guard error == nil,
                      let placemark = placemarks?.first,
                      let coordinate = placemark.location?.coordinate else {
                    completion(.failure(WeatherLocationError.cityNotFound))
                    return
                }
                completion(.success(Self.location(
                    coordinate: coordinate,
                    placemark: placemark,
                    fallbackCity: query
                )))
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard automaticCompletion != nil else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorized:
            manager.requestLocation()
        case .denied, .restricted:
            finishAutomatic(.failure(WeatherLocationError.permissionDenied))
        case .notDetermined:
            break
        @unknown default:
            finishAutomatic(.failure(WeatherLocationError.locationUnavailable))
        }
    }

    func locationManager(_ manager: CLLocationManager,
                         didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else {
            finishAutomatic(.failure(WeatherLocationError.locationUnavailable))
            return
        }
        geocoder.reverseGeocodeLocation(
            location,
            preferredLocale: Locale(identifier: "zh-Hans")
        ) { [weak self] placemarks, _ in
            guard let self else { return }
            let resolved = Self.location(
                coordinate: location.coordinate,
                placemark: placemarks?.first,
                fallbackCity: "\u{5F53}\u{524D}\u{4F4D}\u{7F6E}"
            )
            DispatchQueue.main.async {
                self.finishAutomatic(.success(resolved))
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finishAutomatic(.failure(WeatherLocationError.locationUnavailable))
    }

    private func finishAutomatic(_ result: Result<WeatherLocation, Error>) {
        let completion = automaticCompletion
        automaticCompletion = nil
        completion?(result)
    }

    private static func location(coordinate: CLLocationCoordinate2D,
                                 placemark: CLPlacemark?,
                                 fallbackCity: String) -> WeatherLocation {
        let rawCity = placemark?.locality
            ?? placemark?.subAdministrativeArea
            ?? placemark?.administrativeArea
            ?? fallbackCity
        return WeatherLocation(
            city: normalizedCity(rawCity),
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            timeZoneIdentifier: placemark?.timeZone?.identifier
                ?? WeatherLocation.fallback.timeZoneIdentifier
        )
    }

    static func normalizedCity(_ value: String) -> String {
        var city = value.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in ["\u{7279}\u{522B}\u{884C}\u{653F}\u{533A}", "\u{5E02}"] where city.hasSuffix(suffix) {
            city.removeLast(suffix.count)
            break
        }
        return city.isEmpty ? WeatherLocation.fallback.city : city
    }
}
