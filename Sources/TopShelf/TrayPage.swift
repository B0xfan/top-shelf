import SwiftUI

/// Tray page: the music card on the left, the calendar card on the right, 106 pt tall with 20 pt corners
/// (measured from John's screenshot of Bartender's Top Shelf).
struct TrayPage: View {
    let model: ShelfModel

    var body: some View {
        HStack(spacing: 15) {
            MusicCard(music: model.music)
                .background(Look.cardGradient, in: RoundedRectangle(cornerRadius: 20))
            CalendarCard(calendar: model.calendar, weather: model.weather)
                .clipShape(RoundedRectangle(cornerRadius: 20))
        }
        .frame(height: 106)
    }
}

struct Artwork: View {
    let image: NSImage?
    let size: CGFloat
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
            else { LinearGradient(colors: [Color(white: 0.35), Color(white: 0.15)], startPoint: .topLeading, endPoint: .bottomTrailing) }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size > 30 ? 10 : 3))
        .accessibilityHidden(true)
    }
}

/// A record: dark disc with faint grooves and the album art as its round label. Drawn here, not taken from anywhere.
struct Vinyl: View {
    let image: NSImage?
    let size: CGFloat
    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [Color(white: 0.16), Color(white: 0.04)], center: .center, startRadius: 0, endRadius: size / 2))
            ForEach(0..<5) { k in
                Circle().stroke(Color.white.opacity(0.06), lineWidth: 0.6).padding(size * 0.07 + CGFloat(k) * size * 0.045)
            }
            Group {
                if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
                else { Color(white: 0.3) }
            }
            .frame(width: size * 0.45, height: size * 0.45)
            .clipShape(Circle())
            Circle().fill(Color.black).frame(width: 3, height: 3)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct MusicCard: View {
    let music: NowPlaying
    var body: some View {
        HStack(spacing: 6) {
            Vinyl(image: music.artwork, size: 94).padding(.leading, 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(music.hasTrack ? music.title ?? "" : music.available ? "Nothing playing" : "Music controls unavailable")
                    .font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(music.artist ?? (music.available ? "" : "This version of macOS blocks them"))
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Color(white: 211 / 255)).lineLimit(1)
                Text(music.album ?? "").font(.system(size: 12.5)).foregroundStyle(Color(white: 144 / 255)).lineLimit(1)
                HStack(spacing: 34) {
                    control("backward.fill", "Previous track") { music.send(.previous) }
                    control(music.isPlaying ? "pause.fill" : "play.fill", music.isPlaying ? "Pause" : "Play") { music.send(.toggle) }
                    control("forward.fill", "Next track") { music.send(.next) }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
                .disabled(!music.available || !music.hasTrack)   // a play with no player loaded makes macOS open Apple Music
            }
            .padding(.trailing, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func control(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 17)).contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .foregroundStyle(Color(white: 0.9))
            .accessibilityLabel(label)
            .help(label)
    }
}

/// Calendar card: near-black with a deep blue glow, the next event (or "No events today") in the middle,
/// the weather underneath.
struct CalendarCard: View {
    let calendar: CalendarService
    let weather: WeatherService

    var body: some View {
        ZStack {
            Color.black
            RadialGradient(colors: [Color(red: 8 / 255, green: 25 / 255, blue: 51 / 255), .clear], center: .topLeading, startRadius: 0, endRadius: 230)
            RadialGradient(colors: [Color(red: 5 / 255, green: 15 / 255, blue: 32 / 255), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 170)
            VStack(spacing: 3) {
                if let e = calendar.next {
                    Text(e.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(CalendarService.when(e, now: calendar.now)).font(.system(size: 12)).foregroundStyle(Look.dim)
                } else {
                    Text(calendar.access == false ? "Calendar access is off" : "No events today").font(.system(size: 14, weight: .semibold))
                }
                if let t = weather.temperature, let code = weather.code {
                    Text([t.formatted(.measurement(width: .narrow, usage: .weather, numberFormatStyle: .number.precision(.fractionLength(0)))),
                          WeatherService.describe(code), weather.place].compactMap { $0 }.joined(separator: "  "))
                        .font(.system(size: 11)).foregroundStyle(Look.dim).lineLimit(1).padding(.top, 4)
                }
            }
            .padding(.horizontal, 14)
        }
    }
}
