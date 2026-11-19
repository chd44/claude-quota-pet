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

    /// 解析日志里的一行，不是带额度的 token_count 事件就返回 nil。
    /// 只取时间和 rate_limits：同一个文件里的账号信息、对话内容都不看
    public static func parse(line: Data) -> CodexRateReading? {
        guard line.range(of: marker) != nil,
              let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let stamp = obj["timestamp"] as? String, let time = ClaudeTranscriptScanner.parseDate(stamp),
              let payload = obj["payload"] as? [String: Any], payload["type"] as? String == "token_count",
              let limits = payload["rate_limits"] as? [String: Any] else { return nil }
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

/// 增量读取 Codex 的对话日志（~/.codex 下 sessions 和 archived_sessions 里的 *.jsonl），只取额度读数。
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
            if cursors[path] == nil, let base, file.modified < base {
                // 第一次见到、里面的读数又比起点还早：用不上，只从末尾往后跟（接着旧对话聊时会追加）
                cursors[path] = LineCursor(offset: file.size, identityOf: file.url)
                continue
            }
            var cursor = cursors[path] ?? LineCursor()
            cursor.readAppended(from: file.url, size: file.size) { line in
                if let reading = ingest(line: line), reading.isMain, reading.time <= horizon, base.map({ reading.time > $0 }) ?? true {
                    base = reading.time
                }
            }
            cursors[path] = cursor
        }
        cursors = cursors.filter { seen.contains($0.key) }
        trackedFiles = cursors.count
        readings = readings.filter { $0.value.time >= cutoff }
        return readings.values.sorted { $0.time < $1.time }
    }

    @discardableResult
    func ingest(line: Data) -> CodexRateReading? {
        guard let reading = CodexRateReading.parse(line: line) else { return nil }
        readings["\(reading.time.timeIntervalSince1970)|\(reading.limitID ?? "")"] = reading
        return reading
    }
}
