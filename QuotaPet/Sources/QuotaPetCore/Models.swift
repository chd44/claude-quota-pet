import Foundation

/// 额度来源。以后接 Cursor、Gemini…就在这里加 case，再实现一个 UsageProvider。
public enum ProviderID: String, Codable, CaseIterable, Sendable {
    case claude
    case codex

    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }
}

/// 一个额度窗口，比如 Claude 的「5 小时会话」和「本周额度」。
public struct UsageWindow: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var duration: TimeInterval
    /// 当前百分比 = 最近一次官方读数 + 之后本机用量的实时估算（可能超过 100）
    public var percent: Double
    /// 最近一次官方读数（整数）和读数时间；读数属于已经重置掉的旧窗口时为 nil
    public var official: Double?
    public var officialAt: Date?
    /// official 是 Claude Code 限流消息报告的「用完了」，不是桌面端的读数
    public var limitReported: Bool
    /// 当前窗口的开始 / 重置时间（推算值）；窗口还没开始时为 nil
    public var startedAt: Date?
    public var resetsAt: Date?
    /// 开始 / 重置时间靠得住：服务器给的、手动指定的，或者按看到过的重置推的固定周期。
    /// Claude 的每周额度还没看到过重置时，是按第一次使用猜的（会偏晚），这时为 false，不看节奏
    public var scheduleKnown: Bool
    /// 这个窗口里网页、手机、桌面端聊天等其他端用了多少（已经包含在官方读数里，见 OtherUsage）
    public var otherPercent: Double
    /// 最近一段时间（burnLookback）的消耗速度，百分点 / 小时：本机 Claude Code + 官方读数里看出来的其他端
    public var burnPerHour: Double?
    /// burnPerHour 里其他端的部分
    public var otherBurnPerHour: Double?
    /// 消耗速度按多长时间算：5 小时窗口看最近 30 分钟，每周窗口看最近 24 小时
    public var burnLookback: TimeInterval

    public init(id: String, title: String, duration: TimeInterval, percent: Double,
                official: Double? = nil, officialAt: Date? = nil, limitReported: Bool = false, startedAt: Date? = nil,
                resetsAt: Date? = nil, scheduleKnown: Bool = true, otherPercent: Double = 0, burnPerHour: Double? = nil,
                otherBurnPerHour: Double? = nil, burnLookback: TimeInterval = 1800) {
        self.id = id
        self.title = title
        self.duration = duration
        self.percent = percent
        self.official = official
        self.officialAt = officialAt
        self.limitReported = limitReported
        self.startedAt = startedAt
        self.resetsAt = resetsAt
        self.scheduleKnown = scheduleKnown
        self.otherPercent = otherPercent
        self.burnPerHour = burnPerHour
        self.otherBurnPerHour = otherBurnPerHour
        self.burnLookback = burnLookback
    }

    /// 显示用，限制在 0...100
    public var clampedPercent: Double { min(max(percent, 0), 100) }

    /// 常见窗口的名字，跟着界面语言走（Claude、Codex、演示模式、预览图共用）
    public static var sessionTitle: String { tr("5 小时会话", "5-hour session") }
    public static var weeklyTitle: String { tr("本周额度", "Weekly quota") }

    /// 按窗口长度起名：5 小时会话 / 本周额度 / 30 天额度 / 2 小时额度…
    public static func title(minutes: Int) -> String {
        switch minutes {
        case 300: return sessionTitle
        case 10080: return weeklyTitle
        case let m where m % 1440 == 0: return tr("\(m / 1440) 天额度", "\(m / 1440)-day quota")
        case let m where m % 60 == 0: return tr("\(m / 60) 小时额度", "\(m / 60)-hour quota")
        default: return tr("\(minutes) 分钟额度", "\(minutes)-minute quota")
        }
    }

    /// 显示用的窗口名：按窗口 id 在当前界面语言下生成。快照里存的 title 是后台算快照时那一刻的语言，
    /// 切换语言后、下一次重算之前（或者提醒记录里留着的旧快照）可能还是旧语言，所以界面和通知都用这个
    public var displayTitle: String {
        switch id {
        case "five_hour": return Self.sessionTitle
        case "seven_day": return Self.weeklyTitle
        default:
            if id.hasPrefix("codex_"), id.hasSuffix("m"), let minutes = Int(id.dropFirst(6).dropLast()), minutes > 0 {
                return Self.title(minutes: minutes)
            }
            return title
        }
    }

    /// 实时估算比官方读数多出来的部分（没有官方读数时，整个百分比都是估算）
    public var estimatedExtra: Double { official.map { max(0, percent - $0) } ?? percent }

    /// 说消耗速度的单位：一天以上的窗口按天（每天 20%），5 小时窗口按小时（每小时 42%）
    public var burnUnit: TimeInterval { duration > 86400 ? 86400 : 3600 }

    /// 每个单位（burnUnit）用多少个百分点
    public func perUnit(_ perHour: Double) -> Double { perHour * burnUnit / 3600 }

    /// 照最近的消耗速度，会在重置之前的什么时候用完；来得及重置就返回 nil。
    /// 速度至少要每个单位 1%（5 小时窗口每小时 1%，每周额度每天 1%），太慢的不算。不知道重置时间时只看一个窗口长度以内
    public func projectedExhaustion(now: Date) -> Date? {
        guard let burn = burnPerHour, perUnit(burn) >= 1, percent < 100 else { return nil }
        let t = now.addingTimeInterval((100 - percent) / burn * 3600)
        if t >= resetsAt ?? now.addingTimeInterval(duration) { return nil }
        return t
    }

    /// 「快用完」预警提前多久：5 小时窗口提前半小时（窗口长度的 1/10），一天以上的窗口提前一天
    public var warningLead: TimeInterval { duration > 86400 ? 86400 : duration / 10 }

    /// 和平均节奏（整个窗口均匀地用完）比
    public struct Pace: Equatable, Sendable {
        /// 按平均节奏，现在应该用到多少
        public var expected: Double
        /// 比平均节奏多用了多少个百分点，少用是负数
        public var ahead: Double
        /// 剩下的额度平摊到重置前，每天能用多少；离重置不到一天时为 nil
        public var perDay: Double?
    }

    /// 一天以上的窗口（每周额度等）才看节奏，5 小时窗口是从第一次使用开始算的，一阵一阵地用，看节奏没意义。
    /// 窗口还没开始、重置时间不知道或者是猜的（scheduleKnown）、已经用完时为 nil
    public func pace(now: Date) -> Pace? {
        guard duration > 86400, percent < 100, scheduleKnown, let start = startedAt, let reset = resetsAt,
              now >= start, now < reset else { return nil }
        let expected = now.timeIntervalSince(start) / reset.timeIntervalSince(start) * 100
        let left = reset.timeIntervalSince(now)
        return Pace(expected: expected, ahead: percent - expected,
                    perDay: left >= 86400 ? (100 - percent) / (left / 86400) : nil)
    }
}

public struct FamilyUsage: Equatable, Sendable {
    public var family: String
    public var requests: Int
    public var usd: Double

    public init(family: String, requests: Int, usd: Double) {
        self.family = family
        self.requests = requests
        self.usd = usd
    }
}

/// 本机 Claude Code 今天的用量（按 API 价格折算）
public struct ActivitySummary: Equatable, Sendable {
    public var requests: Int
    public var tokens: Int
    public var usd: Double
    public var byFamily: [FamilyUsage]

    public init(requests: Int = 0, tokens: Int = 0, usd: Double = 0, byFamily: [FamilyUsage] = []) {
        self.requests = requests
        self.tokens = tokens
        self.usd = usd
        self.byFamily = byFamily
    }
}

/// 实时估算用的换算率：多少美元 API 用量 ≈ 1% 额度
public struct EstimationInfo: Equatable, Sendable {
    public var sessionUSDPerPercent: Double
    public var weeklyUSDPerPercent: Double
    /// 学习用到的区间数；0 表示记录还不够，在用起始值
    public var learnedIntervals: Int
    /// 一共记录了多少个区间
    public var recordedIntervals: Int
    /// 学到的数据截至什么时候
    public var learnedUntil: Date?

    public init(sessionUSDPerPercent: Double, weeklyUSDPerPercent: Double, learnedIntervals: Int,
                recordedIntervals: Int, learnedUntil: Date?) {
        self.sessionUSDPerPercent = sessionUSDPerPercent
        self.weeklyUSDPerPercent = weeklyUSDPerPercent
        self.learnedIntervals = learnedIntervals
        self.recordedIntervals = recordedIntervals
        self.learnedUntil = learnedUntil
    }
}

public struct UsageSnapshot: Equatable, Sendable {
    public var provider: ProviderID
    public var windows: [UsageWindow]
    public var generatedAt: Date
    /// 最近一次官方读数的时间
    public var officialAt: Date?
    public var today: ActivitySummary?
    /// 最近一次在本机用它是什么时候，不知道时为 nil（宠物看它判断是不是闲着）
    public var lastActiveAt: Date?
    /// 给用户看的数据说明 / 警告
    public var notes: [String]
    /// 一点数据都没有时为 false（宠物会显示疑惑）
    public var hasData: Bool
    /// 实时估算的换算率（演示模式等没有时为 nil）
    public var estimation: EstimationInfo?

    public init(provider: ProviderID, windows: [UsageWindow], generatedAt: Date, officialAt: Date? = nil,
                today: ActivitySummary? = nil, lastActiveAt: Date? = nil, notes: [String] = [], hasData: Bool = true,
                estimation: EstimationInfo? = nil) {
        self.provider = provider
        self.windows = windows
        self.generatedAt = generatedAt
        self.officialAt = officialAt
        self.today = today
        self.lastActiveAt = lastActiveAt
        self.notes = notes
        self.hasData = hasData
        self.estimation = estimation
    }

    public func window(_ id: String) -> UsageWindow? { windows.first { $0.id == id } }

    /// 用完了的窗口里最晚恢复的那个：几个都满了要等它。没有用完的，或者有一个不知道什么时候恢复时为 nil
    public var lastToRecover: UsageWindow? {
        let full = windows.filter { $0.percent >= 100 }
        guard full.allSatisfy({ $0.resetsAt != nil }) else { return nil }
        return full.max { ($0.resetsAt ?? .distantPast) < ($1.resetsAt ?? .distantPast) }
    }

    /// 最紧张的窗口，宠物的心情跟它走
    public var tightest: UsageWindow? { windows.max { $0.percent < $1.percent } }

    /// 面板和菜单栏上显示哪几家：Claude 一直显示（没数据时由它说明怎么回事），别的有数据、用户又没在设置里关掉（hidden）才出现
    public static func visible(_ snapshots: [UsageSnapshot], hidden: Set<ProviderID> = []) -> [UsageSnapshot] {
        snapshots.filter { $0.provider == .claude || ($0.hasData && !hidden.contains($0.provider)) }
    }

    /// 同时有几家的数据时，宠物和菜单栏跟着谁：有数据的里面最紧张的那家，一样紧张时排在前面的优先；
    /// 都没有数据时是第一家（由它说明为什么没数据）
    public static func focus(of snapshots: [UsageSnapshot]) -> UsageSnapshot? {
        var best: UsageSnapshot?
        for snapshot in snapshots where snapshot.hasData {
            let percent = snapshot.tightest?.percent ?? 0
            if best.map({ percent > ($0.tightest?.percent ?? 0) }) ?? true { best = snapshot }
        }
        return best ?? snapshots.first
    }
}

/// 一个 AI 的额度数据源。
/// snapshot 只会在同一个后台串行队列上调用，实现里可以放心保存增量读取的状态
/// （所以有可变状态的实现可以标 @unchecked Sendable）。
public protocol UsageProvider: AnyObject, Sendable {
    var id: ProviderID { get }
    /// 要监听的目录（FSEvents），里面相关的文件一变就刷新
    var watchPaths: [String] { get }
    /// 没有文件事件时的兜底刷新间隔
    var pollInterval: TimeInterval { get }
    func isRelevantChange(path: String) -> Bool
    func snapshot(now: Date) throws -> UsageSnapshot
}
