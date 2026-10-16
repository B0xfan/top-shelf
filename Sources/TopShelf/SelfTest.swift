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

    static var tests: [() -> Void] = [shelfTests]

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
    static func fill(_ model: ShelfModel) {}
}
#endif
