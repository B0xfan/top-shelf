import AppKit
import Network
import Observation
import Security
import SwiftUI

/// Claude Code sessions as their hooks report them: working, idle, or waiting for John.
/// Hooks post to a listener that only this Mac can reach (127.0.0.1) and must carry a secret made on first run.
@Observable
final class Agents {
    enum State: String { case working = "Working", idle = "Idle", attention = "Needs attention" }
    struct Session: Identifiable, Equatable {
        var id: String
        var name: String
        var state: State
        var detail: String
        var updated: Date
    }

    static let port: UInt16 = 7823
    static let events = ["UserPromptSubmit", "PostToolUse", "Stop", "Notification", "SessionEnd"]
    private(set) var sessions: [Session] = []
    private(set) var lastSignal: Date?
    private(set) var listenerProblem: String?
    let token: String
    private let dir: URL?
    private var listener: NWListener?
    private var timer: Timer?

    init(dir: URL?, live: Bool) {
        self.dir = dir
        token = Self.loadOrMakeToken(dir: dir)
        guard live else { return }
        startListener()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.prune(now: Date()) }
    }

    var needsAttention: Bool { sessions.contains { $0.state == .attention } }

    // MARK: the secret

    /// The hook sends the secret from a file only John's account can read: `X-Top-Shelf-Token: <64 hex>`.
    static func headerFile(_ dir: URL?) -> URL? { dir?.appendingPathComponent("agent-header") }

    static func loadOrMakeToken(dir: URL?) -> String {
        if let f = headerFile(dir), let line = try? String(contentsOf: f, encoding: .utf8),
           let t = line.split(separator: ":").last?.trimmingCharacters(in: .whitespacesAndNewlines), t.count == 64 {
            return t
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { fatalError("no system randomness") }
        let t = bytes.map { String(format: "%02x", $0) }.joined()
        if let f = headerFile(dir) {
            FileManager.default.createFile(atPath: f.path, contents: Data("X-Top-Shelf-Token: \(t)\n".utf8), attributes: [.posixPermissions: 0o600])
        }
        return t
    }

    // MARK: listener

    private func startListener() {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: Self.port)!)
        params.acceptLocalOnly = true
        do { listener = try NWListener(using: params) } catch { listenerProblem = "Could not listen for agents: \(error.localizedDescription)"; return }
        listener?.stateUpdateHandler = { [weak self] state in
            if case .failed(let e) = state { DispatchQueue.main.async { self?.listenerProblem = "Could not listen for agents: \(e.localizedDescription)" } }
        }
        listener?.newConnectionHandler = { [weak self] c in self?.serve(c) }
        listener?.start(queue: .main)
    }

    private func serve(_ c: NWConnection, buffer: Data = Data()) {
        if buffer.isEmpty {
            c.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { c.cancel() }   // no slow or stuck clients
        }
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self, error == nil else { c.cancel(); return }
            let all = buffer + (data ?? Data())
            switch Self.parse(all) {
            case .incomplete where !done && all.count < Self.maxRequest: self.serve(c, buffer: all)
            case .complete(let req): self.reply(c, self.handle(req, now: Date()))
            default: self.reply(c, 400)
            }
        }
    }

    private func reply(_ c: NWConnection, _ status: Int) {
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found"][status] ?? "Error"
        let body = status == 200 ? "{}" : ""
        let text = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        c.send(content: Data(text.utf8), completion: .contentProcessed { _ in c.cancel() })
    }

    // MARK: request handling (no network, so the self-test can drive it)

    static let maxRequest = 256 * 1024
    struct Request { var method: String; var path: String; var headers: [String: String]; var body: Data }
    enum Parsed { case incomplete, complete(Request), bad }

    static func parse(_ d: Data) -> Parsed {
        guard let end = d.range(of: Data("\r\n\r\n".utf8)) else { return d.count > 16384 ? .bad : .incomplete }
        guard let head = String(data: d[d.startIndex..<end.lowerBound], encoding: .utf8) else { return .bad }
        let lines = head.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count == 3 else { return .bad }
        var headers: [String: String] = [:]
        for l in lines.dropFirst() {
            guard let colon = l.firstIndex(of: ":") else { return .bad }
            headers[l[..<colon].lowercased()] = l[l.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0, length <= maxRequest else { return .bad }
        let body = d[end.upperBound...]
        if body.count < length { return .incomplete }
        return .complete(Request(method: String(first[0]), path: String(first[1]), headers: headers, body: Data(body.prefix(length))))
    }

    /// Returns the HTTP status for one hook post and updates the sessions.
    func handle(_ r: Request, now: Date) -> Int {
        guard r.method == "POST", r.path == "/event" else { return 404 }
        guard let given = r.headers["x-top-shelf-token"], Self.same(given, token) else { return 401 }
        guard let json = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any],
              let id = json["session_id"] as? String, let event = json["hook_event_name"] as? String else { return 400 }
        lastSignal = now
        apply(id: id, event: event, json: json, now: now)
        return 200
    }

    private func apply(id: String, event: String, json: [String: Any], now: Date) {
        if event == "SessionEnd" { sessions.removeAll { $0.id == id }; return }
        let name = (json["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Claude Code"
        let update: (State, String)?
        switch event {
        case "UserPromptSubmit": update = (.working, "Claude Code, working")
        case "PostToolUse": update = (.working, "Claude Code, " + Self.activity(json["tool_name"] as? String))
        case "Stop": update = (.idle, "Claude Code, finished its turn")
        case "Notification":
            switch json["notification_type"] as? String {
            case "permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input":
                update = (.attention, json["message"] as? String ?? "Claude Code needs you")
            case "idle_prompt": update = (.idle, "Claude Code, waiting for you")
            default: update = nil
            }
        default: update = nil
        }
        guard let update else { return }
        let s = Session(id: id, name: name, state: update.0, detail: update.1, updated: now)
        sessions.removeAll { $0.id == id }
        sessions.insert(s, at: 0)
        prune(now: now)
    }

    static func activity(_ tool: String?) -> String {
        switch tool {
        case "Edit", "Write", "MultiEdit", "NotebookEdit": "editing files"
        case "Bash": "running commands"
        case "Read", "Grep", "Glob": "reading files"
        case "WebFetch", "WebSearch": "searching the web"
        default: "working"
        }
    }

    /// Sessions quiet for over an hour leave the list (a closed terminal sends nothing).
    func prune(now: Date) { sessions.removeAll { now.timeIntervalSince($0.updated) > 3600 } }

    /// Compares secrets without stopping at the first difference.
    static func same(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    // MARK: one-click hook install

    /// The command every hook runs: post the event in the background, never slow Claude down, never fail it.
    static let hookCommand = #"curl -s -m 2 -o /dev/null -H @"$HOME/Library/Application Support/Top Shelf/agent-header" -H 'Content-Type: application/json' --data-binary @- http://127.0.0.1:7823/event || true"#
    static let marker = "127.0.0.1:7823/event"

    static func hooksInstalled(settings: URL) -> Bool {
        (try? String(contentsOf: settings, encoding: .utf8))?.contains(marker) == true
    }

    enum InstallError: Error { case unreadable, unwritable }

    /// Writes a file that never exists with looser permissions than `mode`, not even for a moment:
    /// a new file is created with the mode, filled, then renamed over the target. `replace: false` refuses an existing target.
    static func writeKeepingPrivate(_ data: Data, to url: URL, mode: Int, replace: Bool = true) throws {
        if !replace && FileManager.default.fileExists(atPath: url.path) { throw InstallError.unwritable }
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).top-shelf-\(UUID().uuidString)")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(mode))
        guard fd >= 0 else { throw InstallError.unwritable }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try h.write(contentsOf: data)
            try h.synchronize()
            try h.close()
            guard fchmodIfNeeded(tmp, mode), rename(tmp.path, url.path) == 0 else { throw InstallError.unwritable }
        } catch {
            unlink(tmp.path)
            throw error
        }
    }

    /// open() trims the mode by the umask; set it exactly so a 0640 original stays 0640.
    private static func fchmodIfNeeded(_ url: URL, _ mode: Int) -> Bool { chmod(url.path, mode_t(mode)) == 0 }

    /// Backs up Claude Code's settings file, then adds the Top Shelf hooks (once; existing hooks are kept).
    /// Returns the backup's location (nil when there was no settings file yet).
    @discardableResult
    static func installHooks(settings: URL, now: Date = Date()) throws -> URL? {
        let fm = FileManager.default
        var root: [String: Any] = [:]
        var backup: URL?
        // Claude Code's settings can hold secrets: the backup and the new file keep the original's permissions (0600 if new).
        var mode = 0o600
        if fm.fileExists(atPath: settings.path) {
            mode = (try fm.attributesOfItem(atPath: settings.path)[.posixPermissions] as? Int) ?? 0o600
            let data = try Data(contentsOf: settings)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw InstallError.unreadable }
            root = obj
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd-HHmmss"
            let stamp = f.string(from: now)
            let b = settings.deletingLastPathComponent().appendingPathComponent("settings.json.top-shelf-backup-\(stamp)")
            try writeKeepingPrivate(data, to: b, mode: mode, replace: false)
            backup = b
        } else {
            try fm.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            let present = groups.contains { g in
                (g["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String)?.contains(marker) == true }
            }
            if !present { groups.append(["hooks": [["type": "command", "command": hookCommand, "async": true, "timeout": 5]]]) }
            hooks[event] = groups
        }
        root["hooks"] = hooks
        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes])
        try writeKeepingPrivate(out, to: settings, mode: mode)
        return backup
    }

    static var claudeSettings: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json") }
}

struct AgentsPage: View {
    let model: ShelfModel
    @State private var installNote: String?
    @State private var installed = Agents.hooksInstalled(settings: Agents.claudeSettings)

    var body: some View {
        let agents = model.agents
        VStack(alignment: .leading, spacing: 8) {
            if agents.sessions.isEmpty {
                Text(installed ? "No Claude Code sessions right now." : "Top Shelf can show what your Claude Code sessions are doing.")
                    .font(Look.small).foregroundStyle(Look.dim)
            }
            ScrollView {
                VStack(spacing: 8) { ForEach(agents.sessions) { row($0) } }
            }
            .scrollIndicators(.never)
            HStack {
                Text(footer(agents)).font(Look.small).foregroundStyle(Look.dim).lineLimit(1)
                Spacer()
                if !installed {
                    Button("Connect Claude Code") { install() }
                        .buttonStyle(.plain).font(Look.small)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Look.blue, in: Capsule())
                }
            }
        }
    }

    private func row(_ s: Agents.Session) -> some View {
        HStack(spacing: 10) {
            Circle().fill(s.state == .attention ? Look.orange : s.state == .working ? Look.green : Look.dim).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 0) {
                Text(s.name).font(Look.title).lineLimit(1)
                Text(s.detail).font(Look.small).foregroundStyle(Look.dim).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(s.state.rawValue).font(Look.small)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .foregroundStyle(s.state == .attention ? Look.orange : s.state == .working ? Look.green : Look.dim)
                .background((s.state == .attention ? Look.orange : s.state == .working ? Look.green : Look.dim).opacity(0.2), in: Capsule())
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Look.card, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private func footer(_ a: Agents) -> String {
        if let p = a.listenerProblem { return p }
        if let note = installNote { return note }
        guard let t = a.lastSignal else { return installed ? "Connected. No signal yet." : "Not connected yet." }
        return "Last signal " + t.formatted(.relative(presentation: .named))
    }

    private func install() {
        do {
            let backup = try Agents.installHooks(settings: Agents.claudeSettings)
            installed = true
            installNote = backup == nil ? "Connected. New Claude Code sessions will show here."
                                        : "Connected. Your old Claude Code settings were saved as a backup."
        } catch {
            installNote = "Could not connect: Claude Code's settings file could not be read. Nothing was changed."
        }
    }
}
