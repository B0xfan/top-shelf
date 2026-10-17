import AppKit

/// The Mac's alert sounds as System Settings names them, plus John's own sounds in ~/Library/Sounds.
enum AlertSounds {
    struct Choice: Hashable { let file: String; let name: String }   // `file` is what NSSound(named:) takes

    static let systemFolder = URL(fileURLWithPath: "/System/Library/Sounds")
    static var userFolder: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Sounds") }

    /// File name to the name System Settings shows (its AlertSounds table, English).
    /// shortcut: English names only, read the system's table if Top Shelf is ever translated.
    static let builtIn = ["Tink": "Boop", "Blow": "Breeze", "Pop": "Bubble", "Glass": "Crystal", "Funk": "Funky", "Hero": "Heroine",
                          "Frog": "Jump", "Basso": "Mezzo", "Bottle": "Pebble", "Purr": "Pluck", "Morse": "Pong", "Ping": "Sonar",
                          "Sosumi": "Sonumi", "Submarine": "Submerge"]
    static let kinds: Set<String> = ["aiff", "aif", "wav", "caf", "m4a", "mp3"]

    /// Built-in sounds plus the user's own, skipping exact copies of a built-in one, sorted by name.
    static func all(userFolder: URL = userFolder, systemFolder: URL = systemFolder) -> [Choice] {
        let fm = FileManager.default
        func size(_ u: URL) -> Int { (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1 }
        let systemFiles = builtIn.keys.map { systemFolder.appendingPathComponent("\($0).aiff") }
        let sizes = Set(systemFiles.map(size))
        // only files the same size as a built-in sound are read to compare
        func isCopy(_ u: URL) -> Bool {
            guard sizes.contains(size(u)), let d = try? Data(contentsOf: u) else { return false }
            return systemFiles.contains { size($0) == d.count && (try? Data(contentsOf: $0)) == d }
        }
        var seen = Set(builtIn.keys)
        let own = ((try? fm.contentsOfDirectory(at: userFolder, includingPropertiesForKeys: [.fileSizeKey])) ?? [])
            .filter { kinds.contains($0.pathExtension.lowercased()) && !isCopy($0) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { $0.deletingPathExtension().lastPathComponent }
            .filter { seen.insert($0).inserted }   // one entry per name
            .map { Choice(file: $0, name: $0) }
        return (builtIn.map { Choice(file: $0.key, name: $0.value) } + own).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func play(_ file: String) {
        guard let s = NSSound(named: NSSound.Name(file)) else { return }
        s.stop()
        s.play()
    }
}
