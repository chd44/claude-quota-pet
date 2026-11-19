import Foundation

/// Claude Code 的一次 API 响应
public struct ClaudeRequest: Equatable, Sendable {
    public var id: String
    public var time: Date
    public var family: ModelFamily
    /// 按模型版本定的价格（见 ClaudePricing.price）
    public var price: ModelPrice
    public var tokens: TokenCounts
    /// 思考程度（high / xhigh / max…），日志里没有就是 nil
    public var effort: String?
    /// 输出 token 里有多少是思考（已经包含在 tokens.output 里）
    public var thinkingTokens: Int

    /// model：日志里的模型名，按它的版本定价；nil 时按这个族当前这一代的价格
    public init(id: String, time: Date, family: ModelFamily, model: String? = nil, tokens: TokenCounts, effort: String? = nil,
                thinkingTokens: Int = 0) {
        self.id = id
        self.time = time
        self.family = family
        self.price = ClaudePricing.price(model: model, family: family)
        self.tokens = tokens
        self.effort = effort
        self.thinkingTokens = thinkingTokens
    }

    /// API 等价花费（美元）
    public var usd: Double { ClaudePricing.cost(price, tokens) }
    /// 其中缓存读的部分
    public var cacheReadUSD: Double { ClaudePricing.cacheReadCost(price, tokens) }
    /// 额度加权花费（缓存读打折），换算成百分比用它
    public var quotaUSD: Double { ClaudePricing.quotaCost(price, tokens) }

    /// 「模型/思考程度」，比如 "opus/max"
    public var group: String { "\(family.rawValue)/\(effort ?? "-")" }
}

/// Claude Code 被限流时写进日志的一条消息（synthetic 占位消息上的 quotaLimits 字段）：
/// 哪个额度用完了、什么时候恢复。这是服务器的原话，和官方读数一样可以宣布「用完了」。
public struct ClaudeLimitEvent: Equatable, Sendable {
    public var time: Date
    /// 和 UsageWindow.id 一样：five_hour、seven_day。别的类型（比如按模型的每周额度）目前不对应任何窗口
    public var window: String
    public var resetsAt: Date

    public init(time: Date, window: String, resetsAt: Date) {
        self.time = time
        self.window = window
        self.resetsAt = resetsAt
    }

    /// {"status":"rejected","rateLimitType":"five_hour","resetsAt":秒级时间戳,…}；不是「被拒绝」就返回 nil
    init?(quotaLimits: Any?, time: Date) {
        guard let q = quotaLimits as? [String: Any], q["status"] as? String == "rejected",
              let window = q["rateLimitType"] as? String,
              let resetsAt = (q["resetsAt"] as? NSNumber)?.doubleValue else { return nil }
        self.init(time: time, window: window, resetsAt: Date(timeIntervalSince1970: resetsAt))
    }
}

/// 增量读取 ~/.claude/projects/**/*.jsonl 里每个 API 响应的 token 用量，以及限流消息。
/// 规则和 usage_lab.py 的 load_requests 一样：一个响应会按内容块拆成多行，
/// 按 message.id 去重，同一响应的各字段取最大值。
/// 每个文件只读新追加的部分，Claude Code 边写我们边算。
public final class ClaudeTranscriptScanner {
    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)
    }

    public let root: URL
    /// 只保留这么久以内的请求（周额度窗口是 7 天，多留一天）
    public let retention: TimeInterval

    private var cursors: [String: LineCursor] = [:]
    private var records: [String: ClaudeRequest] = [:]
    /// 同一次限流会连着重试好几次，按「窗口 + 恢复时间」去重，留最早的那条
    private var limits: [String: ClaudeLimitEvent] = [:]
    public private(set) var trackedFiles = 0
    /// 保留期内的限流消息（按时间排序），refresh 之后更新
    public private(set) var limitEvents: [ClaudeLimitEvent] = []

    public init(root: URL = ClaudeTranscriptScanner.defaultRoot, retention: TimeInterval = 8 * 86400) {
        self.root = root
        self.retention = retention
    }

    /// 读取新增内容，返回保留期内的全部请求（按时间排序）
    public func refresh(now: Date = Date()) -> [ClaudeRequest] {
        let cutoff = now.addingTimeInterval(-retention)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        var seen = Set<String>()
        if let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) {
            for case let url as URL in walker where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
                let path = url.path
                // 很久没动过的文件不用读
                if cursors[path] == nil, let mtime = values.contentModificationDate, mtime < cutoff { continue }
                seen.insert(path)
                var cursor = cursors[path] ?? LineCursor()
                cursor.readAppended(from: url, size: UInt64(values.fileSize ?? 0)) { ingest(line: $0, path: path) }
                cursors[path] = cursor
            }
        }
        cursors = cursors.filter { seen.contains($0.key) }
        trackedFiles = cursors.count
        records = records.filter { $0.value.time >= cutoff }
        limits = limits.filter { $0.value.time >= cutoff }
        limitEvents = limits.values.sorted { $0.time < $1.time }
        return records.values.sorted { $0.time < $1.time }
    }

    private static let usageMarker = Data("\"usage\"".utf8)
    private static let quotaMarker = Data("\"quotaLimits\"".utf8)

    /// 解析一行 jsonl；不是带 usage 的 API 响应、也不是限流消息就忽略
    func ingest(line: Data, path: String) {
        let quota = line.range(of: Self.quotaMarker) != nil
        guard quota || line.range(of: Self.usageMarker) != nil,
              let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let stamp = obj["timestamp"] as? String, let time = Self.parseDate(stamp) else { return }
        if quota, let limit = ClaudeLimitEvent(quotaLimits: obj["quotaLimits"], time: time) {
            let key = "\(limit.window)@\(limit.resetsAt.timeIntervalSince1970)"
            if limits[key].map({ $0.time > limit.time }) ?? true { limits[key] = limit }
        }
        guard let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any], !usage.isEmpty else { return }
        let model = message["model"] as? String
        guard let family = ModelFamily.of(model: model) else { return }  // 例如 <synthetic> 占位消息会被跳过

        func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }
        let cacheCreation = usage["cache_creation"] as? [String: Any] ?? [:]
        let cw5: Int, cw1h: Int
        if cacheCreation.isEmpty {
            cw5 = int(usage["cache_creation_input_tokens"])
            cw1h = 0
        } else {
            cw5 = int(cacheCreation["ephemeral_5m_input_tokens"])
            cw1h = int(cacheCreation["ephemeral_1h_input_tokens"])
        }
        let tokens = TokenCounts(input: int(usage["input_tokens"]), cacheWrite5m: cw5, cacheWrite1h: cw1h,
                                 cacheRead: int(usage["cache_read_input_tokens"]), output: int(usage["output_tokens"]))
        let thinking = int((usage["output_tokens_details"] as? [String: Any])?["thinking_tokens"])
        // 去重的键，和 usage_lab.py 的 load_requests 一样：message.id → requestId → （文件, uuid），都取非空的。
        // 三个都没有的行归到同一个文件里的同一条（和 usage_lab 一样取各字段最大值）：键必须是确定的，
        // 随机生成一个的话，每读一遍文件（换文件、重新扫描）都会重复算一遍
        func nonEmpty(_ value: Any?) -> String? { (value as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let key = nonEmpty(message["id"]) ?? nonEmpty(obj["requestId"]) ?? "\(path)#\(nonEmpty(obj["uuid"]) ?? "")"

        if var previous = records[key] {
            previous.tokens.formMax(tokens)
            previous.thinkingTokens = max(previous.thinkingTokens, thinking)
            previous.time = max(previous.time, time)
            records[key] = previous
        } else {
            records[key] = ClaudeRequest(id: key, time: time, family: family, model: model, tokens: tokens,
                                         effort: obj["effort"] as? String, thinkingTokens: thinking)
        }
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseDate(_ string: String) -> Date? {
        isoFractional.date(from: string) ?? isoPlain.date(from: string)
    }
}
