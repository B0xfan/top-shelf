import AppKit
import Observation

/// What any player is playing, from the system Now Playing service, with play/pause/skip for that player.
/// Third-party apps lost direct access in macOS 15.4, so a small helper runs inside /usr/bin/perl (Helper/).
@Observable
final class NowPlaying {
    var title: String?
    var artist: String?
    var album: String?
    var isPlaying = false
    var artwork: NSImage?
    var playerID: String?
    /// False once the helper cannot run on this macOS; the music card then says so.
    var available = true

    enum Command: Int { case play = 0, pause = 1, toggle = 2, next = 4, previous = 5 }

    private var input: FileHandle?
    private var buffer = Data()
    private var lastArt: String?
    private var quickFailures = 0
    private var startedAt = Date()

    init(resources: URL?) {
        if let resources { start(resources) }
    }

    func send(_ c: Command) {
        try? input?.write(contentsOf: Data("\(c.rawValue)\n".utf8))
    }

    private func start(_ res: URL) {
        let lib = res.appendingPathComponent("libTopShelfNowPlaying.dylib")
        guard FileManager.default.fileExists(atPath: lib.path) else { available = false; return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [res.appendingPathComponent("nowplaying.pl").path, lib.path]
        let out = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardInput = inp
        p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }   // end of output
            DispatchQueue.main.async { self?.receive(d) }
        }
        // The helper exits when our end of its input closes, so it never outlives Top Shelf.
        p.terminationHandler = { [weak self] p in
            DispatchQueue.main.async { self?.ended(status: p.terminationStatus, res) }
        }
        do { try p.run() } catch { available = false; return }
        startedAt = Date()
        input = inp.fileHandleForWriting
    }

    private func ended(status: Int32, _ res: URL) {
        input = nil
        if status == 3 { available = false; return }   // the helper found the system functions missing
        quickFailures = Date().timeIntervalSince(startedAt) < 30 ? quickFailures + 1 : 0
        guard quickFailures < 5 else { available = false; return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.start(res) }
    }

    private func receive(_ d: Data) {
        buffer.append(d)
        while let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { apply(obj) }
        }
    }

    func apply(_ d: [String: Any]) {
        if d["error"] != nil { available = false; return }
        title = d["title"] as? String
        artist = d["artist"] as? String
        album = d["album"] as? String
        isPlaying = d["playing"] as? Bool ?? false
        playerID = d["bundle"] as? String
        let art = d["art"] as? String
        if art != lastArt {   // pictures arrive with every update; decode only a new one
            lastArt = art
            artwork = art.flatMap { Data(base64Encoded: $0) }.flatMap(NSImage.init(data:))
        }
    }

    var hasTrack: Bool { title?.isEmpty == false }
}
