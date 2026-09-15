import Foundation

struct Settings: Codable {
    var theme = "auto"
    var size = "small"
    var sound = true
    var autoOpen = true
    var delay = 30
    var replyMode = "draft"
    var startup = false
    var setupComplete = false
    mutating func normalize() {
        if !["auto", "light", "dark"].contains(theme) { theme = "auto" }
        if !["small", "large"].contains(size) { size = "small" }
        if ![15, 30, 60].contains(delay) { delay = 30 }
        if !["draft", "send"].contains(replyMode) { replyMode = "draft" }
    }
    static var file: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CodexNotifier/settings.json")
    }
    static func load(from url: URL = file) -> Settings {
        guard let data = try? Data(contentsOf: url),
              let saved = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let defaults = try? JSONEncoder().encode(Settings()),
              var merged = (try? JSONSerialization.jsonObject(with: defaults)) as? [String: Any] else { return Settings() }
        merged.merge(saved) { _, saved in saved }
        guard let complete = try? JSONSerialization.data(withJSONObject: merged),
              var settings = try? JSONDecoder().decode(Settings.self, from: complete) else { return Settings() }
        settings.normalize(); return settings
    }
    func save(to url: URL = file) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

struct SessionEvent: Equatable {
    let kind: String
    let thread: String
    let turn: String
}

final class EventDecoder {
    private let started: Date
    private var seen = Set<String>()
    private var order: [String] = []
    private let fractional = ISO8601DateFormatter()
    private let plain = ISO8601DateFormatter()
    init(started: Date = Date()) {
        self.started = started
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }
    func decode(_ line: Data, filename: String) -> SessionEvent? {
        // Avoid allocating dictionaries for large response/tool payloads.
        let prefix = String(decoding: line.prefix(512), as: UTF8.self)
        guard let payloadRange = prefix.range(of: "\"payload\""),
              prefix[..<payloadRange.lowerBound].contains("\"event_msg\"") else { return nil }
        let payload = prefix[payloadRange.upperBound...]
        guard let type = payload.range(of: "\"type\""),
              let colon = payload[type.upperBound...].firstIndex(of: ":"),
              let first = payload[payload.index(after: colon)...].firstIndex(of: "\"") else { return nil }
        let rest = payload[payload.index(after: first)...]
        guard let end = rest.firstIndex(of: "\""), ["task_complete", "task_started", "turn_aborted"].contains(String(rest[..<end])) else { return nil }
        guard let row = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              row["type"] as? String == "event_msg",
              let timestamp = row["timestamp"] as? String,
              let time = fractional.date(from: timestamp) ?? plain.date(from: timestamp), time >= started,
              let p = row["payload"] as? [String: Any], let kind = p["type"] as? String,
              ["task_complete", "task_started", "turn_aborted"].contains(kind) else { return nil }
        let thread = String(URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent.suffix(36)).lowercased()
        guard UUID(uuidString: thread) != nil else { return nil }
        let turn = (p["turn_id"] as? String) ?? ""
        if kind != "task_started" {
            let key = "\(thread):\(turn.isEmpty ? timestamp : turn):\(kind)"
            guard seen.insert(key).inserted else { return nil }
            order.append(key)
            if order.count > 2048 { seen.remove(order.removeFirst()) }
        }
        return SessionEvent(kind: kind, thread: thread, turn: turn)
    }
}

enum ReplyData {
    static let texts = ["Yes", "Continue", "Do it"]
    static func link(thread: String, text: String? = nil) -> URL? {
        guard UUID(uuidString: thread) != nil else { return nil }
        if let text = text, !texts.contains(text) { return nil }
        var url = URLComponents()
        url.scheme = "codex"; url.host = "threads"; url.path = "/" + thread.lowercased()
        if let text = text { url.queryItems = [URLQueryItem(name: "prompt", value: text)] }
        return url.url
    }
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex") }
    static func draft(thread: String) throws -> String {
        try draft(data: Data(contentsOf: home.appendingPathComponent(".codex-global-state.json")), thread: thread)
    }
    static func draft(data: Data, thread: String) throws -> String {
        guard let state = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let atoms = state["electron-persisted-atom-state"] as? [String: Any],
              let drafts = atoms["composer-prompt-drafts-v2"] as? [String: String] else { return "" }
        let alias = atoms["thread-client-id-v1:local%3A" + thread] as? String
        for key in [alias, "local:" + thread, thread].compactMap({ $0 }) {
            if let text = drafts[key], !text.isEmpty { return text }
        }
        return ""
    }
}
