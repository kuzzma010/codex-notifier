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
    @Environment(\.colorScheme) private var scheme
    private var accent: Color { scheme == .dark ? Color(red: 0.78, green: 0.90, blue: 0.84) : Color(red: 0.16, green: 0.37, blue: 0.28) }
    private var onAccent: Color { scheme == .dark ? .black : .white }
    var body: some View {
        Group {
            if expanded {
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Label("Codex", systemImage: "checkmark").foregroundStyle(.secondary); Spacer(); Button(action: expand) { Image(systemName: "chevron.down") }.accessibilityLabel("Свернуть"); Button(action: acknowledge) { Image(systemName: "xmark") }.accessibilityLabel("Увидел") }.font(.system(size: 11))
                    Text("Ответ готов").font(.system(size: 19, weight: .medium))
                    Text(title).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2).help(title)
                    if settings.autoOpen {
                        Text(seconds > 0 ? "До открытия чата: \(seconds) сек." : "Codex открыт · нажми «Увидел»").font(.system(size: 11)).foregroundStyle(.secondary)
                        ProgressView(value: Double(max(0, seconds)), total: Double(settings.delay)).tint(accent)
                    } else { Text("Открытие по нажатию").font(.system(size: 11)).foregroundStyle(.secondary) }
                    HStack {
                        Button(action: open) { Text("Открыть чат").frame(maxWidth: .infinity).padding(.vertical, 7).background(accent, in: RoundedRectangle(cornerRadius: 8)).foregroundColor(onAccent) }
                        Button(action: acknowledge) { Text("Увидел").frame(maxWidth: .infinity).padding(.vertical, 7).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8)) }
                    }.font(.system(size: 12))
                    Text(settings.replyMode == "send" ? "Быстрый ответ · отправить сразу" : "Быстрый ответ · вставить для проверки").font(.system(size: 10)).foregroundStyle(.secondary)
                    HStack { ForEach(ReplyData.texts, id: \.self) { text in Button(action: { reply(text) }) { Text(text).font(.system(size: 12)).frame(maxWidth: .infinity).padding(.vertical, 6).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8)) } } }
                    if !status.isEmpty { Text(status).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }.padding(18).frame(width: 308)
            } else {
                HStack(spacing: 4) {
                    Button(action: open) { Text("Открыть").font(.system(size: 12, weight: .medium)).frame(width: 96, height: 34).background(accent, in: RoundedRectangle(cornerRadius: 9)).foregroundColor(onAccent) }
                    Button(action: expand) { Image(systemName: "ellipsis").frame(width: 32, height: 34) }.accessibilityLabel("Развернуть большую карточку")
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
                       acknowledge: { controller.acknowledge() }, reply: { controller.reply($0) })
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
            Text("CODEX NOTIFIER  /  \(draft.setupComplete ? "НАСТРОЙКИ" : "ПЕРВЫЙ ЗАПУСК")").font(.system(size: 11)).foregroundStyle(.secondary)
            Text("Настрой под себя").font(.system(size: 26, weight: .medium))
            Text("Узнавай, когда ответ готов — удобным для тебя способом.").foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 26) {
                Form {
                    Section("Внешний вид") {
                        Picker("Размер", selection: $draft.size) { Text("Маленькая").tag("small"); Text("Большая").tag("large") }.pickerStyle(.segmented)
                        Picker("Тема", selection: $draft.theme) { Text("Как на устройстве").tag("auto"); Text("Светлая").tag("light"); Text("Тёмная").tag("dark") }
                    }
                    Section("Когда ответ готов") {
                        Toggle("Звуковой сигнал", isOn: $draft.sound)
                        Toggle("Открывать чат автоматически", isOn: $draft.autoOpen)
                        Picker("Через", selection: $draft.delay) { Text("15 секунд").tag(15); Text("30 секунд").tag(30); Text("1 минуту").tag(60) }.disabled(!draft.autoOpen)
                    }
                    Section("Быстрые ответы") {
                        Picker("Режим", selection: $draft.replyMode) { Text("Вставлять для проверки").tag("draft"); Text("Отправлять сразу").tag("send") }
                        if draft.replyMode == "send" {
                            Button("Разрешить управление Codex…") { ReplySender.requestAccessibility() }
                            Text("Для отправки macOS требует разрешение в разделе «Универсальный доступ».").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Section("Запуск") { Toggle("Запускать при входе в macOS", isOn: $draft.startup) }
                }.formStyle(.grouped).frame(width: 352)
                VStack(alignment: .leading, spacing: 18) {
                    Text("ПРЕДПРОСМОТР").font(.system(size: 11)).foregroundStyle(.secondary)
                    NoticeCard(title: "Визуальный стиль уведомлений", settings: draft, expanded: previewExpanded,
                               seconds: draft.delay, status: "", expand: { previewExpanded.toggle() },
                               open: { message = "Чат открыт · демонстрация" }, acknowledge: { message = "Уведомление скрыто · демонстрация" },
                               reply: { message = "\(draft.replyMode == "send" ? "Отправить" : "Вставить"): \($0) · демонстрация" })
                    Button("Проверить уведомление") { controller.test(draft) }
                    Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if !controller.monitorStatus.isEmpty { Text(controller.monitorStatus).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }.frame(width: 308, alignment: .trailing)
            }
            HStack {
                Text("Настройки доступны через значок в строке меню.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Сохранить и начать") {
                    do { try controller.save(draft) } catch { message = error.localizedDescription }
                }.buttonStyle(.borderedProminent).tint(.green)
            }
        }.padding(26).frame(width: 740, height: 640)
        .preferredColorScheme(draft.theme == "auto" ? nil : draft.theme == "dark" ? .dark : .light)
        .onChange(of: draft.size) { previewExpanded = $0 == "large" }
    }
}
