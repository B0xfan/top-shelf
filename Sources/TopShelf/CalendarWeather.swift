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

/// Current weather where the Mac is, from Open-Meteo (free, no account), refreshed every 30 minutes.
@Observable
final class WeatherService: NSObject, CLLocationManagerDelegate {
    var temperature: Measurement<UnitTemperature>?
    var code: Int?
    var place: String?
    var locationOff = false
    private let manager = CLLocationManager()
    private var timer: Timer?

    init(live: Bool) {
        super.init()
        guard live else { return }
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        timer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in self?.manager.requestLocation() }
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        switch m.authorizationStatus {
        case .notDetermined: m.requestWhenInUseAuthorization()
        case .authorized, .authorizedAlways: locationOff = false; m.requestLocation()
        default: locationOff = true
        }
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {}

    func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        CLGeocoder().reverseGeocodeLocation(loc) { [weak self] marks, _ in
            DispatchQueue.main.async { self?.place = marks?.first?.locality ?? marks?.first?.name }
        }
        Task { await fetch(loc.coordinate) }
    }

    private func fetch(_ c: CLLocationCoordinate2D) async {
        var u = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        u.queryItems = [.init(name: "latitude", value: String(format: "%.3f", c.latitude)),
                        .init(name: "longitude", value: String(format: "%.3f", c.longitude)),
                        .init(name: "current", value: "temperature_2m,weather_code")]
        guard let url = u.url, let answer = try? await URLSession.shared.data(from: url),
              (answer.1 as? HTTPURLResponse)?.statusCode == 200, let now = Self.parse(answer.0) else { return }
        await MainActor.run { temperature = now.0; code = now.1 }
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
