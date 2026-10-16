import AppKit
import Carbon.HIToolbox

@main
enum Main {
    static func main() {
        #if TESTHARNESS
        if SelfTest.run(CommandLine.arguments) { return }
        #endif
        // Same as the Agents page's Connect button, for setting it up from Terminal.
        if CommandLine.arguments.contains("--connect-claude") {
            do { let b = try Agents.installHooks(settings: Agents.claudeSettings); print("connected; backup: \(b?.lastPathComponent ?? "none needed")"); exit(0) }
            catch { print("not changed: \(error)"); exit(1) }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--music-check") { musicCheck(CommandLine.arguments.dropFirst(i + 1)) }
        let app = NSApplication.shared
        let delegate = AppDelegate()   // app.run() never returns, so this stays alive
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

/// Windowless check of the built app's music link: prints what plays, sends any commands given
/// (play, pause, next, previous), prints again, then quits. Opens no window.
func musicCheck(_ commands: ArraySlice<String>) -> Never {
    let music = NowPlaying(resources: Bundle.main.resourceURL)
    func report(_ label: String) {
        let until = Date().addingTimeInterval(2.5)
        _ = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { _ in }   // without a timer the run loop returns at once
        RunLoop.main.run(until: until)
        print("\(label): available=\(music.available) player=\(music.playerID ?? "-") title=\(music.title ?? "-") playing=\(music.isPlaying) artwork=\(music.artwork != nil)")
    }
    report("start")
    let names: [String: NowPlaying.Command] = ["play": .play, "pause": .pause, "next": .next, "previous": .previous]
    for c in commands { if let cmd = names[c], music.hasTrack { music.send(cmd); report(c) } }
    exit(music.available ? 0 : 1)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = ShelfModel(live: true)
    private var controller: ShelfController!
    private var statusItem: NSStatusItem!
    private var hotKeys: [HotKey] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = ShelfController(model: model)
        hotKeys = [
            HotKey(keyCode: kVK_ANSI_T, modifiers: cmdKey | optionKey) { [weak self] in self?.model.toggle(.tray) },
            HotKey(keyCode: kVK_ANSI_V, modifiers: cmdKey | optionKey) { [weak self] in self?.model.toggle(.clipboard) },
        ]
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "menubar.rectangle", accessibilityDescription: "Top Shelf")
        statusItem.menu = makeMenu()
        model.openSettings = { [weak self] in self.map { SettingsWindow.show($0.model) } }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Open Top Shelf", "t", [.command, .option]) { [weak self] in self?.model.open(.tray) })
        menu.addItem(item("Open Clipboard", "v", [.command, .option]) { [weak self] in self?.model.open(.clipboard) })
        menu.addItem(.separator())
        menu.addItem(item("Settings…", ",", [.command]) { [weak self] in self.map { SettingsWindow.show($0.model) } })
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Top Shelf", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    private func item(_ title: String, _ key: String = "", _ mods: NSEvent.ModifierFlags = [], action: @escaping () -> Void) -> NSMenuItem {
        let i = MenuAction(title: title, key: key, action: action)
        i.keyEquivalentModifierMask = mods
        return i
    }
}


/// A menu item that runs a closure, so the menu needs no selector plumbing.
final class MenuAction: NSMenuItem {
    private let run: () -> Void
    init(title: String, key: String, action: @escaping () -> Void) {
        run = action
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { run() }
}

/// System-wide shortcut through Carbon, which needs no Accessibility permission.
final class HotKey {
    private static var actions: [UInt32: () -> Void] = [:]
    private var ref: EventHotKeyRef?

    init(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        if Self.actions.isEmpty { Self.installHandler() }
        let id = UInt32(Self.actions.count + 1)
        Self.actions[id] = action
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), EventHotKeyID(signature: 0x5453_4846, id: id),
                            GetApplicationEventTarget(), 0, &ref)
    }

    private static func installHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            HotKey.actions[id.id]?()
            return noErr
        }, 1, &spec, nil, nil)
    }
}
