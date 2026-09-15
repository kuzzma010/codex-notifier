import AppKit
import ApplicationServices

final class ReplySender {
    private var timer: Timer?
    private let queue = DispatchQueue(label: "CodexNotifier.reply", qos: .userInitiated)
    private var generation = 0
    // Count only deliberate actions, never mouse movement or button release.
    static let cancellingEvents: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
    private static func inputSnapshot() -> [UInt32] {
        cancellingEvents.map { CGEventSource.counterForEventType(.combinedSessionState, eventType: $0) }
    }
    static func editorMatches(value: String?, role: String?, text: String) -> Bool {
        guard let value = value, let role = role,
              [kAXTextAreaRole, kAXTextFieldRole].contains(role) else { return false }
        // AX text values can include the editor's trailing line terminator.
        var trimmed = value
        while trimmed.last == "\r" || trimmed.last == "\n" { trimmed.removeLast() }
        return trimmed == text
    }
    static func editorCanBeFilled(value: String?, role: String?, domClasses: [String] = []) -> Bool {
        guard var value = value, let role = role,
              [kAXTextAreaRole, kAXTextFieldRole].contains(role) else { return false }
        while value.last == "\r" || value.last == "\n" { value.removeLast() }
        if value.isEmpty { return true }
        // Chromium exposes an empty ProseMirror composer as its generated
        // placeholder, prefixed by a line terminator, instead of an empty value.
        let placeholders = ["\nAsk anything", "\nСпросите что угодно"]
        return domClasses.contains("ProseMirror") && placeholders.contains(value)
    }
    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
    private static func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value
    }
    private static func isComposer(_ element: AXUIElement) -> Bool {
        guard attribute(element, kAXRoleAttribute as CFString) as? String == kAXTextAreaRole,
              let classes = attribute(element, "AXDOMClassList" as CFString) as? [String] else { return false }
        return classes.contains("ProseMirror")
    }
    private static func findComposer(in root: AXUIElement, limit: Int = 2500) -> AXUIElement? {
        var queue = [root]
        var index = 0
        while index < queue.count && index < limit {
            let element = queue[index]
            index += 1
            if isComposer(element) { return element }
            if let children = attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] {
                queue.append(contentsOf: children)
            }
        }
        return nil
    }
    static func prepareDraft(pid: pid_t, text: String) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 2.5)
        let focused = attribute(app, kAXFocusedUIElementAttribute as CFString)
        var element: AXUIElement?
        if let focused = focused, CFGetTypeID(focused) == AXUIElementGetTypeID() {
            element = (focused as! AXUIElement)
        }
        if element.map({ isComposer($0) }) != true {
            guard let window = attribute(app, kAXFocusedWindowAttribute as CFString),
                  CFGetTypeID(window) == AXUIElementGetTypeID() else { return false }
            element = findComposer(in: window as! AXUIElement)
        }
        guard let element = element else { return false }
        AXUIElementSetMessagingTimeout(element, 2.5)
        var value: CFTypeRef?, role: CFTypeRef?, classes: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        AXUIElementCopyAttributeValue(element, "AXDOMClassList" as CFString, &classes)
        if editorMatches(value: value as? String, role: role as? String, text: text) {
            _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, true as CFBoolean)
            return true
        }
        guard editorCanBeFilled(value: value as? String, role: role as? String,
                                domClasses: classes as? [String] ?? []) else { return false }
        let focusResult = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, true as CFBoolean)
        let setResult = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString)
        guard focusResult == .success, setResult == .success else { return false }
        value = nil
        let readResult = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        let matches = editorMatches(value: value as? String, role: role as? String, text: text)
        return readResult == .success && matches
    }
    func cancel() { generation += 1; timer?.invalidate(); timer = nil }
    func start(thread: String, text: String, mode: String, status: @escaping (String) -> Void, submitted: @escaping () -> Void) {
        cancel()
        let token = generation
        guard let url = ReplyData.link(thread: thread, text: text),
              let appURL = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            status("Codex was not found. Open the task manually."); return
        }
        do {
            guard try ReplyData.draft(thread: thread).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                status("This task already has a draft. It was not replaced."); return
            }
        } catch { status("Could not check the draft. Open the task manually."); return }
        let input = Self.inputSnapshot()
        status(mode == "send" ? "Opening task and preparing to send…" : "Opening task and inserting reply…")
        let config = NSWorkspace.OpenConfiguration(); config.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config) { [weak self] application, error in
            DispatchQueue.main.async {
                guard let self = self, self.generation == token else { return }
                guard error == nil, let application = application else { status("Could not open Codex."); return }
                if mode == "send", !AXIsProcessTrusted() {
                    status("Review the text manually. Allow Accessibility access to enable auto-send.")
                    return
                }
                let pid = application.processIdentifier
                let verificationStart = Date()
                var reading = false
                self.timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
                    guard let self = self, self.generation == token else { return }
                    if Date().timeIntervalSince(verificationStart) > 12 { self.cancel(); status("Could not confirm the text. Check the task before retrying."); return }
                    guard !reading else { return }; reading = true
                    self.queue.async {
                        let draft = mode == "draft" ? (try? ReplyData.draft(thread: thread)) : nil
                        let draftVisible = mode == "draft" && Self.prepareDraft(pid: pid, text: text)
                        DispatchQueue.main.async {
                            reading = false
                            guard self.generation == token else { return }
                            if mode == "draft" {
                                guard draft == text || (draftVisible && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid) else { return }
                                self.cancel(); status("Reply inserted for review."); submitted(); return
                            }
                            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { self.cancel(); status("Focus changed. Review the reply manually."); return }
                            // Do not act over new keyboard/mouse input while the deep link loads.
                            guard Self.inputSnapshot() == input else { self.cancel(); status("New input detected. Send the reply manually."); return }
                            reading = true
                            self.queue.async {
                                let exact = Self.prepareDraft(pid: pid, text: text)
                                DispatchQueue.main.async {
                                    reading = false
                                    guard self.generation == token else { return }
                                    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                                          Self.inputSnapshot() == input else { self.cancel(); status("Focus or input changed. Send the reply manually."); return }
                                    guard exact else { return }
                                    guard NSEvent.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else {
                                        self.cancel(); status("Release modifier keys and send the reply manually."); return
                                    }
                                    self.timer?.invalidate(); self.timer = nil
                                    let source = CGEventSource(stateID: .combinedSessionState)
                                    let down = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true)
                                    let up = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false)
                                    down?.postToPid(pid)
                                    up?.postToPid(pid)
                                    self.cancel()
                                    status(down != nil && up != nil ? "Send requested. Waiting for the task to start…" : "Sending was not confirmed. Check the task before retrying.")
                                    if down != nil && up != nil {
                                        self.timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
                                            self?.cancel(); status("Task start was not confirmed. Check the task before retrying.")
                                        }
                                    }
                                    // No retries: the task_started event dismisses the notice.
                                }
                            }
                        }
                    }
                }
                self.timer?.tolerance = 0.15
            }
        }
    }
}
