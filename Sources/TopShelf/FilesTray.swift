import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Where Top Shelf keeps its own files: ~/Library/Application Support/Top Shelf, readable by John's account only.
func supportFolder() -> URL? {
    guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
    let dir = base.appendingPathComponent("Top Shelf", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return dir
}

/// Writes JSON readable by John's account only, replacing the old file in one step.
func savePrivately<T: Encodable>(_ value: T, to url: URL?) {
    guard let url, let data = try? JSONEncoder().encode(value) else { return }
    try? data.write(to: url, options: [.atomic])
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

/// Up to six files kept on the shelf by reference (the files themselves stay where they are).
@Observable
final class FilesTray {
    struct Item: Codable, Equatable, Identifiable {
        var path: String
        var added: Date
        var id: String { path }
        var url: URL { URL(fileURLWithPath: path) }
    }

    static let limit = 6
    /// Set from Settings; nil = until removed.
    var keepFor: TimeInterval? = 24 * 3600
    private(set) var items: [Item] = []
    private let store: URL?

    init(store: URL?) {
        self.store = store
        if let store, let data = try? Data(contentsOf: store) { items = (try? JSONDecoder().decode([Item].self, from: data)) ?? [] }
        prune()
    }

    /// Adds files, newest first. A file already on the shelf moves to the front instead of appearing twice.
    /// Returns how many could not be added because the shelf was full.
    @discardableResult
    func add(_ urls: [URL], now: Date = Date()) -> Int {
        var refused = 0
        for u in urls where u.isFileURL {
            let path = u.standardizedFileURL.path
            items.removeAll { $0.path == path }
            if items.count >= Self.limit { refused += 1; continue }
            items.insert(Item(path: path, added: now), at: 0)
        }
        save()
        return refused
    }

    func remove(_ item: Item) { items.removeAll { $0 == item }; save() }

    /// Drops expired entries and files that no longer exist.
    func prune(now: Date = Date()) {
        let before = items.count
        items.removeAll { item in
            (keepFor.map { now.timeIntervalSince(item.added) > $0 } ?? false) || !FileManager.default.fileExists(atPath: item.path)
        }
        if items.count != before { save() }
    }

    private func save() { savePrivately(items, to: store) }

    /// Sends the files with AirDrop; the system shows its own picker.
    static func airDrop(_ urls: [URL]) {
        guard let s = NSSharingService(named: .sendViaAirDrop), s.canPerform(withItems: urls) else { return }
        NSApp.activate(ignoringOtherApps: true)
        s.perform(withItems: urls)
    }
}

/// Reads dropped file URLs and hands them over on the main thread.
func loadFileURLs(_ providers: [NSItemProvider], _ done: @escaping ([URL]) -> Void) {
    let group = DispatchGroup()
    var urls: [URL] = []
    let lock = NSLock()
    for p in providers where p.canLoadObject(ofClass: URL.self) {
        group.enter()
        _ = p.loadObject(ofClass: URL.self) { url, _ in
            if let url { lock.lock(); urls.append(url); lock.unlock() }
            group.leave()
        }
    }
    group.notify(queue: .main) { done(urls) }
}

/// An invisible AppKit layer over a file tile: starts a real file drag, and reports only a drag that
/// landed somewhere (so a cancelled drag never loses the file). A click without dragging opens the file.
struct FileDragSource: NSViewRepresentable {
    let url: URL
    let dropped: () -> Void

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ v: DragView, context: Context) { v.url = url; v.dropped = dropped }

    final class DragView: NSView, NSDraggingSource {
        var url: URL?
        var dropped: () -> Void = {}
        private var down: NSEvent?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { down = event }
        override func mouseUp(with event: NSEvent) {
            if down != nil, let url { NSWorkspace.shared.open(url) }
            down = nil
        }
        override func mouseDragged(with event: NSEvent) {
            guard let start = down, let url else { return }
            down = nil
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            let p = convert(start.locationInWindow, from: nil)
            item.setDraggingFrame(NSRect(x: p.x - 24, y: p.y - 24, width: 48, height: 48), contents: icon)
            beginDraggingSession(with: [item], event: start, source: self)
        }
        func draggingSession(_ s: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? [.copy, .move, .generic] : []
        }
        func draggingSession(_ s: NSDraggingSession, endedAt p: NSPoint, operation: NSDragOperation) {
            if !operation.isEmpty { dropped() }
        }
    }
}

struct FilesPage: View {
    let model: ShelfModel
    @State private var airDropTargeted = false
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)   // two rows of three short tiles fit the 106 pt page

    var body: some View {
        let tray = model.files
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                if tray.items.isEmpty {
                    Text("Drop files on the notch to keep them here.")
                        .font(Look.small).foregroundStyle(Look.dim)
                        .frame(maxWidth: .infinity, minHeight: 64)
                        .background(Look.cardGradient, in: RoundedRectangle(cornerRadius: 14))
                } else {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(tray.items) { item in tile(item) }
                    }
                    .frame(maxWidth: .infinity)
                }
                airDrop.frame(width: 130).frame(maxHeight: .infinity)
            }
            .fixedSize(horizontal: false, vertical: true)   // AirDrop is as tall as the tiles beside it
            Text("\(tray.items.count) of \(FilesTray.limit) files. Files leave the tray only after a successful drag out.")
                .font(Look.small).foregroundStyle(Look.dim)
        }
    }

    private func tile(_ item: FilesTray.Item) -> some View {
        HStack(spacing: 6) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.path)).resizable().frame(width: 22, height: 22)
            Text(item.url.lastPathComponent).font(Look.small).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity).frame(height: 34)
        .background(Look.cardGradient, in: RoundedRectangle(cornerRadius: 10))
        .overlay(FileDragSource(url: item.url) { model.files.remove(item) })
        .accessibilityElement(children: .combine)
        .accessibilityHint("Drag out to move or copy it; click to open")
    }

    private var airDrop: some View {
        VStack(spacing: 4) {
            Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 22)).foregroundStyle(Look.blue)
            Text("AirDrop").font(Look.small)
            Text("drop to send").font(Look.small)
        }
        .foregroundStyle(Look.dim)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(airDropTargeted ? Look.faint : .clear, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Look.dim, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
        .onDrop(of: [.fileURL], isTargeted: $airDropTargeted) { providers in
            loadFileURLs(providers) { FilesTray.airDrop($0) }
            return true
        }
        .accessibilityLabel("AirDrop: drop files here to send them")
    }
}
