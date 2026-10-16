import AppKit
import Observation
import SwiftUI

enum Page: String, CaseIterable { case tray = "Tray", files = "Files", clipboard = "Clipboard", agents = "Agents" }

@Observable
final class ShelfModel {
    var isOpen = false
    var page: Page = .tray
    var openedByHover = false
    /// Seconds before a hover over the notch opens the shelf; negative = hover does not open it.
    // Settings (Settings window). Saved at once and read by the code that uses them, so changes apply without a restart.
    enum OpenMode: String, CaseIterable { case hover = "Hover", click = "Click", both = "Both" }
    var openMode: OpenMode = OpenMode(rawValue: UserDefaults.standard.string(forKey: "openMode") ?? "") ?? .both {
        didSet { UserDefaults.standard.set(openMode.rawValue, forKey: "openMode") }
    }
    /// Seconds the pointer waits on the notch before the shelf opens (0 to 1.5).
    var hoverDelay: Double = max(0, UserDefaults.standard.object(forKey: "hoverDelay") as? Double ?? 0.3) {
        didSet { UserDefaults.standard.set(hoverDelay, forKey: "hoverDelay") }
    }
    /// Seconds after the pointer leaves a hover-opened shelf before it closes (0 to 3).
    var hoverCloseDelay: Double = UserDefaults.standard.object(forKey: "hoverCloseDelay") as? Double ?? 0.5 {
        didSet { UserDefaults.standard.set(hoverCloseDelay, forKey: "hoverCloseDelay") }
    }
    /// How long dropped files stay; 0 = until removed.
    var keepFilesFor: TimeInterval = UserDefaults.standard.object(forKey: "keepFilesFor") as? Double ?? 86400 {
        didSet { UserDefaults.standard.set(keepFilesFor, forKey: "keepFilesFor"); files.keepFor = keepFilesFor > 0 ? keepFilesFor : nil; files.prune() }
    }
    /// How long unpinned clipboard items stay.
    var keepClipsFor: TimeInterval = UserDefaults.standard.object(forKey: "keepClipsFor") as? Double ?? 7 * 86400 {
        didSet { UserDefaults.standard.set(keepClipsFor, forKey: "keepClipsFor"); clipboard.keepFor = keepClipsFor; clipboard.prune() }
    }
    var geometry = NotchGeometry(screenWidth: 1512, leftWidth: 662, rightWidth: 662, topInset: 32, menuBarHeight: 32)
    let music: NowPlaying
    let calendar: CalendarService
    let weather: WeatherService
    let files: FilesTray
    let clipboard: ClipboardHistory
    let agents: Agents

    /// `live` starts the system services; the self-test and pictures use a quiet model.
    init(live: Bool = false) {
        music = NowPlaying(resources: live ? Bundle.main.resourceURL : nil)
        calendar = CalendarService(live: live)
        weather = WeatherService(live: live)
        let dir = live ? supportFolder() : nil
        files = FilesTray(store: dir?.appendingPathComponent("files.json"))
        clipboard = ClipboardHistory(dir: dir, live: live)
        agents = Agents(dir: dir, live: live)
        files.keepFor = keepFilesFor > 0 ? keepFilesFor : nil
        clipboard.keepFor = keepClipsFor
        files.prune(); clipboard.prune()
        // the old menu stored "hover off" as a negative delay
        if (UserDefaults.standard.object(forKey: "hoverDelay") as? Double ?? 0) < 0, UserDefaults.standard.string(forKey: "openMode") == nil {
            openMode = .click
        }
    }

    func open(_ p: Page, byHover: Bool = false) {
        page = p; openedByHover = byHover; isOpen = true
        files.prune()   // expiry is checked whenever the shelf opens, so nothing old is ever shown
    }
    func close() { isOpen = false }
    func toggle(_ p: Page) { if isOpen && page == p { close() } else { open(p) } }

    /// Something shows beside the closed notch: Claude Code activity or music.
    var showsMusic: Bool { music.isPlaying && music.hasTrack }
    var hasBanners: Bool { showsMusic || agents.activeState != nil }
    /// The gear button opens the Settings window (set by the app).
    @ObservationIgnored var openSettings: (() -> Void)?

    /// Sizes measured from John's screenshots of Bartender's Top Shelf (Retina pictures, 2 pixels per point):
    /// closed with activity it is 254 pt wide around a 179 pt notch (37.5 pt a side), the top flaring out 3 pt;
    /// open it is 611 x 174 pt.
    static let side: CGFloat = 37.5
    static let flare: CGFloat = 4.5
    var collapsedSize: CGSize {
        CGSize(width: geometry.notchWidth + (hasBanners ? 2 * (Self.side + Self.flare) : 0), height: geometry.notchHeight)
    }
    var openSize: CGSize { CGSize(width: 611, height: 174) }
}

/// Where the notch is. Screens without a notch get a capsule of the same job at the top center.
struct NotchGeometry: Equatable {
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    var hasNotch: Bool

    init(screenWidth: CGFloat, leftWidth: CGFloat?, rightWidth: CGFloat?, topInset: CGFloat, menuBarHeight: CGFloat) {
        if topInset > 0, let l = leftWidth, let r = rightWidth, screenWidth - l - r > 0 {
            notchWidth = screenWidth - l - r; notchHeight = topInset; hasNotch = true
        } else {
            notchWidth = 200; notchHeight = max(menuBarHeight, 24); hasNotch = false
        }
    }

    init(_ screen: NSScreen) {
        self.init(screenWidth: screen.frame.width, leftWidth: screen.auxiliaryTopLeftArea?.width,
                  rightWidth: screen.auxiliaryTopRightArea?.width, topInset: screen.safeAreaInsets.top,
                  menuBarHeight: screen.frame.maxY - screen.visibleFrame.maxY)
    }
}

final class ShelfPanel: NSPanel {
    override var canBecomeKey: Bool { true }   // the clipboard search field needs typing
}

/// Accepts the first click even though Top Shelf is never the active app.
final class FirstClickHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Reports the mouse while it is over the panel, also when another app is active.
final class HoverView: NSView {
    var onMove: (NSPoint) -> Void = { _ in }
    var onExit: () -> Void = {}
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
                                       owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onMove(NSEvent.mouseLocation) }
    override func mouseMoved(with event: NSEvent) { onMove(NSEvent.mouseLocation) }
    override func mouseExited(with event: NSEvent) { onExit() }
}

final class ShelfController {
    private let model: ShelfModel
    private let panel: ShelfPanel
    private var screen: NSScreen?
    private var monitors: [Any] = []
    private lazy var hover = HoverLogic(model: model)

    init(model: ShelfModel) {
        self.model = model
        panel = ShelfPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)   // above the menu bar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isMovable = false
        panel.isReleasedWhenClosed = false

        let hover = HoverView()
        let host = FirstClickHostingView(rootView: ShelfView(model: model))
        host.autoresizingMask = [.width, .height]
        hover.addSubview(host)
        hover.onMove = { [weak self] p in self?.mouseMoved(p) }
        hover.onExit = { [weak self] in self?.mouseLeft() }
        panel.contentView = hover

        let nc = NotificationCenter.default, wc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.place() }
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            wc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.updateFullscreen()
                // the fullscreen animation may still be running; look again once it has settled
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self?.updateFullscreen() }
            }
        }
        // A click in any other app closes an open shelf (global monitors only see clicks outside Top Shelf).
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            if self?.model.isOpen == true { self?.model.close() }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            guard e.keyCode == 53, self?.model.isOpen == true else { return e }   // Esc
            self?.model.close(); return nil
        }) { monitors.append(m) }

        observe({ _ = model.isOpen; _ = model.collapsedSize; _ = model.page }) { [weak self] in self?.layout() }
        place()
        updateFullscreen()
    }

    /// The built-in notch screen when there is one, else the main screen.
    private func place() {
        screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
        if let s = screen { model.geometry = NotchGeometry(s) }
        layout()
    }

    private func layout() {
        guard let s = screen else { return }
        func frame(_ size: CGSize) -> NSRect {
            NSRect(x: s.frame.midX - size.width / 2, y: s.frame.maxY - size.height, width: size.width, height: size.height)
        }
        if model.isOpen {
            panel.setFrame(frame(model.openSize), display: true)
            if model.page == .clipboard && !model.openedByHover { panel.makeKey() }   // search takes typing right away
        } else {
            hover.closed()
            if panel.isKeyWindow { panel.orderOut(nil) }   // hand typing back to the app John was in
            // shrink the window after the closing animation, unless it was reopened meanwhile
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self, !self.model.isOpen else { return }
                self.panel.setFrame(frame(self.model.collapsedSize), display: true)
            }
        }
        if !isFullscreen { panel.orderFrontRegardless() }
    }

    private var notchRect: NSRect {
        guard let s = screen else { return .zero }
        let g = model.geometry
        return NSRect(x: s.frame.midX - g.notchWidth / 2, y: s.frame.maxY - g.notchHeight, width: g.notchWidth, height: g.notchHeight)
    }

    private func mouseMoved(_ p: NSPoint) { hover.moved(inNotch: notchRect.insetBy(dx: -1, dy: -1).contains(p)) }
    private func mouseLeft() { hover.left() }

    // MARK: fullscreen

    private var isFullscreen = false

    /// Hides the shelf while an app covers the whole notch screen.
    private func updateFullscreen() {
        guard let s = screen else { return }
        isFullscreen = Self.coversScreen(s.frame.size)
        if isFullscreen { model.close(); panel.orderOut(nil) } else { panel.orderFrontRegardless() }
    }

    /// True when a normal app window on screen is exactly the screen's size (window bounds need no Screen Recording permission).
    static func coversScreen(_ size: CGSize) -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.contains { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let d = w[kCGWindowBounds as String], let b = CGRect(dictionaryRepresentation: d as! CFDictionary) else { return false }
            return b.size == size
        }
    }
}

/// Hover opening and closing, apart from the window so the self-test can drive it.
final class HoverLogic {
    private let model: ShelfModel
    private var openWork: DispatchWorkItem?
    private var closeWork: DispatchWorkItem?
    /// False after a close until the pointer leaves the notch, so closing with the pointer on the notch does not reopen it.
    private var armed = true

    init(model: ShelfModel) { self.model = model }

    func moved(inNotch: Bool) {
        closeWork?.cancel(); closeWork = nil
        guard !model.isOpen, model.openMode != .click else { return }
        if !inNotch { armed = true; openWork?.cancel(); openWork = nil; return }
        guard armed, openWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.openWork = nil
            if let m = self?.model, !m.isOpen, m.openMode != .click { m.open(.tray, byHover: true) }
        }
        openWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + model.hoverDelay, execute: work)
    }

    func left() {
        armed = true
        openWork?.cancel(); openWork = nil
        guard model.isOpen, model.openedByHover else { return }   // a click or shortcut opening stays until dismissed
        let work = DispatchWorkItem { [weak self] in self?.model.close() }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + model.hoverCloseDelay, execute: work)
    }

    func closed() { armed = false }
}

/// Runs `onChange` every time something read in `read` changes.
func observe(_ read: @escaping () -> Void, _ onChange: @escaping () -> Void) {
    withObservationTracking(read) {
        DispatchQueue.main.async { onChange(); observe(read, onChange) }
    }
}
