import Foundation
import CoreServices

final class SessionMonitor {
    private let root: URL
    private let queue = DispatchQueue(label: "CodexNotifier.files", qos: .utility)
    private let decoder = EventDecoder()
    private var offsets: [String: UInt64] = [:]
    private var stream: FSEventStreamRef?
    var onEvent: ((SessionEvent) -> Void)?
    var onError: ((String) -> Void)?
    init(root: URL = ReplyData.home.appendingPathComponent("sessions")) { self.root = root }
    func start() throws {
        let parent = root.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: parent.path) else {
            throw NSError(domain: "CodexNotifier", code: 1, userInfo: [NSLocalizedDescriptionKey: "Сначала запусти Codex и создай локальную задачу. Затем выбери «Подключиться заново» в меню."])
        }
        queue.sync { scan(root, baseline: true) }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info = info else { return }
            let monitor = Unmanaged<SessionMonitor>.fromOpaque(info).takeUnretainedValue()
            let names = unsafeBitCast(paths, to: NSArray.self)
            for index in 0..<count {
                guard let name = names[index] as? String else { continue }
                let dropped = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped)
                if flags[index] & dropped != 0 { monitor.scan(monitor.root, baseline: false); break }
                let url = URL(fileURLWithPath: name)
                guard url.path == monitor.root.path || url.path.hasPrefix(monitor.root.path + "/") else { continue }
                if url.pathExtension == "jsonl" { monitor.read(url) }
                else if flags[index] & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0 { monitor.scan(url, baseline: false) }
            }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [parent.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1, flags) else {
            throw NSError(domain: "CodexNotifier", code: 2, userInfo: [NSLocalizedDescriptionKey: "Не удалось подключить отслеживание файлов."])
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else { stop(); throw NSError(domain: "CodexNotifier", code: 3, userInfo: [NSLocalizedDescriptionKey: "Не удалось запустить отслеживание файлов."]) }
        queue.async { [weak self] in guard let self = self else { return }; self.scan(self.root, baseline: false) }
    }
    func stop() {
        if let stream = stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); queue.sync {}; FSEventStreamRelease(stream); self.stream = nil }
    }
    deinit { stop() }
    private func scan(_ directory: URL, baseline: Bool) {
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else { return }
        for case let file as URL in files where file.pathExtension == "jsonl" && file.lastPathComponent.hasPrefix("rollout-") {
            if baseline { offsets[file.path] = UInt64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            else { read(file) }
        }
    }
    private func read(_ url: URL) {
        guard url.lastPathComponent.hasPrefix("rollout-") else { return }
        guard let handle = try? FileHandle(forReadingFrom: url) else { offsets.removeValue(forKey: url.path); return }
        defer { try? handle.close() }
        do {
            let length = try handle.seekToEnd()
            var offset = offsets[url.path] ?? 0
            if offset > length { offset = 0 }
            guard offset < length else { return }
            try handle.seek(toOffset: offset)
            var line = Data(), oversize = false, cursor = offset, safe = offset
            while let block = try handle.read(upToCount: 65536), !block.isEmpty {
                for byte in block {
                    cursor += 1
                    if byte == 10 {
                        if !oversize, let event = decoder.decode(line, filename: url.path) {
                            DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
                        }
                        line.removeAll(keepingCapacity: true); oversize = false; safe = cursor
                    } else if line.count < 1048576 { line.append(byte) } else { oversize = true }
                }
            }
            offsets[url.path] = safe // Incomplete lines are reread after the next write.
        } catch {
            DispatchQueue.main.async { [weak self] in self?.onError?("Не удалось прочитать обновление журнала. Следующая запись будет проверена повторно.") }
        }
    }
}
