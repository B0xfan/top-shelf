import AppKit
import CoreLocation
import EventKit
import Observation

/// The current or next event today, from every calendar on the Mac.
@Observable
final class CalendarService {
    struct Event: Equatable {
        var title: String
        var start: Date
        var end: Date
        var color: NSColor?
    }

    var next: Event?
    var now = Date()   // refreshed every minute so "in N minutes" counts down
    var access: Bool?  // nil until asked
    private let store = EKEventStore()
    private var timer: Timer?

    init(live: Bool) {
        guard live else { return }
        store.requestFullAccessToEvents { granted, _ in
            DispatchQueue.main.async { self.access = granted; self.refresh() }
        }
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in self?.refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        now = Date()
        guard access == true, let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now)) else { next = nil; return }
        let events = store.events(matching: store.predicateForEvents(withStart: now, end: end, calendars: nil))
            .filter { !$0.isAllDay }
            .map { Event(title: $0.title ?? "Event", start: $0.startDate, end: $0.endDate, color: $0.calendar?.color) }
        next = Self.pick(events, now: now)
    }

    /// The event under way or the next to start; all-day events are left out by the caller.
    static func pick(_ events: [Event], now: Date) -> Event? {
        events.filter { $0.end > now }.min { $0.start < $1.start }
    }

    static func when(_ e: Event, now: Date) -> String {
        if e.start <= now { return "now, until " + e.end.formatted(date: .omitted, time: .shortened) }
        let minutes = Int((e.start.timeIntervalSince(now) / 60).rounded(.up))
        if minutes < 60 { return "in \(minutes) minute\(minutes == 1 ? "" : "s")" }
        return "at " + e.start.formatted(date: .omitted, time: .shortened)
    }

}

/// Current weather from Open-Meteo (free, no account), refreshed every 30 minutes, for where the Mac is
/// or for a place picked in Settings.
@Observable
final class WeatherService: NSObject, CLLocationManagerDelegate {
    struct Place: Codable, Hashable {
        var name: String, region: String, country: String, latitude: Double, longitude: Double
        var label: String { [name, region, country].filter { !$0.isEmpty }.joined(separator: ", ") }
    }
    enum Source: String { case current, place }

    var temperature: Measurement<UnitTemperature>?
    var code: Int?
    var place: String?
    var locationOff = false
    var offline = false
    /// Settings: where the weather is for. Saved at once and applied straight away.
    var source: Source = Source(rawValue: UserDefaults.standard.string(forKey: "weatherSource") ?? "") ?? .current {
        didSet { UserDefaults.standard.set(source.rawValue, forKey: "weatherSource"); restart() }
    }
    var chosen: Place? = UserDefaults.standard.data(forKey: "weatherPlace").flatMap { try? JSONDecoder().decode(Place.self, from: $0) } {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(chosen), forKey: "weatherPlace"); restart() }
    }
    private(set) var here: CLLocationCoordinate2D?
    private let live: Bool
    private let manager = CLLocationManager()
    private var timer: Timer?

    init(live: Bool) {
        self.live = live
        super.init()
        guard live else { return }
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        timer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }

    /// The spot the weather is for right now: the picked place, or where the Mac is.
    var target: (latitude: Double, longitude: Double)? {
        source == .place ? chosen.map { ($0.latitude, $0.longitude) } : here.map { ($0.latitude, $0.longitude) }
    }

    /// Clears what was shown for the old spot and fetches for the new one.
    private func restart() {
        temperature = nil; code = nil; place = nil; offline = false
        refresh()
    }

    func refresh() {
        guard live else { return }
        if source == .place {
            guard let p = chosen else { return }
            place = p.name
            Task { await fetch(p.latitude, p.longitude) }
        } else if manager.authorizationStatus == .authorized || manager.authorizationStatus == .authorizedAlways {
            manager.requestLocation()
        }
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        switch m.authorizationStatus {
        case .notDetermined: locationOff = false; m.requestWhenInUseAuthorization()
        case .authorized, .authorizedAlways: locationOff = false; if source == .current { m.requestLocation() }
        default: locationOff = true
        }
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {}

    func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        here = loc.coordinate
        guard source == .current else { return }
        CLGeocoder().reverseGeocodeLocation(loc) { [weak self] marks, _ in
            DispatchQueue.main.async { if self?.source == .current { self?.place = marks?.first?.locality ?? marks?.first?.name } }
        }
        Task { await fetch(loc.coordinate.latitude, loc.coordinate.longitude) }
    }

    static func forecastURL(_ latitude: Double, _ longitude: Double) -> URL? {
        var u = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        u.queryItems = [.init(name: "latitude", value: String(format: "%.3f", latitude)),
                        .init(name: "longitude", value: String(format: "%.3f", longitude)),
                        .init(name: "current", value: "temperature_2m,weather_code")]
        return u.url
    }

    private func fetch(_ latitude: Double, _ longitude: Double) async {
        guard let url = Self.forecastURL(latitude, longitude) else { return }
        let answer = try? await URLSession.shared.data(from: url)
        await MainActor.run {
            guard let t = target, t.latitude == latitude, t.longitude == longitude else { return }   // the spot changed meanwhile
            guard let answer, (answer.1 as? HTTPURLResponse)?.statusCode == 200, let now = Self.parse(answer.0) else { offline = true; return }
            temperature = now.0; code = now.1; offline = false
        }
    }

    // MARK: place search (Open-Meteo geocoding, free and keyless)

    static func searchURL(_ name: String) -> URL? {
        var u = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        u.queryItems = [.init(name: "name", value: name), .init(name: "count", value: "6"),
                        .init(name: "language", value: "en"), .init(name: "format", value: "json")]
        return u.url
    }

    /// `{"results":[{"name":..,"admin1":..,"country":..,"latitude":..,"longitude":..}]}`; no "results" means nothing found.
    static func parsePlaces(_ data: Data) -> [Place]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (obj["results"] as? [[String: Any]] ?? []).compactMap { r in
            guard let name = r["name"] as? String, let la = (r["latitude"] as? NSNumber)?.doubleValue,
                  let lo = (r["longitude"] as? NSNumber)?.doubleValue else { return nil }
            return Place(name: name, region: r["admin1"] as? String ?? "", country: r["country"] as? String ?? "", latitude: la, longitude: lo)
        }
    }

    /// Places matching `name`; nil when the search could not be reached.
    static func search(_ name: String) async -> [Place]? {
        guard let url = searchURL(name), let answer = try? await URLSession.shared.data(from: url),
              (answer.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parsePlaces(answer.0)
    }

    /// Open-Meteo's answer: `{"current": {"temperature_2m": 24.1, "weather_code": 2}}`, Celsius by default.
    static func parse(_ data: Data) -> (Measurement<UnitTemperature>, Int)? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cur = obj["current"] as? [String: Any], let t = (cur["temperature_2m"] as? NSNumber)?.doubleValue,
              let code = (cur["weather_code"] as? NSNumber)?.intValue else { return nil }
        return (Measurement(value: t, unit: .celsius), code)
    }

    /// WMO weather codes as Open-Meteo documents them.
    static func describe(_ code: Int) -> String {
        switch code {
        case 0: "Clear"
        case 1: "Mostly clear"
        case 2: "Partly cloudy"
        case 3: "Overcast"
        case 45, 48: "Fog"
        case 51...57: "Drizzle"
        case 61...67, 80...82: "Rain"
        case 71...77, 85, 86: "Snow"
        case 95...99: "Thunderstorm"
        default: "Weather"
        }
    }
}
