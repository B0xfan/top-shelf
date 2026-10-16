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

    static var tests: [() -> Void] = [settingsTests, shelfTests, musicTests, calendarWeatherTests, filesTests, clipboardTests, agentsTests, listenerTest]

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
        check("open size matches Bartender's (611 x 174)", m.openSize == CGSize(width: 611, height: 174))
        check("closed with nothing going on: exactly the notch", m.collapsedSize.width == m.geometry.notchWidth)
        func agentPost(_ json: String) { _ = SelfTest.post(m.agents, json) }
        agentPost(#"{"session_id":"w","hook_event_name":"UserPromptSubmit","cwd":"/x/p"}"#)
        check("closed: a working session shows, with no music or meeting", m.hasBanners && m.agents.activeState == .working && m.agents.activeCount == 1)
        check("closed: Bartender's width, 37.5 pt a side plus a 4.5 pt flare (263 pt with a 179 pt notch)",
              m.collapsedSize.width == m.geometry.notchWidth + 84)
        agentPost(#"{"session_id":"n","hook_event_name":"Notification","notification_type":"permission_prompt","cwd":"/x/q"}"#)
        check("closed: waiting for John wins over working, and both count", m.agents.activeState == .attention && m.agents.activeCount == 2)
        agentPost(#"{"session_id":"n","hook_event_name":"Stop","cwd":"/x/q"}"#)
        agentPost(#"{"session_id":"w","hook_event_name":"Stop","cwd":"/x/p"}"#)
        check("closed: idle sessions do not count", m.agents.activeCount == 0 && !m.hasBanners)
        m.music.apply(["title": "Song", "playing": true])
        check("closed: music alone shows, same width", m.hasBanners && m.collapsedSize.width == m.geometry.notchWidth + 84)
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

        let w = WeatherService.parse(Data(#"{"current":{"time":"2026-10-16T15:00","temperature_2m":24.1,"weather_code":2}}"#.utf8))
        check("weather: reads Open-Meteo's answer", w?.0.value == 24.1 && w?.1 == 2)
        check("weather: a broken answer is ignored", WeatherService.parse(Data("{}".utf8)) == nil)
        check("weather: code 2 is partly cloudy, unknown codes say Weather", WeatherService.describe(2) == "Partly cloudy" && WeatherService.describe(1234) == "Weather")
    }
}

extension SelfTest {
    static func settingsTests() {
        let m = ShelfModel()
        check("settings: defaults are Both, 0.3 s, 0.5 s, 1 day, 1 week",
              m.openMode == .both && m.hoverDelay == 0.3 && m.hoverCloseDelay == 0.5 && m.keepFilesFor == 86400 && m.keepClipsFor == 604800)
        m.openMode = .click; m.hoverDelay = 0.2; m.hoverCloseDelay = 0.3; m.keepFilesFor = 3600; m.keepClipsFor = 86400
        let again = ShelfModel()
        check("settings: kept after a relaunch", again.openMode == .click && again.hoverDelay == 0.2 && again.hoverCloseDelay == 0.3
              && again.keepFilesFor == 3600 && again.keepClipsFor == 86400 && again.files.keepFor == 3600 && again.clipboard.keepFor == 86400)

        let hover = HoverLogic(model: m)
        hover.moved(inNotch: true)
        wait(0.6) { m.isOpen }
        check("settings: in Click mode hovering never opens the shelf", !m.isOpen)
        m.openMode = .both
        hover.moved(inNotch: true)
        wait(0.05) { m.isOpen }
        let openedEarly = m.isOpen
        wait(1) { m.isOpen }
        check("settings: the 0.2 s open delay is honoured (closed at 0.05 s, open after)", !openedEarly && m.isOpen && m.openedByHover)
        hover.left()
        wait(0.1) { !m.isOpen }
        let closedEarly = !m.isOpen
        wait(1) { !m.isOpen }
        check("settings: the 0.3 s close delay is honoured (open at 0.1 s, closed after)", !closedEarly && !m.isOpen)
        hover.moved(inNotch: true)
        wait(0.5) { m.isOpen }
        check("settings: closing with the pointer still on the notch does not reopen it", !m.isOpen)

        let d = tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let f = d.appendingPathComponent("kept.txt")
        FileManager.default.createFile(atPath: f.path, contents: Data())
        m.files.add([f], now: Date().addingTimeInterval(-2 * 3600))
        m.keepFilesFor = 3600
        check("settings: 1 hour drops a file dropped 2 hours ago", m.files.items.isEmpty)
        m.files.add([f], now: Date().addingTimeInterval(-400 * 86400))
        m.keepFilesFor = 0
        check("settings: Until removed keeps even a year-old file", m.files.items.count == 1 && m.files.keepFor == nil)
        m.keepFilesFor = 604800
        check("settings: switching to 1 week applies at once", m.files.items.isEmpty)
        let old = ClipboardHistory.Clip(kind: .text, text: "old", key: "old", last: Date().addingTimeInterval(-2 * 86400))
        m.clipboard.add(old)
        m.keepClipsFor = 2592000
        check("settings: 1 month keeps a 2-day-old clip", m.clipboard.clips.contains { $0.key == "old" })
        m.keepClipsFor = 86400
        check("settings: 1 day drops it at once", !m.clipboard.clips.contains { $0.key == "old" })
        UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier ?? "TopShelf")   // leave defaults for later checks
    }

    static func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("topshelf-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Lets main-queue work (listener, text recognition) run, up to `seconds`, until `done` is true.
    static func wait(_ seconds: Double, until done: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while !done() && Date() < end {
            _ = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { _ in }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    static func filesTests() {
        let d = tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let urls = (1...8).map { d.appendingPathComponent("f\($0).txt") }
        for u in urls { FileManager.default.createFile(atPath: u.path, contents: Data("x".utf8)) }
        let store = d.appendingPathComponent("files.json")
        let t = FilesTray(store: store)
        let refused = t.add(Array(urls.prefix(7)))
        check("files: six fit, the seventh is refused", t.items.count == 6 && refused == 1)
        t.add([urls[0]])
        check("files: adding a file again moves it to the front, no duplicate", t.items.count == 6 && t.items.first?.path == urls[0].path)
        t.remove(t.items[0])
        check("files: removed after a drag out", t.items.count == 5 && !t.items.contains { $0.path == urls[0].path })
        check("files: the tray survives a restart", FilesTray(store: store).items.count == 5)
        check("files: saved for John's account only", (try? FileManager.default.attributesOfItem(atPath: store.path)[.posixPermissions] as? Int) == 0o600)
        try? FileManager.default.removeItem(at: urls[1])
        t.prune(now: Date())
        check("files: a deleted file leaves the tray", !t.items.contains { $0.path == urls[1].path })
        t.prune(now: Date().addingTimeInterval(24 * 3600 + 1))
        check("files: everything expires after a day", t.items.isEmpty)
    }

    static func clipboardTests() {
        let d = tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let pb = NSPasteboard(name: NSPasteboard.Name("TopShelfTest-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        let h = ClipboardHistory(dir: d, live: false)
        func copy(_ fill: () -> Void) { pb.clearContents(); fill(); h.poll(pb) }

        copy { pb.setString("hello", forType: .string) }
        copy { pb.setString("hello", forType: .string) }
        check("clipboard: a repeat is merged with a count", h.clips.count == 1 && h.clips[0].count == 2 && h.clips[0].kind == .text)
        copy { pb.declareTypes([.string, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")], owner: nil); pb.setString("secret", forType: .string) }
        check("clipboard: password-manager copies are never kept", !h.clips.contains { $0.text == "secret" })
        copy { pb.declareTypes([.string, NSPasteboard.PasteboardType("org.nspasteboard.TransientType")], owner: nil); pb.setString("temp", forType: .string) }
        check("clipboard: temporary copies are skipped", !h.clips.contains { $0.text == "temp" })
        copy { pb.setData(Data("{\\rtf1 bold}".utf8), forType: .rtf); pb.setString("bold", forType: .string) }
        check("clipboard: rich text keeps its formatting", h.clips[0].kind == .rich && h.clips[0].rtf != nil)
        copy { pb.writeObjects([URL(fileURLWithPath: "/tmp/Report.pdf") as NSURL]) }
        check("clipboard: copied files are kept as references", h.clips[0].kind == .files && h.clips[0].text == "Report.pdf")

        let img = NSImage(size: NSSize(width: 600, height: 120), flipped: false) { r in
            NSColor.white.setFill(); r.fill()
            ("INVOICE NUMBER 4471" as NSString).draw(at: NSPoint(x: 20, y: 40), withAttributes: [.font: NSFont.systemFont(ofSize: 40), .foregroundColor: NSColor.black])
            return true
        }
        copy { pb.writeObjects([img]) }
        check("clipboard: a picture is stored", h.clips[0].kind == .image && h.image(h.clips[0]) != nil)
        wait(20) { h.clips.contains { $0.text.contains("4471") } }
        h.query = "invoice"
        check("clipboard: words inside a picture can be searched", h.visible.first?.kind == .image)
        h.query = ""

        let hello = h.clips.first { $0.text == "hello" }!
        h.togglePin(hello)
        check("clipboard: pinned clips come first", h.visible.first?.text == "hello")
        h.copy(hello, to: pb); h.poll(pb)
        check("clipboard: copying back puts it on the clipboard", pb.string(forType: .string) == "hello")
        check("clipboard: the history survives a restart", ClipboardHistory(dir: d, live: false).clips.count == h.clips.count)
        let picture = h.clips.first { $0.kind == .image }!.imageFile!
        h.prune(now: Date().addingTimeInterval(7 * 86400 + 1))
        check("clipboard: after a week only pinned clips stay", h.clips.map(\.text) == ["hello"])
        check("clipboard: an expired picture is deleted from disk",
              !FileManager.default.fileExists(atPath: d.appendingPathComponent("clipboard-images/" + picture).path))
        for i in 0..<(ClipboardHistory.maxClips + 5) { h.add(.init(kind: .text, text: "n\(i)", key: "k\(i)", last: Date())) }
        check("clipboard: at most 200 unpinned clips plus pinned ones", h.clips.count == ClipboardHistory.maxClips + 1)
    }

    static func post(_ a: Agents, _ json: String, token: String? = nil, path: String = "/event") -> Int {
        let body = Data(json.utf8)
        let raw = "POST \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Top-Shelf-Token: \(token ?? a.token)\r\nContent-Length: \(body.count)\r\n\r\n"
        guard case .complete(let req) = Agents.parse(Data(raw.utf8) + body) else { return -1 }
        return a.handle(req, now: Date())
    }

    static func agentsTests() {
        let d = tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let a = Agents(dir: d, live: false)
        check("agents: a 64-character secret is made on first run", a.token.count == 64)
        check("agents: the secret file is for John's account only",
              (try? FileManager.default.attributesOfItem(atPath: d.appendingPathComponent("agent-header").path)[.posixPermissions] as? Int) == 0o600)
        check("agents: the same secret after a restart", Agents(dir: d, live: false).token == a.token)
        check("agents: a fresh install gets a different secret", Agents(dir: tempDir(), live: false).token != a.token)

        check("agents: a wrong secret is refused", post(a, #"{"session_id":"s1","hook_event_name":"Stop"}"#, token: String(repeating: "0", count: 64)) == 401)
        check("agents: other paths are refused", post(a, "{}", path: "/other") == 404)
        check("agents: junk is refused", post(a, "not json") == 400)
        check("agents: nothing was recorded from refused posts", a.sessions.isEmpty && a.lastSignal == nil)

        _ = post(a, #"{"session_id":"s1","hook_event_name":"UserPromptSubmit","cwd":"/Users/x/sample-project"}"#)
        check("agents: a prompt marks the session working", a.sessions.first?.state == .working && a.sessions.first?.name == "sample-project" && a.lastSignal != nil)
        _ = post(a, #"{"session_id":"s1","hook_event_name":"PostToolUse","tool_name":"Edit","cwd":"/Users/x/sample-project"}"#)
        check("agents: tool use says what it is doing", a.sessions.first?.detail == "Claude Code, editing files")
        _ = post(a, #"{"session_id":"s1","hook_event_name":"Notification","notification_type":"permission_prompt","message":"Claude needs your permission to use Bash","cwd":"/Users/x/sample-project"}"#)
        check("agents: a permission prompt needs attention", a.activeState == .attention && a.sessions.count == 1)
        _ = post(a, #"{"session_id":"s1","hook_event_name":"Notification","notification_type":"auth_success","cwd":"/x"}"#)
        check("agents: unrelated notices change nothing", a.activeState == .attention)
        _ = post(a, #"{"session_id":"s1","hook_event_name":"PostToolUse","tool_name":"Bash","cwd":"/Users/x/sample-project"}"#)
        check("agents: once approved it is working again", a.sessions.first?.state == .working && a.activeState == .working)
        _ = post(a, #"{"session_id":"s1","hook_event_name":"Stop","cwd":"/Users/x/sample-project"}"#)
        check("agents: stop means idle, and no dot", a.sessions.first?.state == .idle && a.activeState == nil)
        _ = post(a, #"{"session_id":"s1","hook_event_name":"SessionEnd"}"#)
        check("agents: an ended session leaves the list", a.sessions.isEmpty)

        // Subagents: their own rows under the session, counted while they work.
        _ = post(a, #"{"session_id":"m","hook_event_name":"UserPromptSubmit","cwd":"/x/main-project"}"#)
        _ = post(a, #"{"session_id":"m","hook_event_name":"SubagentStart","agent_id":"a1","agent_type":"Explore","cwd":"/x/main-project"}"#)
        _ = post(a, #"{"session_id":"m","hook_event_name":"SubagentStart","agent_id":"a2","agent_type":"general-purpose","cwd":"/x/main-project"}"#)
        check("subagents: a session plus two subagents counts 3", a.activeCount == 3)
        check("subagents: listed under their session", a.ordered.map(\.id) == ["m", "a2", "a1"] && a.ordered[1].parent == "m")
        _ = post(a, #"{"session_id":"m","hook_event_name":"PostToolUse","agent_id":"a1","agent_type":"Explore","tool_name":"Grep","cwd":"/x/main-project"}"#)
        check("subagents: their tool use updates their own row", a.sessions.first { $0.id == "a1" }?.detail == "Explore, reading files"
              && a.sessions.first { $0.id == "m" }?.detail == "Claude Code, working")
        _ = post(a, #"{"session_id":"m","hook_event_name":"SubagentStop","agent_id":"a1","agent_type":"Explore"}"#)
        check("subagents: a finished one leaves", a.activeCount == 2 && !a.sessions.contains { $0.id == "a1" })
        _ = post(a, #"{"session_id":"m","hook_event_name":"SubagentStop","agent_id":"","agent_type":""}"#)
        check("subagents: Claude's own helpers stopping change nothing", a.activeCount == 2)
        _ = post(a, #"{"session_id":"z","hook_event_name":"SubagentStart","agent_id":"z1","agent_type":"Plan","cwd":"/x/other"}"#)
        check("subagents: an unseen session appears as working", a.sessions.first { $0.id == "z" }?.state == .working && a.activeCount == 4)
        _ = post(a, #"{"session_id":"m","hook_event_name":"SessionEnd"}"#)
        check("subagents: leave with their session", !a.sessions.contains { $0.id == "a2" || $0.id == "m" })
        _ = post(a, #"{"session_id":"z","hook_event_name":"SessionEnd"}"#)
        _ = post(a, #"{"session_id":"s2","hook_event_name":"Stop","cwd":"/x/y"}"#)
        a.prune(now: Date().addingTimeInterval(3601))
        check("agents: quiet sessions leave after an hour", a.sessions.isEmpty)

        check("agents: a partial request waits for the rest", { if case .incomplete = Agents.parse(Data("POST /event HTTP/1.1\r\nContent-Length: 10\r\n\r\n{}".utf8)) { return true }; return false }())
        check("agents: an oversized request is refused", { if case .bad = Agents.parse(Data("POST /event HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n".utf8)) { return true }; return false }())
        check("agents: secrets compare correctly", Agents.same("abc", "abc") && !Agents.same("abc", "abd") && !Agents.same("abc", "ab"))

        // One-click install, on a copy in a temporary folder (never the real ~/.claude).
        let settings = d.appendingPathComponent("claude/settings.json")
        try? FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = #"{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}"#
        try! Data(original.utf8).write(to: settings)
        let backup = try? Agents.installHooks(settings: settings)
        let after = (try? JSONSerialization.jsonObject(with: Data(contentsOf: settings))) as? [String: Any]
        let hooks = after?["hooks"] as? [String: Any]
        check("install: a backup of the old settings is made first", backup.flatMap { try? String(contentsOf: $0, encoding: .utf8) } == original)
        check("install: John's own settings and hooks are kept", after?["model"] as? String == "opus" && (hooks?["Stop"] as? [Any])?.count == 2)
        check("install: every event is connected, subagents included", Agents.events.allSatisfy { (hooks?[$0] as? [Any])?.isEmpty == false })
        check("install: shows as installed", Agents.hooksInstalled(settings: settings))
        check("install: the secret is not in Claude's settings", !((try? String(contentsOf: settings, encoding: .utf8)) ?? "").contains(a.token))
        Thread.sleep(forTimeInterval: 1.1)   // backups are named by the second
        _ = try? Agents.installHooks(settings: settings)
        let again = (try? JSONSerialization.jsonObject(with: Data(contentsOf: settings))) as? [String: Any]
        check("install: a second click adds nothing twice", ((again?["hooks"] as? [String: Any])?["Stop"] as? [Any])?.count == 2)
        let broken = d.appendingPathComponent("broken/settings.json")
        try? FileManager.default.createDirectory(at: broken.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data("{ not json".utf8).write(to: broken)
        check("install: an unreadable settings file is left untouched",
              (try? Agents.installHooks(settings: broken)) == nil && (try? String(contentsOf: broken, encoding: .utf8)) == "{ not json")
        func perms(_ u: URL?) -> Int? { u.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.posixPermissions] as? Int } }
        let fresh = d.appendingPathComponent("none/settings.json")
        let freshBackup: URL?? = try? Agents.installHooks(settings: fresh)
        check("install: works when Claude Code has no settings file yet (no backup needed)",
              freshBackup != nil && freshBackup! == nil && Agents.hooksInstalled(settings: fresh))
        check("install: a new settings file is private (0600)", perms(fresh) == 0o600)
        for mode in [0o600, 0o640] {
            let s = d.appendingPathComponent("mode\(mode)/settings.json")
            try? FileManager.default.createDirectory(at: s.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: s.path, contents: Data("{}".utf8), attributes: [.posixPermissions: mode])
            let b = try? Agents.installHooks(settings: s)
            check("install: settings and backup keep the original permissions (\(String(mode, radix: 8)))",
                  perms(s) == mode && perms(b ?? nil) == mode)
        }
        let s0 = d.appendingPathComponent("inplace/settings.json")
        try? FileManager.default.createDirectory(at: s0.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: s0.path, contents: Data("{}".utf8), attributes: [.posixPermissions: 0o644])
        func inode(_ u: URL) -> Int? { (try? FileManager.default.attributesOfItem(atPath: u.path)[.systemFileNumber]) as? Int }
        let before = inode(s0)
        _ = try? Agents.installHooks(settings: s0)
        check("install: the settings file is rewritten in place (same file), so open sessions notice",
              before != nil && inode(s0) == before && Agents.hooksInstalled(settings: s0) && perms(s0) == 0o644)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: settings.deletingLastPathComponent().path)) ?? []
        check("install: no half-written files are left behind", !leftovers.contains { $0.hasPrefix(".settings.json.top-shelf-") })
    }

    /// The real listener on 127.0.0.1:7823 with the real hook command (curl), on the build machine.
    static func listenerTest() {
        let d = tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let a = Agents(dir: d, live: true)
        wait(1) { false }
        func curl(_ header: String) -> Int32 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "printf '%s' '{\"session_id\":\"live\",\"hook_event_name\":\"UserPromptSubmit\",\"cwd\":\"/tmp/live-check\"}' | curl -s -m 2 -o /dev/null -w '%{http_code}' -H @\"$H\" --data-binary @- http://127.0.0.1:7823/event > \"$OUT\""]
            let out = d.appendingPathComponent("code-\(UUID().uuidString)")
            p.environment = ["H": header, "OUT": out.path, "PATH": "/usr/bin:/bin"]
            try? p.run()
            wait(5) { !p.isRunning }
            return Int32((try? String(contentsOf: out, encoding: .utf8)) ?? "") ?? -1
        }
        let good = d.appendingPathComponent("agent-header").path
        let badFile = d.appendingPathComponent("bad-header")
        try! Data("X-Top-Shelf-Token: \(String(repeating: "f", count: 64))\n".utf8).write(to: badFile)
        check("listener: a hook with a wrong secret gets 401", curl(badFile.path) == 401 && a.sessions.isEmpty)
        check("listener: the real hook command is accepted", curl(good) == 200)
        check("listener: and the session shows as working", a.sessions.first?.name == "live-check" && a.sessions.first?.state == .working)
    }
}

enum Shots {
    static func draw(into dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = ShelfModel()
        Sample.fill(model)
        var states: [(String, Bool, Page)] = [("collapsed-agents", false, .tray)]
        for p in Page.allCases { states.append((p.rawValue.lowercased(), true, p)) }
        for (name, open, page) in states {
            model.page = page
            model.isOpen = open
            shot(ShelfView(model: model).transaction { $0.animation = nil }, size: CGSize(width: 760, height: 260),
                 to: dir.appendingPathComponent("\(name).png"))
        }
        shot(SettingsView(model: model), size: CGSize(width: 560, height: 560), to: dir.appendingPathComponent("settings.png"))
        // closed with only music playing
        _ = SelfTest.post(model.agents, #"{"session_id":"a","hook_event_name":"SessionEnd"}"#)
        _ = SelfTest.post(model.agents, #"{"session_id":"b","hook_event_name":"SessionEnd"}"#)
        model.isOpen = false
        shot(ShelfView(model: model).transaction { $0.animation = nil }, size: CGSize(width: 760, height: 260),
             to: dir.appendingPathComponent("collapsed-music.png"))
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
        model.music.apply(["title": "Sample Song", "artist": "Sample Artist", "album": "Sample Album", "playing": true])
        model.calendar.now = Date()
        model.calendar.next = .init(title: "Design sync", start: Date().addingTimeInterval(11 * 60 - 1), end: Date().addingTimeInterval(41 * 60))
        model.weather.temperature = Measurement(value: 24, unit: .celsius)
        model.weather.code = 2
        model.weather.place = "Sample City"

        let d = SelfTest.tempDir()
        let files = ["Proposal.pdf", "Photo-01.png", "Budget.xlsx"].map { d.appendingPathComponent($0) }
        for f in files { FileManager.default.createFile(atPath: f.path, contents: Data()) }
        model.files.add(files.reversed())
        let now = Date()
        for (i, t) in ["Meeting notes draft for Friday", "https://example.com/sample-link", "https://example.com/sample-link", "Pinned: sample email signature text"].enumerated() {
            model.clipboard.add(.init(kind: .text, text: t, key: t, last: now.addingTimeInterval(Double(i))))
        }
        model.clipboard.togglePin(model.clipboard.clips[0])
        _ = SelfTest.post(model.agents, #"{"session_id":"b","hook_event_name":"Notification","notification_type":"permission_prompt","message":"Claude Code, asking permission to run a command","cwd":"/x/sample-website"}"#)
        _ = SelfTest.post(model.agents, #"{"session_id":"a","hook_event_name":"PostToolUse","tool_name":"Edit","cwd":"/x/sample-project"}"#)
        _ = SelfTest.post(model.agents, #"{"session_id":"a","hook_event_name":"SubagentStart","agent_id":"s1","agent_type":"Explore","cwd":"/x/sample-project"}"#)
    }
}
#endif
