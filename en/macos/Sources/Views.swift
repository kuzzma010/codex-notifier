import SwiftUI
import AppKit
import ServiceManagement

struct Glass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView(); view.material = .hudWindow
        view.blendingMode = .behindWindow; view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct NoticeCard: View {
    let title: String
    let settings: Settings
    let expanded: Bool
    let seconds: Int
    let status: String
    let expand: () -> Void
    let open: () -> Void
    let acknowledge: () -> Void
    let reply: (String) -> Void
    var replyEnabled = true
    @Environment(\.colorScheme) private var scheme
    private var accent: Color { scheme == .dark ? Color(red: 0.78, green: 0.90, blue: 0.84) : Color(red: 0.16, green: 0.37, blue: 0.28) }
    private var onAccent: Color { scheme == .dark ? .black : .white }
    var body: some View {
        Group {
            if expanded {
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Label("Codex", systemImage: "checkmark").foregroundStyle(.secondary); Spacer(); Button(action: expand) { Image(systemName: "chevron.down") }.accessibilityLabel("Collapse"); Button(action: acknowledge) { Image(systemName: "xmark") }.accessibilityLabel("Got it") }.font(.system(size: 11))
                    Text("Reply ready").font(.system(size: 19, weight: .medium))
                    Text(title).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2).help(title)
                    if !replyEnabled { Text("Automatic opening cancelled").font(.system(size: 11)).foregroundStyle(.secondary) }
                    else if settings.autoOpen {
                        Text(seconds > 0 ? "Opening task in: \(seconds) sec." : "Codex opened · click Got it").font(.system(size: 11)).foregroundStyle(.secondary)
                        ProgressView(value: Double(max(0, seconds)), total: Double(settings.delay)).tint(accent)
                    } else { Text("Open manually").font(.system(size: 11)).foregroundStyle(.secondary) }
                    HStack {
                        Button(action: open) { Text("Open task").frame(maxWidth: .infinity).padding(.vertical, 7).background(accent, in: RoundedRectangle(cornerRadius: 8)).foregroundColor(onAccent) }
                        Button(action: acknowledge) { Text("Got it").frame(maxWidth: .infinity).padding(.vertical, 7).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8)) }
                    }.font(.system(size: 12))
                    Text(settings.replyMode == "send" ? "Quick reply · send immediately" : "Quick reply · insert for review").font(.system(size: 10)).foregroundStyle(.secondary)
                    HStack { ForEach(ReplyData.texts, id: \.self) { text in Button(action: { reply(text) }) { Text(text).font(.system(size: 12)).frame(maxWidth: .infinity).padding(.vertical, 6).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8)) } } }.disabled(!replyEnabled)
                    if !status.isEmpty { Text(status).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }.padding(18).frame(width: 308)
            } else {
                HStack(spacing: 4) {
                    Button(action: open) { Text("Open").font(.system(size: 12, weight: .medium)).frame(width: 96, height: 34).background(accent, in: RoundedRectangle(cornerRadius: 9)).foregroundColor(onAccent) }
                    Button(action: expand) { Image(systemName: "ellipsis").frame(width: 32, height: 34) }.accessibilityLabel("Expand notification")
                }.padding(6)
            }
        }.buttonStyle(.plain).background(Glass()).clipShape(RoundedRectangle(cornerRadius: expanded ? 22 : 16))
        .overlay(RoundedRectangle(cornerRadius: expanded ? 22 : 16).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
    }
}

struct NotificationView: View {
    @ObservedObject var controller: AppController
    var body: some View {
        if let notice = controller.current {
            NoticeCard(title: notice.title, settings: controller.displaySettings, expanded: controller.expanded,
                       seconds: controller.seconds, status: controller.replyStatus,
                       expand: { controller.toggleExpanded() }, open: { controller.openCurrent() },
                       acknowledge: { controller.acknowledge() }, reply: { controller.reply($0) }, replyEnabled: !controller.replyInProgress)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var controller: AppController
    @State private var draft: Settings
    @State private var previewExpanded: Bool
    @State private var message = ""
    init(controller: AppController) {
        self.controller = controller
        var value = controller.settings
        value.startup = SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval
        _draft = State(initialValue: value); _previewExpanded = State(initialValue: value.size == "large")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("CODEX NOTIFIER  /  \(draft.setupComplete ? "SETTINGS" : "FIRST RUN")").font(.system(size: 11)).foregroundStyle(.secondary)
            Text("Make it yours").font(.system(size: 26, weight: .medium))
            Text("Know when a reply is ready, your way.").foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 26) {
                Form {
                    Section("Appearance") {
                        Picker("Size", selection: $draft.size) { Text("Small").tag("small"); Text("Large").tag("large") }.pickerStyle(.segmented)
                        Picker("Theme", selection: $draft.theme) { Text("Follow system").tag("auto"); Text("Light").tag("light"); Text("Dark").tag("dark") }
                    }
                    Section("When a reply is ready") {
                        Toggle("Play a sound", isOn: $draft.sound)
                        Toggle("Open task automatically", isOn: $draft.autoOpen)
                        Picker("After", selection: $draft.delay) { Text("15 seconds").tag(15); Text("30 seconds").tag(30); Text("1 minute").tag(60) }.disabled(!draft.autoOpen)
                    }
                    Section("Quick replies") {
                        Picker("Mode", selection: $draft.replyMode) { Text("Insert for review").tag("draft"); Text("Send immediately").tag("send") }
                        Button("Allow Accessibility access…") { ReplySender.requestAccessibility() }
                        Text("Inserting and sending replies requires Accessibility permission on macOS.").font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Startup") { Toggle("Launch at login", isOn: $draft.startup) }
                }.formStyle(.grouped).frame(width: 352)
                VStack(alignment: .leading, spacing: 18) {
                    Text("PREVIEW").font(.system(size: 11)).foregroundStyle(.secondary)
                    NoticeCard(title: "Notification appearance", settings: draft, expanded: previewExpanded,
                               seconds: draft.delay, status: "", expand: { previewExpanded.toggle() },
                               open: { message = "Task opened · preview" }, acknowledge: { message = "Notification dismissed · preview" },
                               reply: { message = "\(draft.replyMode == "send" ? "Send" : "Insert"): \($0) · preview" })
                    Button("Test notification") { controller.test(draft) }
                    Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if !controller.monitorStatus.isEmpty { Text(controller.monitorStatus).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }.frame(width: 308, alignment: .trailing)
            }
            HStack {
                Text("Open settings from the menu bar icon.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Save and start") {
                    do { try controller.save(draft) } catch { message = error.localizedDescription }
                }.buttonStyle(.borderedProminent).tint(.green)
            }
        }.padding(26).frame(width: 740, height: 640)
        .preferredColorScheme(draft.theme == "auto" ? nil : draft.theme == "dark" ? .dark : .light)
        .onChange(of: draft.size) { previewExpanded = $0 == "large" }
    }
}
