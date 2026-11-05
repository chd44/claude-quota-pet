import Foundation

/// Claude 额度：官方读数（桌面端；用户打开时还有官方命令行查到的）+ 本机 Claude Code 日志实时估算 + 日志里的限流消息。
/// 这个类自己只读本机文件，不联网、不读凭据：命令行的读数是 App 另外存进文件的（见 ClaudeCLIReadings）。
public final class ClaudeProvider: UsageProvider, @unchecked Sendable {
    public struct Config: Equatable, Sendable {
        /// 用本机日志估算两次官方读数之间的用量
        public var liveEstimate = true
        /// 从持续记录的区间里自动学习换算率；关掉就一直用起始值
        public var autoLearn = true
        /// 用户手动指定的某一次每周重置时间（之后每 7 天一次）；nil 表示自动推算
        public var weeklyResetAnchor: Date?
        /// 用命令行查到的官方读数和重置时间（设置里的「用 Claude 命令行补官方读数」）；关掉就当没有这些读数
        public var useCLIReadings = true

        public init() {}
    }

    public static let sessionDuration: TimeInterval = 5 * 3600
    public static let weekDuration: TimeInterval = 7 * 86400
    /// 官方读数多久没来算停了：桌面端每 15 分钟记一次，连着错过两次
    public static let staleAfter: TimeInterval = 3 * WindowInference.sampleSpacing
    /// 限流消息里没有账号信息，Claude Code 和桌面端登的可能不是同一个账号。所以同一个窗口里有官方读数时要对得上：
    /// 限流之后的读数，或者限流之前的读数 + 之间本机的用量，至少要到这么多。同一个账号撞线时这里接近 100
    /// （给本机看不到的网页 / 手机用量和估算误差留 25 个点）；别的账号撞线时很难刚好这么高
    static let limitEvidenceFloor = 75.0
    /// 限流之前的读数要多新才能拿来核对：桌面端正常每 15 分钟记一次。再旧的读数之后别处（网页、手机）用了多少看不到，
    /// 对不上也说明不了是别的账号，就不拿它否定限流消息
    static let limitEvidenceMaxAge: TimeInterval = staleAfter

    public static var missingHistoryNote: String {
        tr("没找到 Claude 桌面端的额度记录。装好并登录 Claude 桌面端后，它每 15 分钟会记一次官方额度。",
           "No usage history from the Claude desktop app yet. Once it's installed and signed in, it records your official usage every 15 minutes.")
    }

    public let id = ProviderID.claude
    public let pollInterval: TimeInterval = 60
    public let historyURL: URL
    public let scanner: ClaudeTranscriptScanner
    /// 区间记录；nil 表示不落盘（自检用）
    public let archive: IntervalArchive?

    /// 存每周窗口推出来的开始时间（见 weeklyOrigin），和区间记录放在一起；nil 表示不落盘（自检用）
    public let originURL: URL?
    /// 命令行查到的官方读数（见 ClaudeCLIReadings），和区间记录放在一起；nil 表示不读（自检用）
    public let cliArchive: CLIReadingArchive?

    /// 最近一次 snapshot 用到的数据，--dump 调试用
    public private(set) var lastRequests: [ClaudeRequest] = []
    public private(set) var lastSamples: [PlanUsageSample] = []

    private let lock = NSLock()
    private var storedConfig = Config()
    private var historyCache: (mtime: Date, samples: [PlanUsageSample])?
    private var cliCache: (mtime: Date, readings: [CLIReading])?
    private var storedDesktopOrg: String?
    /// 每周额度还没看到过重置时，按第一次使用推出来的当前窗口的开始时间。下次从它接着推：本机日志只留 8 天，
    /// 不记着的话最早的请求每天滚出去一些，窗口的起点跟着往后挪（百分比只剩一两天的用量，旧请求滚出去时还会掉到 0、误报恢复）
    private var weeklyOrigin: Date?
    private var originLoaded = false

    public init(historyURL: URL = ClaudeDesktopHistory.defaultURL, projectsURL: URL = ClaudeTranscriptScanner.defaultRoot,
                archiveURL: URL? = IntervalArchive.defaultURL) {
        self.historyURL = historyURL
        self.scanner = ClaudeTranscriptScanner(root: projectsURL)
        self.archive = archiveURL.map { IntervalArchive(url: $0) }
        self.originURL = archiveURL.map { $0.deletingLastPathComponent().appendingPathComponent("weekly-origin.json") }
        self.cliArchive = archiveURL.map { CLIReadingArchive(url: $0.deletingLastPathComponent().appendingPathComponent("cli-readings.jsonl")) }
    }

    /// 桌面端读数里最近一次的组织：命令行登录的账号要和它对得上才用命令行的读数。可以从任意线程读
    public var desktopOrg: String? {
        lock.lock(); defer { lock.unlock() }
        return storedDesktopOrg
    }

    /// 可以从任意线程设置
    public var config: Config {
        get { lock.lock(); defer { lock.unlock() }; return storedConfig }
        set { lock.lock(); storedConfig = newValue; lock.unlock() }
    }

    public var watchPaths: [String] {
        // 监听 ~/.claude 而不是 projects：用户第一次用 Claude Code 之前 projects 目录还不存在
        [historyURL.deletingLastPathComponent().path, scanner.root.deletingLastPathComponent().path]
    }

    public func isRelevantChange(path: String) -> Bool {
        path.hasSuffix(".jsonl") || path.hasSuffix(historyURL.lastPathComponent)
    }

    // MARK: - Snapshot

    public func snapshot(now: Date) throws -> UsageSnapshot {
        let cfg = config
        let requests = scanner.refresh(now: now)
        let limits = scanner.limitEvents
        var notes: [String] = []

        // 命令行查到的读数（用户打开了「用命令行补官方读数」才有）：有的话桌面端的读数缺着也不用提示
        let cliReadings = cfg.useCLIReadings ? loadCLIReadings(now: now) : []
        let desktop: [PlanUsageSample]
        switch loadHistory() {
        case .ok(let s):
            desktop = s
            if s.isEmpty, cliReadings.isEmpty {
                notes.append(tr("Claude 桌面端还没记录到额度，暂时只能用本机日志估算。",
                                "The Claude desktop app hasn't recorded any usage yet, so for now everything is estimated from local logs."))
            }
        case .missing:
            desktop = []
            if cliReadings.isEmpty { notes.append(Self.missingHistoryNote) }
        case .unreadable(let reason):
            desktop = []
            notes.append(tr("Claude 桌面端的额度记录读不了：\(reason)", "Can't read the Claude desktop app's usage history: \(reason)"))
        }
        lock.lock()
        storedDesktopOrg = desktop.last?.org
        lock.unlock()
        let usableCLI = ClaudeCLIReadings.usable(cliReadings, desktopOrg: desktop.last?.org)
        let samples = ClaudeCLIReadings.merge(desktop: desktop, cli: usableCLI)
        let officialResets = ClaudeCLIReadings.latestResets(usableCLI)
        lastRequests = requests
        lastSamples = samples

        // 每来一次官方读数就多一个完整区间：存进记录，再从全部记录里学换算率
        var recorded = UsageInterval.extract(samples: samples, requests: requests, since: now.addingTimeInterval(-scanner.retention),
                                             now: now)
        if let archive {
            archive.merge(recorded)
            recorded = archive.intervals
        }
        let starting = ClaudeRates.starting
        // 按旧价格记下、花费里有 Haiku 的区间（Haiku 5.5 改价前）本机日志又不在了没法重算：花费不对，不拿来学
        let learnable = recorded.filter { $0.isCurrentPriceBasis || !$0.hasHaikuSpend }
        let sessionFit = RateLearner.learn(learnable, delta: \.sessionDelta, prior: starting.usdPerSessionPercent)
        let weeklyFit = RateLearner.learn(learnable, delta: \.weeklyDelta, prior: starting.usdPerWeeklyPercent)
        let sessionRate = cfg.autoLearn ? sessionFit.usdPerPercent : starting.usdPerSessionPercent
        let weeklyRate = cfg.autoLearn ? weeklyFit.usdPerPercent : starting.usdPerWeeklyPercent
        let estimation = EstimationInfo(
            sessionUSDPerPercent: sessionRate, weeklyUSDPerPercent: weeklyRate,
            learnedIntervals: cfg.autoLearn ? sessionFit.intervals : 0, recordedIntervals: recorded.count,
            learnedUntil: cfg.autoLearn ? sessionFit.latest : nil)

        let sessionSeries = samples.compactMap { s in s.session.map { UsageSample(time: s.time, value: $0) } }
        let weeklySeries = samples.compactMap { s in s.weekly.map { UsageSample(time: s.time, value: $0) } }
        let session = buildWindow(
            id: "five_hour", title: UsageWindow.sessionTitle, duration: Self.sessionDuration,
            series: sessionSeries, requests: requests, scale: 1, percentOf: { $0.quotaUSD / sessionRate },
            resetAnchor: nil, officialReset: officialResets.session, limits: limits, live: cfg.liveEstimate, now: now)
        let origin = loadOrigin()
        let weekly = buildWindow(
            id: "seven_day", title: UsageWindow.weeklyTitle, duration: Self.weekDuration,
            series: weeklySeries, requests: requests, scale: 1, percentOf: { $0.quotaUSD / weeklyRate },
            resetAnchor: cfg.weeklyResetAnchor, officialReset: officialResets.weekly, fixedCadence: true, limits: limits,
            origin: origin, live: cfg.liveEstimate, now: now)
        // 只记按第一次使用推出来的（看到过重置、手动指定、限流中的都有准确的时间）；窗口结束了还没再用时留着旧的
        if !weekly.scheduleKnown, let start = weekly.startedAt, start != origin { saveOrigin(start) }

        return UsageSnapshot(
            provider: .claude, windows: [session, weekly], generatedAt: now, officialAt: samples.last?.time,
            today: todaySummary(requests, now: now), lastActiveAt: requests.last?.time, notes: notes,
            hasData: !samples.isEmpty || !requests.isEmpty, estimation: estimation)
    }

    /// 官方读数 + 读数之后的本机用量 = 当前百分比。本机用量 = Σ percentOf(请求) × scale
    /// limits 是限流消息（只用 window == id 的）：还没到恢复时间时算一次 100% 的官方读数，窗口的开始和重置时间也以它为准。
    /// origin：之前推出来的窗口开始时间（见 weeklyOrigin、WindowInference.infer）
    /// officialReset：命令行查到的官方重置时间（最近一次读数里的）。每周窗口按固定时间重置，过去的重置时间也能往后每 7 天推；
    /// 5 小时窗口只有还没到的才是当前窗口的结束时间，已经过了的当成一次精确的重置
    func buildWindow(id: String, title: String, duration: TimeInterval,
                     series: [UsageSample], requests: [ClaudeRequest], scale: Double,
                     percentOf: (ClaudeRequest) -> Double, resetAnchor: Date?, officialReset: Date? = nil, fixedCadence: Bool = false,
                     limits: [ClaudeLimitEvent] = [], origin: Date? = nil, live: Bool, now: Date) -> UsageWindow {
        // 和这个窗口的官方读数对不上的限流消息（多半是别的账号，或者额度变了）不用，见 limitEvidenceFloor
        func matchesOfficial(_ limit: ClaudeLimitEvent) -> Bool {
            let start = limit.resetsAt.addingTimeInterval(-duration)
            let readings = series.filter { $0.time >= start && $0.time < limit.resetsAt && $0.time <= now }
            if let after = readings.last(where: { $0.time > limit.time }) {
                return after.value >= Self.limitEvidenceFloor
            }
            // 这个窗口里还没有官方读数，或者最近的读数太旧（之后别处用了多少看不到）：没法核对，相信限流消息
            guard let before = readings.last, limit.time.timeIntervalSince(before.time) <= Self.limitEvidenceMaxAge else { return true }
            var local = 0.0
            for r in requests where r.time > before.time && r.time <= limit.time {
                local += percentOf(r)
            }
            return before.value + local * scale >= Self.limitEvidenceFloor
        }
        // 恢复时间不会比限流晚一个窗口以上，超出的当成格式变了，不用
        let limits = limits.filter {
            $0.window == id && $0.time <= now && $0.resetsAt > $0.time && $0.resetsAt <= $0.time.addingTimeInterval(duration)
                && matchesOfficial($0)
        }
        let limit = limits.last.flatMap { now < $0.resetsAt ? $0 : nil }  // 还在限流中

        var current: InferredWindow?
        var lastReset: Date?
        var scheduleKnown = true
        // 限流中：限流消息里的恢复时间就是这个窗口的结束时间；其次是官方给的重置时间（比手动指定的准）；
        // 和手动指定的每周重置时间一样按它往后推
        var anchor = limit?.resetsAt
        var pastOfficialReset: [Date] = []
        if anchor == nil, let officialReset {
            if fixedCadence || officialReset > now {
                anchor = officialReset
            } else {
                pastOfficialReset = [officialReset]
            }
        }
        if let anchor = anchor ?? resetAnchor {
            current = WindowInference.cycle(from: anchor, duration: duration, now: now)
            lastReset = current?.start
        } else {
            let inferred = WindowInference.infer(samples: series, activity: requests.map(\.time), duration: duration, now: now,
                                                 knownResets: limits.map(\.resetsAt) + pastOfficialReset, fixedCadence: fixedCadence,
                                                 origin: origin)
            current = inferred.current
            lastReset = inferred.lastReset
            // 按固定时间重置的窗口还没看到过重置：是按第一次使用猜的，会偏晚。5 小时窗口本来就从第一次使用开始算
            scheduleKnown = !fixedCadence || inferred.fromCadence
        }

        func added(after from: Date, including: Bool = false) -> Double {
            guard live else { return 0 }
            var sum = 0.0
            for r in requests where (r.time > from || (including && r.time == from)) && r.time <= now {
                sum += percentOf(r)
            }
            return sum * scale
        }

        // 限流中：限流消息就是一次 100% 的官方读数。它之后桌面端没到 100 的读数（只差一点，见 matchesOfficial）不算
        var officialReadings = series
        if let limit {
            officialReadings.removeAll { $0.time > limit.time && $0.value < 100 }
            officialReadings.insert(UsageSample(time: limit.time, value: 100),
                                    at: officialReadings.firstIndex { $0.time > limit.time } ?? officialReadings.endIndex)
        }

        var percent = 0.0
        var official: Double?
        var officialAt: Date?
        var limitReported = false
        // 最近的官方读数还属于当前窗口：在最近一次重置之后，也不比一个窗口还旧（窗口就这么长，再旧的读数所在的窗口早就结束了，
        // 比如每周额度的读数停在 9 天前、桌面端一直没开）
        if let last = officialReadings.last, lastReset.map({ $0 <= last.time }) ?? true, now.timeIntervalSince(last.time) < duration {
            official = last.value
            officialAt = last.time
            limitReported = last.time == limit?.time
            percent = last.value + added(after: last.time)
        } else if let window = current {
            // 读数之后窗口已经重置过了，只能从窗口开始累计本机用量
            percent = added(after: window.start, including: true)
        }
        // 只有官方读数或限流消息能宣布「用完了」：估算最多到 99%，免得宠物误睡、误发限流提醒
        if (official ?? 0) < 100 { percent = min(percent, 99) }

        // 其他端用量：当前窗口里官方读数涨了、本机日志解释不了的部分。用桌面端的原始读数，不含限流消息那次 100%，
        // 免得把撞线时估算和 100 之间的差当成其他端
        var other: [OtherUsage.Segment] = []
        if live, let window = current {
            let readings = series.filter { $0.time > window.start && $0.time <= now }
            let local: (ClaudeRequest) -> Double = { percentOf($0) * scale }
            // 窗口开始时是 0 只是推算的：开始前最后一次官方读数确实是 0 才从窗口开始算；不然从窗口里第一次读数算起，
            // 免得窗口开始推算得偏晚（比如桌面端的记录是从一周中间开始的）时，把之前的用量都当成其他端
            if let first = readings.first, series.last(where: { $0.time <= window.start })?.value != 0 {
                other = OtherUsage.segments(start: first.time, startValue: first.value, readings: Array(readings.dropFirst()),
                                            requests: requests, percentOf: local)
            } else {
                other = OtherUsage.segments(start: window.start, readings: readings, requests: requests, percentOf: local)
            }
        }

        // 5 小时窗口看最近 30 分钟的速度；每周窗口看最近 24 小时，不然一会儿猛用就会误报「几小时后用完」
        let lookback: TimeInterval = duration > 86400 ? 86400 : 1800
        var burn: Double?
        var otherBurn: Double?
        if live {
            let from = max(now.addingTimeInterval(-lookback), current?.start ?? .distantPast)
            let otherPerHour = OtherUsage.burnPerHour(other, from: from, now: now, minSpan: lookback / 3)
            otherBurn = otherPerHour
            // 回看被窗口开始截断时，开启窗口的那个请求（时间正好是窗口开始）也要算进去，和百分比一样（including）。
            // 不然窗口开始后的半小时里速度只算后面的请求，刚开工就猛用时「烧得快」「快用完」来得太晚
            burn = added(after: from, including: from == current?.start) * 3600 / max(now.timeIntervalSince(from), lookback / 3)
                + otherPerHour
        }

        return UsageWindow(id: id, title: title, duration: duration, percent: percent,
                           official: official, officialAt: officialAt, limitReported: limitReported, startedAt: current?.start,
                           resetsAt: current?.end, scheduleKnown: scheduleKnown, otherPercent: other.reduce(0) { $0 + $1.percent },
                           burnPerHour: burn, otherBurnPerHour: otherBurn, burnLookback: lookback)
    }

    func todaySummary(_ requests: [ClaudeRequest], now: Date) -> ActivitySummary {
        let dayStart = Calendar.current.startOfDay(for: now)
        var summary = ActivitySummary()
        var byFamily: [ModelFamily: FamilyUsage] = [:]
        for r in requests where r.time >= dayStart && r.time <= now {
            let usd = r.usd
            summary.requests += 1
            summary.tokens += r.tokens.total
            summary.usd += usd
            byFamily[r.family, default: FamilyUsage(family: r.family.displayName, requests: 0, usd: 0)].requests += 1
            byFamily[r.family]?.usd += usd
        }
        summary.byFamily = byFamily.values.sorted { $0.usd > $1.usd }
        return summary
    }

    // MARK: - 每周窗口的起点

    private struct StoredOrigin: Codable {
        var start: Date
    }

    private func loadOrigin() -> Date? {
        if !originLoaded {
            originLoaded = true
            if let originURL, let data = try? Data(contentsOf: originURL),
               let stored = try? Self.originDecoder.decode(StoredOrigin.self, from: data) {
                weeklyOrigin = stored.start
            }
        }
        return weeklyOrigin
    }

    private func saveOrigin(_ start: Date) {
        weeklyOrigin = start
        guard let originURL, let data = try? Self.originEncoder.encode(StoredOrigin(start: start)) else { return }
        try? FileManager.default.createDirectory(at: originURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: originURL, options: .atomic)
    }

    private static let originEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    private static let originDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()

    // MARK: - 桌面端读数

    enum HistoryState {
        case ok([PlanUsageSample])
        case missing
        case unreadable(String)
    }

    /// 命令行读数文件里的内容，按修改时间缓存（探测器写入之后才重读）
    private func loadCLIReadings(now: Date) -> [CLIReading] {
        guard let cliArchive, let mtime = cliArchive.modificationDate else { return [] }
        // 缓存的是文件里的全部读数：过了保留期的在使用时去掉（文件不变时缓存里的不会自己过期）
        let cutoff = now.addingTimeInterval(-ClaudeCLIReadings.retention)
        if let cache = cliCache, cache.mtime == mtime { return cache.readings.filter { $0.time > cutoff } }
        let readings = cliArchive.readings(now: now)
        cliCache = (mtime, readings)
        return readings.filter { $0.time > cutoff }
    }

    private func loadHistory() -> HistoryState {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: historyURL.path) else { return .missing }
        let mtime = attrs[.modificationDate] as? Date ?? .distantPast
        if let cache = historyCache, cache.mtime == mtime { return .ok(cache.samples) }
        do {
            let samples = try ClaudeDesktopHistory.parse(Data(contentsOf: historyURL))
            historyCache = (mtime, samples)
            return .ok(samples)
        } catch {
            // 桌面端正在写文件时可能读到半截，先用上一次的结果
            if let cache = historyCache { return .ok(cache.samples) }
            return .unreadable(error.localizedDescription)
        }
    }
}
