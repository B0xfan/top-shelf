#if TESTHARNESS
import AppKit
import SwiftUI

/// Debug builds only. `--selftest` checks the logic; `--shots <dir>` draws every shelf state into PNGs
/// in a window that is never shown. Both run on the GitHub build machine, never on John's Mac.
enum SelfTest {
    private static var failures = 0
    static func check(_ name: String, _ ok: Bool) {
        print((ok ? "PASS " : "FAIL ") + name)
        if !ok { failures += 1 }
    }

    static func run(_ args: [String]) -> Bool {
        if args.contains("--selftest") {
            UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier ?? "TopShelf")
            for t in tests { t() }
            print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
        if let i = args.firstIndex(of: "--shots"), i + 1 < args.count {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.accessory)
            Shots.draw(into: URL(fileURLWithPath: args[i + 1]))
            exit(0)
        }
        return false
    }

    static var tests: [() -> Void] = [shelfTests, musicTests, calendarWeatherTests]

    static func shelfTests() {
        let g = NotchGeometry(screenWidth: 1512, leftWidth: 662, rightWidth: 662, topInset: 32, menuBarHeight: 37)
        check("notch: width is the gap between the two side areas", g.hasNotch && g.notchWidth == 188 && g.notchHeight == 32)
        let flat = NotchGeometry(screenWidth: 2560, leftWidth: nil, rightWidth: nil, topInset: 0, menuBarHeight: 25)
        check("no notch: a 200 pt capsule as tall as the menu bar", !flat.hasNotch && flat.notchWidth == 200 && flat.notchHeight == 25)
        let odd = NotchGeometry(screenWidth: 1000, leftWidth: 600, rightWidth: 600, topInset: 32, menuBarHeight: 24)
        check("nonsense side areas fall back to the capsule", !odd.hasNotch)

        let m = ShelfModel()
        m.open(.clipboard)
        check("open goes to the asked page", m.isOpen && m.page == .clipboard && !m.openedByHover)
        m.toggle(.clipboard)
        check("toggling the open page closes", !m.isOpen)
        m.open(.tray, byHover: true); m.toggle(.files)
        check("toggling another page switches to it", m.isOpen && m.page == .files && !m.openedByHover)
        check("open size matches the mockup (680 x 236 with a 32 pt notch)", m.openSize == CGSize(width: 680, height: 236))
        m.hoverDelay = 0.8
        check("hover delay is remembered", UserDefaults.standard.double(forKey: "hoverDelay") == 0.8)
    }
}

extension SelfTest {
    static func musicTests() {
        let m = NowPlaying(resources: nil)
        let png = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { r in NSColor.red.setFill(); r.fill(); return true }
        let art = NSBitmapImageRep(data: png.tiffRepresentation!)!.representation(using: .png, properties: [:])!.base64EncodedString()
        m.apply(["title": "Song", "artist": "Artist", "playing": true, "bundle": "com.spotify.client", "art": art])
        check("music: a helper line fills the card", m.hasTrack && m.isPlaying && m.artist == "Artist" && m.playerID == "com.spotify.client" && m.artwork != nil)
        m.apply(["title": "Song", "playing": false])
        check("music: a pause and a missing picture clear both", !m.isPlaying && m.artwork == nil && m.artist == nil)
        m.apply(["error": "missing MRMediaRemoteSendCommand"])
        check("music: a helper error marks controls unavailable", !m.available)
        check("music: without the helper files the service says unavailable",
              !NowPlaying(resources: URL(fileURLWithPath: "/nonexistent")).available)
    }

    static func calendarWeatherTests() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func ev(_ t: String, _ s: Double, _ e: Double) -> CalendarService.Event {
            .init(title: t, start: now.addingTimeInterval(s * 60), end: now.addingTimeInterval(e * 60))
        }
        let list = [ev("Later", 90, 120), ev("Done", -60, -1), ev("Soon", 11, 41)]
        check("calendar: picks the next event, skipping finished ones", CalendarService.pick(list, now: now)?.title == "Soon")
        check("calendar: an event under way wins", CalendarService.pick(list + [ev("Now", -5, 25)], now: now)?.title == "Now")
        check("calendar: nothing left today", CalendarService.pick([ev("Done", -60, -1)], now: now) == nil)
        check("calendar: in 11 minutes", CalendarService.when(ev("Soon", 11, 41), now: now) == "in 11 minutes")
        check("calendar: in 1 minute (rounded up, singular)", CalendarService.when(ev("x", 0.5, 30), now: now) == "in 1 minute")
        check("calendar: an hour or more away shows the time", CalendarService.when(ev("x", 90, 120), now: now).hasPrefix("at "))
        check("calendar: under way says now", CalendarService.when(ev("x", -5, 25), now: now).hasPrefix("now, until"))
        let c = CalendarService(live: false)
        c.now = now; c.next = ev("Soon", 11, 41)
        check("calendar: an event within the hour shows beside the notch", c.soon != nil)
        c.next = ev("Later", 90, 120)
        check("calendar: a later event does not", c.soon == nil)

        let w = WeatherService.parse(Data(#"{"current":{"time":"2026-10-16T15:00","temperature_2m":24.1,"weather_code":2}}"#.utf8))
        check("weather: reads Open-Meteo's answer", w?.0.value == 24.1 && w?.1 == 2)
        check("weather: a broken answer is ignored", WeatherService.parse(Data("{}".utf8)) == nil)
        check("weather: code 2 is partly cloudy, unknown codes say Weather", WeatherService.describe(2) == "Partly cloudy" && WeatherService.describe(1234) == "Weather")
    }
}

enum Shots {
    static func draw(into dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = ShelfModel()
        Sample.fill(model)
        var states: [(String, Bool, Page)] = [("collapsed", false, .tray)]
        for p in Page.allCases { states.append((p.rawValue.lowercased(), true, p)) }
        for (name, open, page) in states {
            model.page = page
            model.isOpen = open
            shot(ShelfView(model: model).transaction { $0.animation = nil }, size: CGSize(width: 760, height: 260),
                 to: dir.appendingPathComponent("\(name).png"))
        }
    }

    /// Draws a real window off screen (unlike ImageRenderer, text fields and AppKit views show up).
    static func shot<V: View>(_ view: V, size: CGSize, to url: URL) {
        let content = view.background(LinearGradient(colors: [Color(red: 0.17, green: 0.23, blue: 0.33), Color(red: 0.42, green: 0.36, blue: 0.54)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        let host = NSHostingView(rootView: content)
        let w = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: size.width, height: size.height),
                         styleMask: .borderless, backing: .buffered, defer: false)
        w.contentView = host
        w.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        w.orderOut(nil)
        print("shot \(url.lastPathComponent)")
    }
}

/// Mockup sample data for the pictures only.
enum Sample {
    static func fill(_ model: ShelfModel) {
        model.music.apply(["title": "Sample Song", "artist": "Sample Artist", "playing": true])
        model.calendar.now = Date()
        model.calendar.next = .init(title: "Design sync", start: Date().addingTimeInterval(11 * 60 - 1), end: Date().addingTimeInterval(41 * 60))
        model.weather.temperature = Measurement(value: 24, unit: .celsius)
        model.weather.code = 2
        model.weather.place = "Sample City"
    }
}
#endif
