import Foundation

/// Codex 每轮对话结束时写进日志的一次额度读数（token_count 事件上的 rate_limits）。
/// 这是 OpenAI 服务器给的官方百分比和重置时间，本机不用估算。
public struct CodexRateReading: Equatable, Sendable {
    public struct Window: Equatable, Sendable {
        /// 窗口长度（分钟）：300 = 5 小时，10080 = 一周；免费版只有一个 43200（30 天）
        public var minutes: Int
        public var usedPercent: Double
        public var resetsAt: Date

        public init(minutes: Int, usedPercent: Double, resetsAt: Date) {
            self.minutes = minutes
            self.usedPercent = usedPercent
            self.resetsAt = resetsAt
        }
    }

    public var time: Date
    /// 额度桶：Codex 的总额度是 "codex"，老版本没有这个字段（nil）。个别模型有自己单独的桶，App 只看总额度。
    /// 字段在、却不是字符串（null、数字…）时是 ""：认不出是哪个桶，不能当成老格式的总额度
    public var limitID: String?
    public var windows: [Window]

    public init(time: Date, limitID: String?, windows: [Window]) {
        self.time = time
        self.limitID = limitID
        self.windows = windows
    }

    /// 是 Codex 总额度的读数：limit_id 是 "codex"，或者确实没有这个字段（老格式，那时只有总额度一个桶）
    public var isMain: Bool { limitID == nil || limitID == "codex" }

    private static let marker = Data("\"rate_limits\"".utf8)
    private static let eventMarker = Data("\"token_count\"".utf8)

    /// 解析日志里的一行，不是带额度的 token_count 事件就返回 nil。
    /// 只取时间和 rate_limits：同一个文件里的账号信息、对话内容都不看
    public static func parse(line: Data) -> CodexRateReading? {
        guard line.range(of: marker) != nil, let event = tokenEvent(line: line) else { return nil }
        return event.reading
    }

    /// 解析一行 token_count 事件：time 是这条记录自己的时间（本机用了一轮 Codex），reading 是它带的额度读数（可能没有）。
    /// 没有 rate_limits、或只有个别模型额度的事件也算「在用」，自动跟随要靠它；只看事件类型和时间，用量、对话内容都不看
    public static func tokenEvent(line: Data) -> (time: Date, reading: CodexRateReading?)? {
        guard line.range(of: eventMarker) != nil,
              let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              obj["type"] as? String == "event_msg",  // 只认事件记录；普通消息正文里碰巧有这个词、或结构对不上的都不算
              let stamp = obj["timestamp"] as? String, let time = ClaudeTranscriptScanner.parseDate(stamp),
              let payload = obj["payload"] as? [String: Any], payload["type"] as? String == "token_count" else { return nil }
        return (time, reading(payload: payload, time: time))
    }

    private static let turnContextWord = Data("turn_context".utf8)
    private static let taskStartedWord = Data("task_started".utf8)
    private static let sessionMetaWord = Data("session_meta".utf8)

    /// 这一行是不是「新一轮开始」的记录（用户发起一轮对话时 Codex 写下的顶层 turn_context，或 event_msg 里的 task_started），是的话返回记录时间。
    /// 含这两个词的行才解析，按顶层字段判断（合法 JSON 带空格也认，嵌在别的字段里的同名类型不认），只取类型和时间，不保存其他内容
    public static func turnStart(line: Data) -> Date? {
        guard line.range(of: turnContextWord) != nil || line.range(of: taskStartedWord) != nil,
              let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let stamp = obj["timestamp"] as? String, let time = ClaudeTranscriptScanner.parseDate(stamp) else { return nil }
        let type = obj["type"] as? String
        if type == "turn_context" { return time }
        if type == "event_msg", (obj["payload"] as? [String: Any])?["type"] as? String == "task_started" { return time }
        return nil
    }

    /// 这一行是不是子代理会话的开头（session_meta 的 source 里有 subagent）：这种会话里的开始记录是后台派生的，不算用户主动开始
    public static func isSubagentSessionMeta(line: Data) -> Bool {
        guard line.range(of: sessionMetaWord) != nil,
              let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], obj["type"] as? String == "session_meta",
              let payload = obj["payload"] as? [String: Any] else { return false }
        if let source = payload["source"] as? [String: Any] { return source.keys.contains { $0.lowercased().contains("subagent") } }
        return false
    }

    private static func reading(payload: [String: Any], time: Date) -> CodexRateReading? {
        guard let limits = payload["rate_limits"] as? [String: Any] else { return nil }
        var windows: [Window] = []
        for key in ["primary", "secondary"] {
            // 窗口最长按一年算，免得离谱的数字在后面乘成秒时溢出；百分比限制在 0...100（后面会转成整数显示）
            guard let w = limits[key] as? [String: Any],
                  let minutes = (w["window_minutes"] as? NSNumber)?.intValue, (1...527_040).contains(minutes),
                  let raw = (w["used_percent"] as? NSNumber)?.doubleValue, raw.isFinite,
                  !windows.contains(where: { $0.minutes == minutes })  // 同样长的窗口只留一个，id 不能重复
            else { continue }
            let used = min(max(raw, 0), 100)
            // 新版给秒级时间戳 resets_at；老版本给的是离这条记录还有几秒 resets_in_seconds
            let resetsAt: Date
            if let at = (w["resets_at"] as? NSNumber)?.doubleValue {
                resetsAt = Date(timeIntervalSince1970: at)
            } else if let seconds = (w["resets_in_seconds"] as? NSNumber)?.doubleValue {
                resetsAt = time.addingTimeInterval(seconds)
            } else {
                continue
            }
            // 重置时间只能在这条记录之后一个窗口以内（留几分钟误差）；超出的当成格式变了（比如换成毫秒），不用
            let slack: TimeInterval = 300
            guard resetsAt > time.addingTimeInterval(-slack), resetsAt <= time.addingTimeInterval(TimeInterval(minutes * 60) + slack)
            else { continue }
            windows.append(Window(minutes: minutes, usedPercent: used, resetsAt: resetsAt))
        }
        guard !windows.isEmpty else { return nil }
        // rate_limit_reached_type 先不用：见过的日志里它一直是 null，取值和含义没法确认，猜错了宠物会误睡。只认 used_percent
        let limitID: String?
        if let raw = limits["limit_id"] { limitID = raw as? String ?? "" } else { limitID = nil }
        return CodexRateReading(time: time, limitID: limitID, windows: windows)
    }
}

/// 增量读取 Codex 的对话日志（~/.codex 下 sessions 和 archived_sessions 里的 *.jsonl），只取额度读数和每轮用量记录的时间。
/// 日志加起来可能有几百 MB：第一次从最近改过的文件往前读，读到一条比「现在 − 25 小时」还早的读数就停（算消耗速度的起点）；
/// 之后每个文件只读新追加的部分。
public final class CodexLogScanner {
    public static var defaultHome: URL {
        if let custom = ProcessInfo.processInfo.environment["CODEX_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    public let home: URL
    /// 只保留这么久以内的读数（免费版的窗口是 30 天，多留一天）
    public let retention: TimeInterval
    /// 第一次读时要读到这么久以前：算消耗速度最多往回看 24 小时，起点是那之前的最后一次读数
    static let backfill: TimeInterval = 25 * 3600

    /// 对话日志所在的目录。~/.codex 下别的文件（auth.json 登录凭据、数据库等）都不碰
    public var directories: [URL] {
        [home.appendingPathComponent("sessions", isDirectory: true), home.appendingPathComponent("archived_sessions", isDirectory: true)]
    }

    private var cursors: [String: LineCursor] = [:]
    /// 最近用过 Codex 的时间（token_count 事件自己的时间，不是读到它的时间）：重扫、归档挪动都不会续期。
    /// 记一个集合而不是最大值：时钟偏差写出的未来时间不能把真正最近的那次盖住
    private var activity: Set<Date> = []
    /// 「新一轮开始」的记录时间（用户主动发起的），和有没有见过这种记录（旧版 Codex 日志没有时，退回用用量记录当开始）
    private var starts: Set<Date> = []
    /// 每个会话文件的状态：是不是子代理会话、有没有出现过开始记录、有没有出现过用量记录
    private struct FileState { var subagent = false; var sawStart = false; var sawUsage = false }
    private var fileStates: [String: FileState] = [:]
    /// 上次看到的每个文件的修改时间：大小没变、修改时间变了（原地改写）时，把末尾一段重新核对一遍
    private var modifiedAt: [String: Date] = [:]
    /// 原地改写、还原的旧文件，只重新核对末尾这么多字节
    static let tailCheck = 256 << 10
    /// 用过的记录只留这么久（自动跟随只看最近 10 分钟，宠物的「闲了多久」看到 1 小时左右）
    static let activityRetention: TimeInterval = 2 * 3600
    /// 按「时间 + 额度桶」去重：对话归档时文件会从 sessions 挪到 archived_sessions，同一条读数会再读到一次
    private var readings: [String: CodexRateReading] = [:]
    public private(set) var trackedFiles = 0

    public init(home: URL = CodexLogScanner.defaultHome, retention: TimeInterval = 31 * 86400) {
        self.home = home
        self.retention = retention
    }

    /// 读取新增内容，返回保留期内的全部读数（按时间排序）
    public func refresh(now: Date = Date()) -> [CodexRateReading] {
        let cutoff = now.addingTimeInterval(-retention)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        var files: [(url: URL, size: UInt64, modified: Date)] = []
        for directory in directories {
            guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Array(keys),
                                                              options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walker where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
                let modified = values.contentModificationDate ?? .distantPast
                if cursors[url.path] == nil, modified < cutoff { continue }  // 很久没动过的文件不用读
                files.append((url, UInt64(values.fileSize ?? 0), modified))
            }
        }

        // 算消耗速度的起点：回看开始之前的最后一次读数（Codex 总额度）。文件里的读数都不晚于它的修改时间，
        // 所以比这条读数还早改过的文件里不会有更近的起点。按现在算，不按最新读数算：最新读数可能就是几分钟前的
        let horizon = now.addingTimeInterval(-Self.backfill)
        var base = readings.values.filter { $0.isMain && $0.time <= horizon }.map(\.time).max()
        var seen = Set<String>()
        for file in files.sorted(by: { $0.modified > $1.modified }) {  // 新的先读
            let path = file.url.path
            seen.insert(path)
            defer { modifiedAt[path] = file.modified }
            if cursors[path] == nil, let base, file.modified < base {
                // 第一次见到、里面的读数又比起点还早：用不上，只从末尾往后跟（接着旧对话聊时会追加）。
                // 还原、导入的文件会保留旧的修改时间，里面却可能有刚发生的记录：末尾一段核对一遍
                cursors[path] = LineCursor(offset: file.size, identityOf: file.url)
                checkTail(of: file.url, size: file.size, readings: false)
                continue
            }
            if let cursor = cursors[path], cursor.offset == file.size, let seen = modifiedAt[path], seen != file.modified {
                // 大小没变、修改时间变了：原地等长改写，游标看不出来，末尾一段重新核对
                checkTail(of: file.url, size: file.size, readings: true)
            }
            var cursor = cursors[path] ?? LineCursor()
            cursor.readAppended(from: file.url, size: file.size) { line in
                if let reading = ingest(line: line, file: path), reading.isMain, reading.time <= horizon, base.map({ reading.time > $0 }) ?? true {
                    base = reading.time
                }
            }
            cursors[path] = cursor
        }
        cursors = cursors.filter { seen.contains($0.key) }
        fileStates = fileStates.filter { seen.contains($0.key) || $0.key.isEmpty }
        modifiedAt = modifiedAt.filter { seen.contains($0.key) }
        trackedFiles = cursors.count
        readings = readings.filter { $0.value.time >= cutoff }
        let recent = now.addingTimeInterval(-Self.activityRetention)
        activity = activity.filter { $0 >= recent }
        starts = starts.filter { $0 >= recent }
        return readings.values.sorted { $0.time < $1.time }
    }

    /// 到 now 为止最近一次在本机用 Codex 的时间（有没有带额度都算）。
    /// 时间在未来的记录（时钟偏差、或系统时间往回拨之前写下的）直接丢掉：不能等时间追上后再冒出来
    public func lastActivity(asOf now: Date) -> Date? {
        dropFuture(now)
        return activity.max()
    }

    /// 到 now 为止最近一次「用户主动开始一轮」的时间。日志里从没出现过开始记录（旧版）时，退回用最近一次用量记录
    public func lastStart(asOf now: Date) -> Date? {
        dropFuture(now)
        return starts.max()
    }

    private func dropFuture(_ now: Date) {
        let limit = now.addingTimeInterval(ActivityLedger.futureTolerance)
        activity = activity.filter { $0 <= limit }
        starts = starts.filter { $0 <= limit }
    }

    /// 重新核对文件末尾一段（最多 tailCheck 字节，从第一个完整行开始），重复的记录自然去重。
    /// readings = false 时只取活动时间（还原的旧文件：额度读数照旧不从旧文件里补）
    private func checkTail(of url: URL, size: UInt64, readings: Bool) {
        guard size > 0, let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        // 末尾那段看不到文件开头：先看第一行是不是子代理会话的 session_meta
        if fileStates[url.path] == nil, (try? handle.seek(toOffset: 0)) != nil, let head = try? handle.read(upToCount: 64 << 10),
           let newline = head.firstIndex(of: 0x0A) {
            ingest(line: Data(head[..<newline]), file: url.path, readings: false)
        }
        let start = size > UInt64(Self.tailCheck) ? size - UInt64(Self.tailCheck) : 0
        guard (try? handle.seek(toOffset: start)) != nil, var data = try? handle.read(upToCount: Int(size - start)) else { return }
        if start > 0, let newline = data.firstIndex(of: 0x0A) { data = Data(data[data.index(after: newline)...]) }
        var lineStart = data.startIndex
        while let newline = data[lineStart...].firstIndex(of: 0x0A) {
            ingest(line: Data(data[lineStart..<newline]), file: url.path, readings: readings)
            lineStart = data.index(after: newline)
        }
    }

    @discardableResult
    func ingest(line: Data, file: String = "", readings keepReadings: Bool = true) -> CodexRateReading? {
        var state = fileStates[file] ?? FileState()
        defer { fileStates[file] = state }
        if CodexRateReading.isSubagentSessionMeta(line: line) {
            state.subagent = true
            return nil
        }
        if let start = CodexRateReading.turnStart(line: line) {
            state.sawStart = true
            activity.insert(start)
            if !state.subagent { starts.insert(start) }  // 子代理会话的开始是后台派生的：只算动静
            return nil
        }
        guard let event = CodexRateReading.tokenEvent(line: line) else { return nil }
        activity.insert(event.time)
        // 旧格式（这个会话里从没出现过开始记录）：只有这个会话的第一条用量记录算开始，之后的是同一轮或后台接着写
        if !state.subagent, !state.sawStart, !state.sawUsage { starts.insert(event.time) }
        state.sawUsage = true
        guard keepReadings, let reading = event.reading else { return nil }
        readings["\(reading.time.timeIntervalSince1970)|\(reading.limitID ?? "")"] = reading
        return reading
    }
}
