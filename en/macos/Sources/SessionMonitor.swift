import Foundation
import CoreServices
import Darwin

final class SessionMonitor {
    private let root: URL
    private let queue = DispatchQueue(label: "CodexNotifier.files", qos: .utility)
    private let decoder = EventDecoder()
    private var offsets: [String: UInt64] = [:]
    private var stream: FSEventStreamRef?
    private var fileSources: [String: DispatchSourceFileSystemObject] = [:]
    private var directorySources: [String: DispatchSourceFileSystemObject] = [:]
    var onEvent: ((SessionEvent) -> Void)?
    var onError: ((String) -> Void)?
    init(root: URL = ReplyData.home.appendingPathComponent("sessions")) { self.root = root }
    func start() throws {
        let parent = root.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: parent.path) else {
            throw NSError(domain: "CodexNotifier", code: 1, userInfo: [NSLocalizedDescriptionKey: "Start Codex and create a local task, then select Reconnect in the menu."])
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
                if url.pathExtension == "jsonl" {
                    monitor.read(url)
                } else if flags[index] & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0 {
                    monitor.scan(url, baseline: false)
                }
            }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [parent.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1, flags) else {
            throw NSError(domain: "CodexNotifier", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not connect the file monitor."])
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else { stop(); throw NSError(domain: "CodexNotifier", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not start the file monitor."]) }
        queue.async { [weak self] in guard let self = self else { return }; self.scan(self.root, baseline: false) }
    }
    func stop() {
        if let stream = stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); queue.sync {}; FSEventStreamRelease(stream); self.stream = nil }
        queue.sync {
            fileSources.values.forEach { $0.cancel() }; fileSources.removeAll()
            directorySources.values.forEach { $0.cancel() }; directorySources.removeAll()
        }
    }
    deinit { stop() }
    private func scan(_ directory: URL, baseline: Bool) {
        watchDirectory(directory)
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
        for case let file as URL in files {
            if (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                watchDirectory(file); continue
            }
            guard file.pathExtension == "jsonl", file.lastPathComponent.hasPrefix("rollout-") else { continue }
            if baseline { offsets[file.path] = UInt64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            else { read(file) }
            if isRecent(file) { watchFile(file) }
        }
    }
    private func isRecent(_ file: URL) -> Bool {
        let calendar = Calendar.current
        return [0, -1].compactMap { calendar.date(byAdding: .day, value: $0, to: Date()) }.contains { date in
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            guard let year = parts.year, let month = parts.month, let day = parts.day else { return false }
            let directory = root
                .appendingPathComponent(String(format: "%04d", year))
                .appendingPathComponent(String(format: "%02d", month))
                .appendingPathComponent(String(format: "%02d", day))
            return file.path.hasPrefix(directory.path + "/")
        }
    }
    private func watchFile(_ url: URL) {
        guard fileSources[url.path] == nil, isRecent(url) else { return }
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .extend, .rename, .delete], queue: queue)
        source.setEventHandler { [weak self] in
            guard let self = self, let active = self.fileSources[url.path] else { return }
            let events = active.data
            if events.contains(.rename) || events.contains(.delete) {
                active.cancel(); self.fileSources.removeValue(forKey: url.path); self.offsets.removeValue(forKey: url.path)
            } else { self.read(url) }
        }
        source.setCancelHandler { close(descriptor) }
        fileSources[url.path] = source
        source.resume()
    }
    private func watchDirectory(_ url: URL) {
        guard directorySources[url.path] == nil else { return }
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: queue)
        source.setEventHandler { [weak self] in
            guard let self = self, let active = self.directorySources[url.path] else { return }
            let events = active.data
            if events.contains(.rename) || events.contains(.delete) {
                active.cancel(); self.directorySources.removeValue(forKey: url.path)
            } else { self.scan(url, baseline: false) }
        }
        source.setCancelHandler { close(descriptor) }
        directorySources[url.path] = source
        source.resume()
    }
    private func read(_ url: URL) {
        guard url.lastPathComponent.hasPrefix("rollout-") else { return }
        watchFile(url)
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
            DispatchQueue.main.async { [weak self] in self?.onError?("Could not read the log update. The next write will be checked again.") }
        }
    }
}
