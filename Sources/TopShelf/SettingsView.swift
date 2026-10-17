import AppKit
import SwiftUI

/// Top Shelf Settings, laid out as the approved settings mockup (settings-mockup.html), in the Mac's own grouped style.
struct SettingsView: View {
    @Bindable var model: ShelfModel

    var body: some View {
        Form {
            Section("Opening") {
                Picker("Open the shelf by", selection: $model.openMode) {
                    ForEach(ShelfModel.OpenMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                delay("Hover open delay", "Pointer waits on the notch before it opens", $model.hoverDelay, upTo: 1.5)
                    .disabled(model.openMode == .click)   // hover never opens it in Click mode
                delay("Hover close delay", "Time after the pointer leaves before it closes", $model.hoverCloseDelay, upTo: 3)
            }
            Section("Menu bar") {
                Toggle("Show menu bar icon", isOn: $model.showMenuBarIcon)
                    .toggleStyle(.switch)
                LabeledContent("Quit Top Shelf") {   // the only way to quit when the menu bar icon is hidden
                    Button("Quit") { NSApp.terminate(nil) }
                }
            }
            WeatherSettings(weather: model.weather)
            SoundSettings(model: model)
            Section("Keeping things") {
                Picker("Keep dropped files for", selection: $model.keepFilesFor) {
                    Text("1 hour").tag(3600.0); Text("1 day").tag(86400.0); Text("1 week").tag(604800.0); Text("Until removed").tag(0.0)
                }
                Picker("Keep clipboard items for", selection: $model.keepClipsFor) {
                    Text("1 day").tag(86400.0); Text("1 week").tag(604800.0); Text("1 month").tag(2592000.0)
                }
            }
            Section("Keyboard shortcuts") {
                LabeledContent("Open the shelf") { keycap("⌥⌘T") }
                LabeledContent("Open the clipboard") { keycap("⌥⌘V") }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func delay(_ title: String, _ hint: String, _ value: Binding<Double>, upTo max: Double) -> some View {
        LabeledContent {
            HStack(spacing: 10) {
                Slider(value: value, in: 0...max, step: 0.1).frame(width: 200).labelsHidden()
                Text(String(format: "%.1f s", value.wrappedValue)).monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
            }
        } label: {
            Text(title)
            Text(hint)
        }
    }

    private func keycap(_ keys: String) -> some View {
        Text(keys).font(.system(size: 12, design: .monospaced))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Color.secondary.opacity(0.2), in: RoundedRectangle(cornerRadius: 5))
    }
}

/// One Settings window, opened from the gear button and the menu bar icon.
enum SettingsWindow {
    private static var window: NSWindow?

    static func show(_ model: ShelfModel) {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
            w.title = "Top Shelf Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        model.close()
        NSApp.activate(ignoringOtherApps: true)   // Top Shelf has no Dock icon; bring the window forward
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Weather for the current location or a picked place, as in the approved settings mockup.
struct WeatherSettings: View {
    @Bindable var weather: WeatherService
    @State private var query = ""
    @State private var results: [WeatherService.Place]?
    @State private var searchFailed = false

    var body: some View {
        Section("Weather") {
            Picker("Weather for", selection: $weather.source) {
                Text("Use current location").tag(WeatherService.Source.current)
                Text("Choose a place").tag(WeatherService.Source.place)
            }
            .pickerStyle(.segmented)
            if weather.source == .current && weather.locationOff {
                Text("Location access is off for Top Shelf, so it can't tell where you are. Choose a place instead, or allow Top Shelf in System Settings, Privacy & Security, Location Services.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if weather.source == .place {
                LabeledContent("Place") {
                    Text(weather.chosen?.label ?? "None chosen yet").foregroundStyle(weather.chosen == nil ? .secondary : .primary)
                }
                TextField("Search for a city", text: $query, prompt: Text("Search for a city")).textFieldStyle(.roundedBorder).labelsHidden()
                if searchFailed {
                    Text("Can't search right now. Check the internet connection.").font(.callout).foregroundStyle(.secondary)
                } else if let results, results.isEmpty {
                    Text("No places found").font(.callout).foregroundStyle(.secondary)
                } else if let results {
                    ForEach(results, id: \.self) { p in
                        Button { weather.chosen = p; query = "" } label: {
                            HStack(spacing: 6) {
                                Text(p.name)
                                Text([p.region, p.country].filter { !$0.isEmpty }.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .task(id: query) {   // searches shortly after typing stops
            let q = query.trimmingCharacters(in: .whitespaces)
            guard q.count >= 2 else { results = nil; searchFailed = false; return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            let found = await WeatherService.search(q)
            guard !Task.isCancelled else { return }
            results = found; searchFailed = found == nil
        }
    }
}

/// Sounds for John's main chats, as in the approved settings mockup.
struct SoundSettings: View {
    @Bindable var model: ShelfModel
    @State private var choices = AlertSounds.all()

    var body: some View {
        Section {
            Toggle("When a chat has a question", isOn: $model.questionSoundOn).toggleStyle(.switch)
            row($model.questionSound, on: model.questionSoundOn, label: "When a chat has a question")
            Toggle("When a chat finishes", isOn: $model.finishedSoundOn).toggleStyle(.switch)
            row($model.finishedSound, on: model.finishedSoundOn, label: "When a chat finishes")
        } header: {
            Text("Sounds")
        } footer: {
            Text("Only your main chats make sounds. Their helpers (subagents) stay quiet.").font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { choices = AlertSounds.all() }   // picks up sounds added to ~/Library/Sounds since
    }

    private func row(_ file: Binding<String>, on: Bool, label: String) -> some View {
        LabeledContent("Sound") {
            HStack(spacing: 8) {
                Picker("Sound", selection: file) {
                    ForEach(choices, id: \.file) { Text($0.name).tag($0.file) }
                }
                .labelsHidden().fixedSize()
                .accessibilityLabel("Sound: \(label)")
                Button { AlertSounds.play(file.wrappedValue) } label: { Image(systemName: "play.fill") }
                    .buttonStyle(.borderless).help("Play").accessibilityLabel("Play")
            }
        }
        .disabled(!on)
    }
}
