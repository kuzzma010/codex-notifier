import AppKit
import SwiftUI
import ServiceManagement

struct PendingNotice {
    let thread: String?
    let title: String
}
final class NoticePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class AppController: NSObject, ObservableObject, NSApplicationDelegate, NSWindowDelegate {
    @Published var settings = Settings.load()
    @Published var current: PendingNotice?
    @Published var expanded = false
    @Published var seconds = 30
    @Published var replyStatus = ""
    @Published var monitorStatus = ""
    private var statusItem: NSStatusItem?
    private var monitor: SessionMonitor?
    private var settingsWindow: NSWindow?
    private var panel: NoticePanel?
    private var queue: [PendingNotice] = []
    private var countdown: Timer?
    private var deadline = Date()
    private var paused = false
    private var pauseItem: NSMenuItem?
    private var testOptions: Settings?
    private var sender = ReplySender()
    @Published var replyInProgress = false
    var displaySettings: Settings { testOptions ?? settings }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "bell.badge", accessibilityDescription: "Codex Notifier")
        let menu = NSMenu()
        let actions: [(String, Selector)] = [("Settings…", #selector(showSettings)), ("Test notification", #selector(testCurrentSettings)), ("Reconnect", #selector(connect)), ("Pause", #selector(togglePause))]
        for (title, selector) in actions {
            let entry = NSMenuItem(title: title, action: selector, keyEquivalent: ""); entry.target = self; menu.addItem(entry)
            if title == "Pause" { pauseItem = entry }
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"); quit.target = self; menu.addItem(quit)
        item.menu = menu; statusItem = item
        connect()
        if !settings.setupComplete { showSettings() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showSettings(); return true }
    func applicationWillTerminate(_ notification: Notification) { monitor?.stop(); countdown?.invalidate(); sender.cancel() }
    @objc func quitApp() { NSApp.terminate(nil) }
    @objc func togglePause() {
        paused.toggle(); pauseItem?.state = paused ? .on : .off
        if paused { queue.removeAll(); dismiss() }
    }
    @objc func connect() {
        monitor?.stop(); monitor = nil
        let instance = SessionMonitor()
        instance.onEvent = { [weak self] event in self?.receive(event) }
        instance.onError = { [weak self] text in self?.monitorStatus = text }
        do { try instance.start(); monitor = instance; monitorStatus = "" } catch { monitorStatus = error.localizedDescription }
    }
    @objc func showSettings() {
        if let window = settingsWindow { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        if let notice = current, notice.thread != nil { queue.insert(notice, at: 0) }
        dismiss()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 640), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings — Codex Notifier"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(controller: self)); window.delegate = self
        settingsWindow = window; window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        window.contentView = nil; settingsWindow = nil
        if current?.thread == nil { dismiss() }
        showNext()
    }
    func save(_ value: Settings) throws {
        var next = value; next.normalize(); next.setupComplete = true
        let registered = SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval
        if next.startup != registered {
            if next.startup { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        }
        do { try next.save() } catch {
            if registered != next.startup { if registered { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() } }
            throw error
        }
        settings = next; settingsWindow?.close()
        if SMAppService.mainApp.status == .requiresApproval { monitorStatus = "Approve login startup in System Settings → General → Login Items." }
    }
    private func title(_ thread: String) -> String {
        guard let data = try? Data(contentsOf: ReplyData.home.appendingPathComponent("session_index.jsonl")), let text = String(data: data, encoding: .utf8) else { return "Your Codex reply is ready" }
        var title = "Task " + String(thread.prefix(8))
        for line in text.split(separator: "\n") {
            guard let row = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any], row["id"] as? String == thread else { continue }
            if let name = row["thread_name"] as? String { title = name }
        }
        return title
    }
    private func receive(_ event: SessionEvent) {
        if event.kind == "task_started" {
            queue.removeAll { $0.thread == event.thread }
            if current?.thread == event.thread { acknowledge() }
            return
        }
        guard !paused else { return }
        queue.removeAll { $0.thread == event.thread }
        queue.append(PendingNotice(thread: event.thread, title: title(event.thread) + (event.kind == "turn_aborted" ? " — stopped" : "")))
        if queue.count > 200 { queue.removeFirst() }
        showNext()
    }
    private func showNext() {
        guard !paused, current == nil, settingsWindow == nil, !queue.isEmpty else { return }
        display(queue.removeFirst(), options: nil)
    }
    private func display(_ notice: PendingNotice, options: Settings?) {
        dismiss(); testOptions = options; current = notice; expanded = displaySettings.size == "large"
        seconds = displaySettings.delay; deadline = Date().addingTimeInterval(TimeInterval(seconds)); replyStatus = ""
        let panel = NoticePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .floating; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.appearance = displaySettings.theme == "auto" ? nil : NSAppearance(named: displaySettings.theme == "dark" ? .darkAqua : .aqua)
        panel.contentView = NSHostingView(rootView: NotificationView(controller: self)); self.panel = panel
        resizePanel(); panel.orderFrontRegardless()
        if displaySettings.sound { NSSound(named: NSSound.Name("Glass"))?.play() }
        if displaySettings.autoOpen {
            countdown = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                self.seconds = max(0, Int(ceil(self.deadline.timeIntervalSinceNow)))
                if self.seconds == 0 {
                    self.countdown?.invalidate(); self.countdown = nil
                    if notice.thread == nil { self.replyStatus = "Test finished. No real task was opened."; self.resizePanel() }
                    else { self.navigate(notice.thread!) }
                }
            }; countdown?.tolerance = 0.2
        }
    }
    func toggleExpanded() { expanded.toggle(); resizePanel() }
    private func resizePanel() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let panel = self.panel, let content = panel.contentView else { return }
            content.layoutSubtreeIfNeeded()
            let size = content.fittingSize
            let frame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
            panel.setFrame(NSRect(x: frame.maxX - size.width - 18, y: frame.minY + 18, width: size.width, height: size.height), display: true)
        }
    }
    @discardableResult private func navigate(_ thread: String) -> Bool {
        guard let url = ReplyData.link(thread: thread) else { return false }
        if !NSWorkspace.shared.open(url) { replyStatus = "Could not open Codex."; expanded = true; resizePanel(); return false }
        return true
    }
    func openCurrent() {
        guard let notice = current else { return }
        if let thread = notice.thread { if navigate(thread) { acknowledge() } }
        else { replyStatus = "Open task · preview"; expanded = true; resizePanel() }
    }
    private func dismiss() {
        sender.cancel(); replyInProgress = false; countdown?.invalidate(); countdown = nil
        panel?.orderOut(nil); panel?.contentView = nil; panel?.close(); panel = nil
        current = nil; testOptions = nil
    }
    func acknowledge() { dismiss(); showNext() }
    @objc func testCurrentSettings() { test(settings) }
    func test(_ options: Settings) {
        if let notice = current, notice.thread != nil { queue.insert(notice, at: 0) }
        display(PendingNotice(thread: nil, title: "Notification appearance"), options: options)
    }
    func reply(_ text: String) {
        guard !replyInProgress, let notice = current else { return }
        countdown?.invalidate(); countdown = nil
        guard let thread = notice.thread else { replyStatus = "\(text) · preview, no message sent"; resizePanel(); return }
        replyInProgress = true
        sender.start(thread: thread, text: text, mode: displaySettings.replyMode, status: { [weak self] status in
            self?.replyStatus = status; self?.expanded = true; self?.resizePanel()
        }, submitted: { [weak self] in self?.acknowledge() })
    }
}
