import Foundation

/// Codex 额度：本机的 Codex（命令行或桌面端）每轮对话结束时，把服务器给的已用百分比和重置时间记在对话日志里。
/// 只读 ~/.codex 下的对话日志，不联网、不读 auth.json 等登录凭据。
public final class CodexProvider: UsageProvider, @unchecked Sendable {
    public let id = ProviderID.codex
    public let pollInterval: TimeInterval = 60
    public let scanner: CodexLogScanner
    /// 最近一次 snapshot 用到的读数（Codex 总额度），--dump 调试用
    public private(set) var lastReadings: [CodexRateReading] = []

    /// 最近的读数比这更旧时提醒一句：网页、Dot 之类云端任务的用量要等下次在本机用 Codex 才会记下来。
    /// 云端任务可以在你不动的时候一直跑，所以不能等太久
    public static let staleAfter: TimeInterval = 3600

    /// 正常模式：最近一次官方读数超过 staleAfter（1 小时）算旧读数。面板照样画出上次的数字，但整体变灰、标明时间，宠物用中性表情
    public static func isStale(_ snapshot: UsageSnapshot?, now: Date) -> Bool {
        guard let snapshot, snapshot.provider == .codex, snapshot.hasData, let readAt = snapshot.officialAt else { return false }
        return now.timeIntervalSince(readAt) >= staleAfter
    }

    /// 正常模式的过期规则：最近一次官方读数超过 staleAfter 就是未知，不拿旧读数当现在的额度（演示模式不用）
    public static func expiringStale(_ snapshot: UsageSnapshot, now: Date) -> UsageSnapshot {
        guard snapshot.provider == .codex, snapshot.hasData, let readAt = snapshot.officialAt,
              now.timeIntervalSince(readAt) >= staleAfter else { return snapshot }
        let ago = Fmt.ago(readAt, now: now)
        var expired = UsageSnapshot(provider: .codex, windows: [], generatedAt: now, officialAt: readAt, lastActiveAt: snapshot.lastActiveAt,
                             notes: [tr("Codex 最近一次记下官方总额度读数是\(ago)。超过 1 小时的读数不当作现在的额度；本机 Codex 下次在日志里记下总额度时会更新，也可以在官方页面查看。",
                                        "Codex last recorded an overall quota reading \(ago). Readings older than an hour aren’t treated as current usage; it updates when Codex on this Mac next records the overall quota in its logs, or check the official page.")],
                             hasData: false)
        expired.lastStartAt = snapshot.lastStartAt
        return expired
    }

    public static var missingNote: String {
        tr("没找到 Codex 的额度记录。在这台 Mac 上用 Codex（命令行或桌面端）聊过之后就会显示。",
           "No Codex usage records yet. They show up after you use Codex (CLI or desktop app) on this Mac.")
    }

    /// 只记到个别模型自己的额度，没有 Codex 总额度的读数时
    public static var mainMissingNote: String {
        tr("只找到 Codex 个别模型的额度记录，没有总额度的读数：总额度缺数据，用 Codex 聊几句后就会记下来。",
           "Only per-model Codex limits were found, with no overall quota reading: the overall quota is missing and shows up after you chat with Codex.")
    }

    /// 读数太久没更新时给用户看的那句话（预览图也用它）
    public static func staleNote(readAt: Date, now: Date) -> String {
        let ago = Fmt.ago(readAt, now: now)
        return tr("Codex 的总额度读数停在\(ago)。网页、Dot 等云端任务的用量，要等本机 Codex 下次在日志里记下总额度才会反映出来。",
                  "The last overall Codex quota reading was \(ago). Usage from the web or cloud tasks (such as Dots) shows up the next time Codex on this Mac records the overall quota in its logs.")
    }

    public init(home: URL = CodexLogScanner.defaultHome) {
        scanner = CodexLogScanner(home: home)
    }

    public var watchPaths: [String] { scanner.directories.map(\.path) }

    public func isRelevantChange(path: String) -> Bool { path.hasSuffix(".jsonl") }

    public func snapshot(now: Date) throws -> UsageSnapshot {
        // 时间戳在未来的读数（时钟偏差）还不算数，等时间追上了再参与（扫描器里留着）
        let all = scanner.refresh(now: now).filter { $0.time <= now }
        // 最近一次在本机用 Codex：任何 token_count 事件都算，不管有没有带总额度（自动跟随、宠物的「闲了多久」用它）
        let activeAt = scanner.lastActivity(asOf: now)
        let startAt = scanner.lastStart(asOf: now)
        // 只看 Codex 的总额度：个别模型自己的额度不能顶替它（那会把某个模型的百分比当成总额度）
        let readings = all.filter(\.isMain)
        lastReadings = readings
        guard let latest = readings.last else {
            // 只有个别模型的记录：说总额度缺数据，不拿它们凑
            var empty = UsageSnapshot(provider: .codex, windows: [], generatedAt: now, lastActiveAt: activeAt,
                                      notes: [all.isEmpty ? Self.missingNote : Self.mainMissingNote], hasData: false)
            empty.lastStartAt = startAt
            return empty
        }
        let windows = latest.windows.sorted { $0.minutes < $1.minutes }.map {
            window($0, readings: readings, readAt: latest.time, now: now)
        }
        var notes: [String] = []
        if now.timeIntervalSince(latest.time) > Self.staleAfter, windows.contains(where: { $0.official != nil }) {
            notes.append(Self.staleNote(readAt: latest.time, now: now))
        }
        // 百分比只用总额度读数；最近一次使用另算（没带额度的那轮也算），至少不早于最近一次读数
        var snapshot = UsageSnapshot(provider: .codex, windows: windows, generatedAt: now, officialAt: latest.time,
                                     lastActiveAt: max(activeAt ?? latest.time, latest.time), notes: notes)
        snapshot.lastStartAt = startAt
        return snapshot
    }

    /// 一个额度窗口。读数就是官方百分比，不用估算；最近一次读数之后已经重置过的窗口算 0，等下次使用再开始
    func window(_ w: CodexRateReading.Window, readings: [CodexRateReading], readAt: Date, now: Date) -> UsageWindow {
        let duration = TimeInterval(w.minutes * 60)
        let id = Self.windowID(minutes: w.minutes), title = UsageWindow.title(minutes: w.minutes)
        // 和 Claude 一样：5 小时窗口看最近 30 分钟的速度，更长的窗口看最近 24 小时
        let lookback: TimeInterval = duration > 86400 ? 86400 : 1800
        guard now < w.resetsAt else {
            return UsageWindow(id: id, title: title, duration: duration, percent: 0, burnLookback: lookback)
        }
        let start = w.resetsAt.addingTimeInterval(-duration)
        // 同一个窗口里的历次读数（同一个窗口的重置时间偶尔会差一两秒）
        let series = readings.compactMap { r -> UsageSample? in
            guard r.time >= start, r.time <= now,
                  let same = r.windows.first(where: { $0.minutes == w.minutes && abs($0.resetsAt.timeIntervalSince(w.resetsAt)) < 120 })
            else { return nil }
            return UsageSample(time: r.time, value: same.usedPercent)
        }
        let used = max(0, w.usedPercent)
        return UsageWindow(id: id, title: title, duration: duration, percent: used, official: used, officialAt: readAt,
                           startedAt: start, resetsAt: w.resetsAt,
                           burnPerHour: Self.burn(series, windowStart: start, lookback: lookback, now: now), burnLookback: lookback)
    }

    /// 最近 lookback 里涨了多少（百分点 / 小时）。起点是 lookback 开头之前的最后一次读数；
    /// 窗口是 lookback 里才开始的就从 0 算起；都没有就从窗口里第一次读数算起
    static func burn(_ series: [UsageSample], windowStart: Date, lookback: TimeInterval, now: Date) -> Double? {
        guard let last = series.last else { return nil }
        let from = max(now.addingTimeInterval(-lookback), windowStart)
        let base: UsageSample
        if let before = series.last(where: { $0.time <= from }) {
            base = UsageSample(time: from, value: before.value)
        } else if windowStart >= now.addingTimeInterval(-lookback) {
            base = UsageSample(time: windowStart, value: 0)
        } else {
            base = series[0]
        }
        return max(0, last.value - base.value) * 3600 / max(now.timeIntervalSince(base.time), lookback / 3)
    }

    /// 和 Claude 同样长的窗口用同一个 id，菜单栏「5 小时」「5h + 周」两种显示方式对两家都管用
    static func windowID(minutes: Int) -> String {
        switch minutes {
        case 300: return "five_hour"
        case 10080: return "seven_day"
        default: return "codex_\(minutes)m"
        }
    }
}
