import AppKit
import ApplicationServices

final class ReplySender {
    private var timer: Timer?
    private let queue = DispatchQueue(label: "CodexNotifier.reply", qos: .userInitiated)
    private var generation = 0
    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
    func cancel() { generation += 1; timer?.invalidate(); timer = nil }
    func start(thread: String, text: String, mode: String, status: @escaping (String) -> Void, submitted: @escaping () -> Void) {
        cancel()
        let token = generation
        guard let url = ReplyData.link(thread: thread, text: text),
              let appURL = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            status("Приложение Codex не найдено. Открой чат вручную."); return
        }
        do {
            guard try ReplyData.draft(thread: thread).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                status("В чате уже есть черновик. Он не заменён."); return
            }
        } catch { status("Не удалось проверить черновик. Открой чат вручную."); return }
        let start = Date()
        status(mode == "send" ? "Открываю задачу и готовлю отправку…" : "Открываю задачу и вставляю ответ…")
        let config = NSWorkspace.OpenConfiguration(); config.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config) { [weak self] application, error in
            DispatchQueue.main.async {
                guard let self = self, self.generation == token else { return }
                guard error == nil, let application = application else { status("Не удалось открыть Codex."); return }
                if mode == "send", !AXIsProcessTrusted() {
                    status("Текст оставлен для проверки. Для автоотправки разреши управление в настройках универсального доступа.")
                    return
                }
                let pid = application.processIdentifier
                var reading = false
                self.timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
                    guard let self = self, self.generation == token else { return }
                    if Date().timeIntervalSince(start) > 10 { self.cancel(); status("Не удалось подтвердить ввод. Проверь чат перед повтором."); return }
                    guard !reading else { return }; reading = true
                    self.queue.async {
                        let draft = try? ReplyData.draft(thread: thread)
                        DispatchQueue.main.async {
                            reading = false
                            guard self.generation == token, draft == text else { return }
                            if mode == "draft" { self.cancel(); status("Ответ вставлен для проверки."); submitted(); return }
                            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { self.cancel(); status("Фокус изменился. Ответ оставлен для проверки."); return }
                            // Do not act over new keyboard/mouse input while the deep link loads.
                            let elapsed = Date().timeIntervalSince(start)
                            let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
                            let mouseIdle = min(CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown), CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .rightMouseDown))
                            guard idle >= elapsed, mouseIdle + 0.1 >= elapsed else { self.cancel(); status("Ввод изменился. Отправь сообщение вручную."); return }
                            self.timer?.invalidate(); self.timer = nil
                            self.queue.async {
                                let appElement = AXUIElementCreateApplication(pid)
                                AXUIElementSetMessagingTimeout(appElement, 0.5)
                                var focused: CFTypeRef?
                                guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
                                      let focused = focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
                                    DispatchQueue.main.async { if self.generation == token { self.cancel(); status("Поле ввода не подтверждено. Отправь сообщение вручную.") } }; return
                                }
                                let element = focused as! AXUIElement
                                var value: CFTypeRef?, role: CFTypeRef?
                                AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
                                AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
                                let exact = (value as? String) == text
                                let editable = [kAXTextAreaRole, kAXTextFieldRole].contains((role as? String) ?? "")
                                DispatchQueue.main.async {
                                    guard self.generation == token else { return }
                                    guard exact, editable, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { self.cancel(); status("Поле ввода не подтверждено. Отправь сообщение вручную."); return }
                                    let down = AXUIElementPostKeyboardEvent(appElement, 0, 36, true)
                                    let up = AXUIElementPostKeyboardEvent(appElement, 0, 36, false)
                                    self.cancel()
                                    status(down == .success && up == .success ? "Отправка запрошена. Ожидаю начала задачи…" : "Отправка не подтверждена. Проверь чат перед повтором.")
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
