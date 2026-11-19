import CoreServices
import Foundation
import QuotaPetCore

/// 用 FSEvents 递归监听目录，回调里给出变化的路径和事件标志（在主线程）。
/// 流启动失败（FSEventStreamStart 返回 false）时 init 返回 nil，调用方不能把这些目录记成「正在监听」，下次兜底刷新再试
final class FileWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: ([FileEvent]) -> Void

    init?(paths: [String], latency: CFTimeInterval = 1.0, onChange: @escaping ([FileEvent]) -> Void) {
        self.onChange = onChange
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return nil }

        var context = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = (unsafeBitCast(eventPaths, to: NSArray.self) as? [String]) ?? []
            let events = paths.prefix(count).enumerated().map { index, path in
                FileEvent(path: path, flags: FileEventFlags(rawValue: eventFlags[index]))
            }
            watcher.onChange(events)
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagWatchRoot)  // WatchRoot：监听的目录本身被移走、改名时才会收到 RootChanged
        guard let stream = FSEventStreamCreate(nil, callback, &context, existing as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        else { return nil }
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        self.stream = stream
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
