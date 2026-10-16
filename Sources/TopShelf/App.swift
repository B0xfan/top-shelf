import AppKit
import Carbon.HIToolbox

@main
enum Main {
    static func main() {
        #if TESTHARNESS
        if SelfTest.run(CommandLine.arguments) { return }
        #endif
        let app = NSApplication.shared
        let delegate = AppDelegate()   // app.run() never returns, so this stays alive
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = ShelfModel()
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
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Open Top Shelf", "t", [.command, .option]) { [weak self] in self?.model.open(.tray) })
        menu.addItem(item("Open Clipboard", "v", [.command, .option]) { [weak self] in self?.model.open(.clipboard) })
        menu.addItem(.separator())
        let delay = NSMenuItem(title: "Open on Hover", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (title, value) in [("Off", -1.0), ("Right Away", 0.0), ("After a Short Pause", 0.3), ("After a Long Pause", 0.8)] {
            let i = item(title) { [weak self] in self?.model.hoverDelay = value }
            i.representedObject = value
            sub.addItem(i)
        }
        sub.delegate = self
        delay.submenu = sub
        menu.addItem(delay)
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

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {   // tick the current hover choice
        for i in menu.items { i.state = (i.representedObject as? Double) == model.hoverDelay ? .on : .off }
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
