import SwiftUI

/// Tray page: music card on the left, next event and weather on the right (mockup "Tray").
struct TrayPage: View {
    let model: ShelfModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            MusicCard(music: model.music).card()
            VStack(alignment: .leading, spacing: 8) {
                EventRow(calendar: model.calendar)
                WeatherRow(weather: model.weather)
            }
            .card()
        }
    }
}

extension View {
    func card() -> some View {
        padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Look.card, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct Artwork: View {
    let image: NSImage?
    let size: CGFloat
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
            else { LinearGradient(colors: [Color(red: 1, green: 0.22, blue: 0.37), Color(red: 0.37, green: 0.36, blue: 0.9)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing) }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size > 30 ? 10 : 5))
        .accessibilityHidden(true)
    }
}

struct MusicCard: View {
    let music: NowPlaying
    var body: some View {
        HStack(spacing: 10) {
            Artwork(image: music.artwork, size: 56)
            VStack(alignment: .leading, spacing: 0) {
                Text(music.hasTrack ? music.title ?? "" : music.available ? "Nothing playing" : "Music controls unavailable")
                    .font(Look.title).lineLimit(1)
                Text(music.artist ?? (music.available ? "" : "This version of macOS blocks them"))
                    .font(Look.small).foregroundStyle(Look.dim).lineLimit(1)
                HStack(spacing: 14) {
                    control("backward.end.fill", "Previous track") { music.send(.previous) }
                    control(music.isPlaying ? "pause.fill" : "play.fill", music.isPlaying ? "Pause" : "Play") { music.send(.toggle) }
                    control("forward.end.fill", "Next track") { music.send(.next) }
                }
                .padding(.top, 6)
                .disabled(!music.available || !music.hasTrack)   // a play with no player loaded makes macOS open Apple Music
            }
        }
    }

    private func control(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 16)).contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
            .help(label)
    }
}

struct EventRow: View {
    let calendar: CalendarService
    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(calendar.next?.color.map(Color.init(nsColor:)) ?? Look.blue).frame(width: 3, height: 28)
            VStack(alignment: .leading, spacing: 0) {
                if let e = calendar.next {
                    Text(e.title).font(Look.title).lineLimit(1)
                    Text(CalendarService.when(e, now: calendar.now)).font(Look.small).foregroundStyle(Look.dim)
                } else {
                    Text(calendar.access == false ? "Calendar access is off" : "No more events today").font(Look.title).lineLimit(1)
                    if calendar.access == false {
                        Text("Allow it in System Settings, Privacy").font(Look.small).foregroundStyle(Look.dim)
                    }
                }
            }
        }
    }
}

struct WeatherRow: View {
    let weather: WeatherService
    var body: some View {
        HStack(spacing: 10) {
            if let t = weather.temperature, let code = weather.code {
                Text(t.formatted(.measurement(width: .narrow, usage: .weather, numberFormatStyle: .number.precision(.fractionLength(0)))))
                    .font(.system(size: 24, weight: .light))
                VStack(alignment: .leading, spacing: 0) {
                    Text(WeatherService.describe(code)).font(Look.title).lineLimit(1)
                    Text(weather.place ?? "").font(Look.small).foregroundStyle(Look.dim).lineLimit(1)
                }
            } else {
                Text(weather.locationOff ? "Weather needs Location access" : "Weather loading").font(Look.small).foregroundStyle(Look.dim)
            }
        }
    }
}
