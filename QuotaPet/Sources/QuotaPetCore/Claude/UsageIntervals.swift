import Foundation

/// 两次相邻官方读数之间（约 15 分钟）的一段记录：官方涨了多少，本机花了多少。
/// QuotaPet 把它们一直存下来：用来学习换算率，也方便以后重新做回归（比如检验思考程度的影响）。
public struct UsageInterval: Codable, Equatable, Sendable {
    public var start: Date
    public var end: Date
    /// 这段开始 / 结束时的官方读数（5 小时、每周）
    public var sessionFrom: Double?
    public var sessionTo: Double?
    public var weeklyFrom: Double?
    public var weeklyTo: Double?
    /// 本机 Claude Code 在这段时间里的请求数和 API 等价花费
    public var requests: Int
    public var usd: Double
    /// usd 里缓存读的部分；旧版本记下的区间没有这一项
    public var cacheReadUSD: Double?
    /// 按「模型/思考程度」分的花费，比如 "opus/max"
    public var usdByGroup: [String: Double]
    public var outputTokens: Int
    public var thinkingTokens: Int
    /// 这段的花费是按哪一版价格算的（ClaudePricing.basis）；旧版本记下的没有这一项，当成 1
    public var priceBasis: Int? = nil
    /// 这一段里这个窗口有没有跨过一次确定的重置（官方给的重置时间、限流消息、手动指定的每周重置时间）。
    /// 跨过的话两头的读数属于两个窗口，官方「增量」不是这段本机花费换来的，不能拿来学换算率。
    /// 只有能确定重置时刻的才算（读数掉下去的已经在 delta 里排除了）；旧记录没有这一项，当作没跨过
    public var sessionCrossedReset: Bool? = nil
    public var weeklyCrossedReset: Bool? = nil

    /// 花费是按当前这版价格算的
    public var isCurrentPriceBasis: Bool { (priceBasis ?? 1) >= ClaudePricing.basis }

    /// 花费里有 Haiku：价格改过之后旧版本记下的这种区间花费不对，本机日志又不在了没法重算，就不拿来学换算率
    public var hasHaikuSpend: Bool { usdByGroup.contains { $0.key.hasPrefix("haiku") && $0.value > 0 } }

    /// 这段时间里官方读数涨了多少；中间重置过（读数掉了，或者确定跨过了重置）就是 nil
    public var sessionDelta: Double? { sessionCrossedReset == true ? nil : Self.delta(sessionFrom, sessionTo) }
    /// 额度加权花费（缓存读打折，见 ClaudePricing.cacheReadQuotaWeight）；旧记录算不出来，是 nil
    public var quotaUSD: Double? { cacheReadUSD.map { ClaudePricing.quotaCost(usd: usd, cacheReadUSD: $0) } }
    public var weeklyDelta: Double? { weeklyCrossedReset == true ? nil : Self.delta(weeklyFrom, weeklyTo) }

    static func delta(_ from: Double?, _ to: Double?) -> Double? {
        guard let from, let to, to >= from else { return nil }
        return to - from
    }

    /// 区间结束后要等这么久才切：一个响应会分好几行写进日志，时间按最后一行算（和 usage_lab.py 一样），
    /// 切早了它可能先算进这一段、写完后又算进下一段，记录是只追加的，会重复算。实际日志里同一个响应的各行最多隔几分钟
    static let settleDelay: TimeInterval = 5 * 60

    /// 从官方读数和本机请求里切出完整的区间。只要正常的间隔（≤ 20 分钟，说明桌面端一直开着），
    /// 并且已经结束 settleDelay 以上（晚写进日志的请求也算进来了）。requests 要按时间排序。
    /// since：requests 从什么时候开始是全的（扫描器的保留期）。桌面端的读数可能早得多，更早开始的区间
    /// 本机花费看不全，会被当成 0 记进只追加的记录里，所以不切。
    /// sessionResets：5 小时窗口确定的重置时刻；weeklyResetAnchors：每周窗口任何一次确定的重置时刻，
    /// 每周额度按固定的 168 小时（ClaudeProvider.weekDuration）循环，往前往后都推。区间里跨过了的，按窗口分别标出来
    public static func extract(samples: [PlanUsageSample], requests: [ClaudeRequest], since: Date = .distantPast,
                               sessionResets: [Date] = [], weeklyResetAnchors: [Date] = [], now: Date) -> [UsageInterval] {
        var intervals: [UsageInterval] = []
        var first = 0
        for (a, b) in zip(samples, samples.dropFirst()) {
            let span = b.time.timeIntervalSince(a.time)
            guard span > 0, span <= 20 * 60, a.time >= since, b.time <= now.addingTimeInterval(-settleDelay) else { continue }
            while first < requests.count, requests[first].time <= a.time { first += 1 }
            var interval = UsageInterval(start: a.time, end: b.time, sessionFrom: a.session, sessionTo: b.session,
                                         weeklyFrom: a.weekly, weeklyTo: b.weekly, requests: 0, usd: 0, cacheReadUSD: 0,
                                         usdByGroup: [:], outputTokens: 0, thinkingTokens: 0, priceBasis: ClaudePricing.basis)
            var i = first
            while i < requests.count, requests[i].time <= b.time {
                let r = requests[i]
                let usd = r.usd
                interval.requests += 1
                interval.usd += usd
                interval.cacheReadUSD? += r.cacheReadUSD
                interval.usdByGroup[r.group, default: 0] += usd
                interval.outputTokens += r.tokens.output
                interval.thinkingTokens += r.thinkingTokens
                i += 1
            }
            interval.sessionCrossedReset = sessionResets.contains { $0 > a.time && $0 <= b.time } ? true : nil
            interval.weeklyCrossedReset = weeklyResetAnchors.contains {
                Self.crossesCycle(anchor: $0, period: ClaudeProvider.weekDuration, after: a.time, upTo: b.time)
            } ? true : nil
            intervals.append(interval)
        }
        return intervals
    }

    /// 从 anchor 起每 period 一次的重置，在 (after, upTo] 里有没有
    static func crossesCycle(anchor: Date, period: TimeInterval, after: Date, upTo: Date) -> Bool {
        let next = anchor.addingTimeInterval(period * ((after.timeIntervalSince(anchor) / period).rounded(.down) + 1))
        return next > after && next <= upTo
    }
}

/// 区间记录，存在 ~/Library/Application Support/QuotaPet/intervals.jsonl：一行一条，只追加，按结束时间去重。
/// Claude Code 会清理旧日志，这份记录不会。
public final class IntervalArchive {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/QuotaPet/intervals.jsonl")
    }

    public let url: URL
    /// 文件里的和还没写进去的（写失败了，下次合并时再写）
    private var byEnd: [Int64: UsageInterval] = [:]
    private var unsaved: Set<Int64> = []
    private var loaded = false

    public init(url: URL = IntervalArchive.defaultURL) {
        self.url = url
    }

    public var intervals: [UsageInterval] {
        load()
        return byEnd.values.sorted { $0.end < $1.end }
    }

    /// 合并新切出来的区间，没记过的（或者能补全旧记录的）追加到文件末尾；返回写了几条。
    /// 写失败的先留在内存里（照样用来学习），下次合并时再写
    @discardableResult
    public func merge(_ newIntervals: [UsageInterval]) -> Int {
        load()
        for interval in newIntervals {
            guard let key = Self.key(interval), byEnd[key].map({ Self.canUpgrade($0, to: interval) }) ?? true else { continue }
            byEnd[key] = interval
            unsaved.insert(key)
        }
        guard !unsaved.isEmpty else { return 0 }
        var lines = Data()
        var written: [Int64] = []
        for key in unsaved.sorted() {
            guard let interval = byEnd[key], let line = try? Self.encoder.encode(interval) else {
                unsaved.remove(key)  // 编码不了的（比如花费是 NaN）再试也一样
                continue
            }
            lines.append(line)
            lines.append(0x0A)
            written.append(key)
        }
        guard !lines.isEmpty, JSONLFile.append(lines, to: url) else { return 0 }
        unsaved.subtract(written)
        return written.count
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: url) else { return }
        for line in data.split(separator: 0x0A) {
            // 写坏了的行（写到一半、时间离谱）跳过，别让一行坏数据每次启动都崩
            if let interval = try? Self.decoder.decode(UsageInterval.self, from: Data(line)), let key = Self.key(interval) {
                byEnd[key] = interval
            }
        }
    }

    /// 旧版本记下的区间没有缓存读花费。本机日志还在（花费对得上）时，用新切出来的再记一行；
    /// 读回来时同一段以后面那行为准，所以文件还是只追加
    static func canUpgrade(_ old: UsageInterval, to new: UsageInterval) -> Bool {
        // 价格表改过：旧价格算的花费用新价格重算的换掉（新切出来的才有本机日志，日志不在了的留着旧的）
        if (old.priceBasis ?? 1) < (new.priceBasis ?? 1) { return true }
        // 后来才知道这一段跨过了重置（比如命令行读数、限流消息晚到）：补上标记，免得它被拿去学换算率
        if (new.sessionCrossedReset == true && old.sessionCrossedReset != true)
            || (new.weeklyCrossedReset == true && old.weeklyCrossedReset != true) { return true }
        return old.cacheReadUSD == nil && new.cacheReadUSD != nil && abs(old.usd - new.usd) < 0.01
    }

    /// 按结束时间（毫秒）去重；时间不合理（文件写坏了）时是 nil，这一条不用
    static func key(_ interval: UsageInterval) -> Int64? {
        let start = interval.start.timeIntervalSince1970, end = interval.end.timeIntervalSince1970
        guard start.isFinite, end.isFinite, start >= 0, start <= end, end < 1e11 else { return nil }  // 1e11 秒约是公元 5000 年
        return Int64((end * 1000).rounded())
    }

    // 时间存成毫秒时间戳（和桌面端的 plan-usage-history.json 一样），读回来不丢精度
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()
}
