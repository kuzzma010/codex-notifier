import Foundation

enum SelfTest {
    static func run() throws {
        var count = 0
        func check(_ value: Bool, _ name: String) throws {
            guard value else { throw NSError(domain: "SelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
            count += 1
        }
        let thread = "11111111-2222-4333-8444-555555555555"
        let file = "rollout-2026-09-15T00-00-00-\(thread).jsonl"
        let now = Date()
        let decoder = EventDecoder(started: now.addingTimeInterval(-1))
        let fmt = ISO8601DateFormatter(); fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // Real journals have timestamp/type before payload. Keep that order in fixtures.
        func line(_ kind: String, _ turn: String, _ date: Date? = nil) -> Data {
            Data("{\"timestamp\":\"\(fmt.string(from: date ?? now))\",\"type\":\"event_msg\",\"payload\":{\"type\":\"\(kind)\",\"turn_id\":\"\(turn)\"}}".utf8)
        }
        try check(decoder.decode(line("task_complete", "a"), filename: file)?.thread == thread, "completion")
        try check(decoder.decode(line("task_complete", "a"), filename: file) == nil, "deduplication")
        try check(decoder.decode(line("task_started", "b"), filename: file)?.kind == "task_started", "new turn")
        try check(decoder.decode(line("task_complete", "old", now.addingTimeInterval(-100)), filename: file) == nil, "history ignored")
        try check(decoder.decode(line("turn_aborted", "c"), filename: file)?.kind == "turn_aborted", "abort")
        try check(decoder.decode(line("task_complete", "d"), filename: "bad.jsonl") == nil, "invalid task ID")
        try check(decoder.decode(Data("{\"type\":\"response_item\",\"payload\":BROKEN".utf8), filename: file) == nil, "tool payload ignored")
        try check(ReplyData.link(thread: thread, text: "Да")?.absoluteString.contains("%D0%94%D0%B0") == true, "encoded reply")
        try check(ReplyData.link(thread: "invalid", text: "Да") == nil, "reject invalid destination")
        try check(ReplyData.link(thread: thread, text: "unexpected") == nil, "reject unexpected reply")
        let draft = Data("{\"electron-persisted-atom-state\":{\"thread-client-id-v1:local%3A\(thread)\":\"client-new-thread:test\",\"composer-prompt-drafts-v2\":{\"client-new-thread:test\":\"Дальше\"}}}".utf8)
        try check(try ReplyData.draft(data: draft, thread: thread) == "Дальше", "client identity draft")
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("CodexNotifier-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let url = temp.appendingPathComponent("settings.json")
        var settings = Settings(); settings.theme = "dark"; settings.replyMode = "send"; settings.setupComplete = true
        try settings.save(to: url)
        try check(Settings.load(from: url).theme == "dark" && Settings.load(from: url).replyMode == "send", "settings persist")
        settings.delay = -1; settings.size = "bad"; settings.normalize()
        try check(settings.delay == 30 && settings.size == "small", "settings normalize")
        try check(ReplySender.editorMatches(value: "Дальше", role: "AXTextArea", text: "Дальше"), "visible editor without persisted draft")
        try check(ReplySender.editorMatches(value: "Дальше\n", role: "AXTextField", text: "Дальше"), "editor line terminator")
        try check(!ReplySender.editorMatches(value: "Дальше ещё", role: "AXTextArea", text: "Дальше"), "reject modified text")
        try check(!ReplySender.editorMatches(value: "Дальше", role: "AXButton", text: "Дальше"), "reject non-editor")
        try check(!ReplySender.cancellingEvents.contains(.mouseMoved) && !ReplySender.cancellingEvents.contains(.leftMouseUp), "mouse movement and release do not cancel")
        try check(ReplySender.cancellingEvents.contains(.keyDown) && ReplySender.cancellingEvents.contains(.otherMouseDown) && ReplySender.cancellingEvents.contains(.scrollWheel), "new input cancels")
        try check(!ReplySender.editorMatches(value: "\nДальше", role: "AXTextArea", text: "Дальше"), "leading newline is user content")
        try Data("{\"theme\":\"dark\",\"setupComplete\":true}".utf8).write(to: url)
        try check(Settings.load(from: url).theme == "dark" && Settings.load(from: url).setupComplete && Settings.load(from: url).replyMode == "draft", "older settings keep saved preferences")
        try check(decoder.decode(line("task_complete", "", now.addingTimeInterval(1)), filename: file) != nil && decoder.decode(line("task_complete", "", now.addingTimeInterval(2)), filename: file) != nil, "distinct events without turn IDs")
        print("PASS: \(count) core checks")
    }
}
