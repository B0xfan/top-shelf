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
