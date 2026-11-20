import Foundation

// 面板顶部先说什么（PanelHeadline），和一家用完了时让用户去看另一家（RelayOffer）。
// 都是纯逻辑，时间由调用方传入：面板每次重画用同一个 now 算，重置时间一到就会收起。

extension UsageWindow {
    /// 已确认用完：属于当前窗口、仍有效的官方 100% 读数（限流消息也算一次 100%，见 limitReported）。
    /// 估算和预测不算；已知重置时间到了也不算：额度已经恢复，只是快照还没来得及重算
    public func isConfirmedFull(now: Date) -> Bool {
        guard (official ?? 0) >= 100, percent >= 100 else { return false }
        if let resetsAt, resetsAt <= now { return false }
        return true
    }

    /// 说「这个额度」时的名字：5 小时窗口叫「5 小时额度」（displayTitle 里是「5 小时会话」），别的照 displayTitle
    public var quotaName: String {
        id == "five_hour" ? tr("5 小时额度", "5-hour quota") : displayTitle
    }

    /// 摘要里用的短名字
    var shortName: String {
        switch id {
        case "five_hour": return tr("5 小时", "5h")
        case "seven_day": return tr("本周", "Week")
        default: return displayTitle
        }
    }
}

extension ProviderID {
    /// 官方读数多久没来算过期。和面板底部、Codex 的提醒是同一个标准（ClaudeProvider.staleAfter、CodexProvider.staleAfter），比较方向也照它们：
    /// Claude 满 45 分钟算停了，Codex 超过 1 小时才算
    public func isOfficialStale(age: TimeInterval) -> Bool {
        switch self {
        case .claude: return age >= ClaudeProvider.staleAfter
        case .codex: return age > CodexProvider.staleAfter
        }
    }
}

extension UsageSnapshot {
    /// 已确认用完的窗口（见 UsageWindow.isConfirmedFull）
    public func confirmedFull(now: Date) -> [UsageWindow] { windows.filter { $0.isConfirmedFull(now: now) } }

    /// 最近一次官方样本的时间（取各窗口的官方读数时间里最晚的）：新鲜度只看它，不看 generatedAt，
    /// 后台刚重算过也不会让旧读数变新。没有属于当前窗口的官方读数时为 nil
    public var officialReadAt: Date? { windows.compactMap(\.officialAt).max() }
}

/// 面板上看哪一家：用户（或宠物）选的那家；它不在显示的几家里（比如 Codex 的记录过期了、被关掉了）就回到宠物跟着的那家
public enum PanelSelection {
    public static func resolve(shown: [UsageSnapshot], requested: ProviderID, focus: ProviderID?) -> ProviderID {
        shown.contains { $0.provider == requested } ? requested : focus ?? .claude
    }
}

/// 打开面板时，宠物旁边先给出的一条最有用的信息，和下面一行读数来源 / 时间
public struct PanelHeadline: Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// 已确认用完：卡住的窗口和恢复时间
        case blocked
        /// 照最近的速度会在重置前用完
        case forecast
        /// 官方读数过期了
        case stale
        /// 没有官方读数，只有本机估算
        case estimated
        /// 平稳：当前额度概况
        case steady
    }

    public var kind: Kind
    public var text: String
    public var detail: String?

    /// 没有数据（还在读、读取出错、这家没数据）时是 nil，由宠物那句话和下面的说明讲
    public static func of(_ snapshot: UsageSnapshot?, now: Date, calendar: Calendar = .current) -> PanelHeadline? {
        guard let snapshot, snapshot.hasData, !snapshot.windows.isEmpty else { return nil }

        // 1. 已确认用完：说卡住的窗口和恢复时间，几个都满了等最晚恢复的那个，有一个不知道就说不知道
        let blocked = snapshot.confirmedFull(now: now)
        if !blocked.isEmpty {
            let recovery: String
            var decisive = blocked[0]
            if blocked.allSatisfy({ $0.resetsAt != nil }), let last = blocked.max(by: { ($0.resetsAt ?? .distantPast) < ($1.resetsAt ?? .distantPast) }),
               let back = last.resetsAt {
                recovery = tr("约 \(Fmt.clock(back, now: now, calendar: calendar)) 恢复", "back around \(Fmt.clock(back, now: now, calendar: calendar))")
                decisive = last
            } else {
                recovery = tr("恢复时间未知", "recovery time unknown")
                decisive = blocked.first { $0.resetsAt == nil } ?? decisive
            }
            let names = blocked.map(\.quotaName)
            let text = blocked.count == 1
                ? tr("\(names[0])已用完 · \(recovery)", "\(names[0]) used up · \(recovery)")
                : tr("\(names.joined(separator: "、"))都已用完 · \(recovery)", "\(names.joined(separator: " and ")) all used up · \(recovery)")
            return PanelHeadline(kind: .blocked, text: text, detail: blockedSource(decisive, now: now))
        }

        // 2. 有耗尽预测：和额度卡上那行火焰是同一个判断（UsageWindow.projectedExhaustion），取最早的
        let ending = snapshot.windows.compactMap { window in window.projectedExhaustion(now: now).map { (window: window, at: $0) } }
            .min { $0.at < $1.at }
        if let ending {
            return PanelHeadline(
                kind: .forecast,
                text: tr("\(ending.window.quotaName)预计 \(Fmt.clock(ending.at, now: now, calendar: calendar)) 用完",
                         "\(ending.window.quotaName) should run out around \(Fmt.clock(ending.at, now: now, calendar: calendar))"),
                detail: readingLine(ending.window, now: now))
        }

        // 3. 过期、缺官方读数、平稳
        let summary = Self.summary(snapshot)
        guard let readAt = snapshot.officialReadAt else {
            return PanelHeadline(kind: .estimated,
                                 text: tr("暂无官方读数 · 以下为本机估算", "No official reading · local estimates"),
                                 detail: summary)
        }
        if snapshot.provider.isOfficialStale(age: now.timeIntervalSince(readAt)) {
            let hint = snapshot.provider == .claude
                ? tr("含本机估算，可能有偏差", "includes local estimates, may be off")
                : tr("网页、云端任务的用量还没记进来", "web and cloud usage isn't logged yet")
            return PanelHeadline(kind: .stale,
                                 text: tr("上次官方读数 · \(Fmt.ago(readAt, now: now))", "Last official reading · \(Fmt.ago(readAt, now: now))"),
                                 detail: "\(summary) · \(hint)")
        }
        return PanelHeadline(kind: .steady, text: summary, detail: snapshot.tightest.flatMap { readingLine($0, now: now) })
    }

    /// 各窗口的概况：5 小时 27% · 本周 25%
    static func summary(_ snapshot: UsageSnapshot) -> String {
        snapshot.windows.map { "\($0.shortName) \(Fmt.percent($0.clampedPercent))" }.joined(separator: " · ")
    }

    /// 一个窗口的读数来源和时间：官方 52% · 9 分钟前 · 本机估算 +6 个百分点；没有官方读数时说明是本机估算
    static func readingLine(_ window: UsageWindow, now: Date) -> String {
        guard let official = window.official, let at = window.officialAt else {
            return tr("本机估算 约 \(Fmt.percent(window.clampedPercent)) · 暂无官方读数",
                      "Local estimate ~\(Fmt.percent(window.clampedPercent)) · no official reading")
        }
        var line = tr("官方 \(Fmt.percent(official)) · \(Fmt.ago(at, now: now))", "Official \(Fmt.percent(official)) · \(Fmt.ago(at, now: now))")
        let extra = Int(window.estimatedExtra.rounded())
        if window.estimatedExtra >= 0.5, extra >= 1 {
            line += tr(" · 本机估算 +\(extra) 个百分点", " · local estimate +\(plural(extra, "point"))")
        }
        return line
    }

    /// 用完了的窗口的读数来源：官方读数，或 Claude Code 的限流消息
    private static func blockedSource(_ window: UsageWindow, now: Date) -> String? {
        guard let at = window.officialAt else { return nil }
        return window.limitReported
            ? tr("Claude Code 限流消息 · \(Fmt.ago(at, now: now))", "Claude Code limit message · \(Fmt.ago(at, now: now))")
            : tr("官方读数 100% · \(Fmt.ago(at, now: now))", "Official reading 100% · \(Fmt.ago(at, now: now))")
    }
}

/// 双宠接力：正在看的这一家有窗口确认用完了，另一家还能用时，提示去看另一家
public struct RelayOffer: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// 另一家读数新鲜、所有窗口都没满：显示接力台词和按钮。topPercent 是它最高的已用比例，readAt 是官方读数的时间
        case ready(topPercent: Double, readAt: Date)
        /// 另一家读数过期了：只显示读数有多旧，不说台词、不给按钮
        case stale(readAt: Date)
    }

    public var provider: ProviderID
    public var state: State

    /// viewing：正在看的那家；shown：面板上显示的几家（已经去掉了隐藏的、没数据的），只有一家时没有接力。
    /// 另一家没有官方读数、没数据、也用完了（含读数过期但已满）时返回 nil，接力区域收起
    public static func of(viewing: UsageSnapshot?, shown: [UsageSnapshot], now: Date) -> RelayOffer? {
        guard let viewing, !viewing.confirmedFull(now: now).isEmpty else { return nil }
        var stale: RelayOffer?
        for other in shown where other.provider != viewing.provider {
            guard other.hasData, !other.windows.isEmpty, let readAt = other.officialReadAt else { continue }
            // 也用完了：不管读数新旧都收起（没有可以接力的）
            if other.windows.contains(where: { $0.percent >= 100 || $0.isConfirmedFull(now: now) }) { continue }
            if other.provider.isOfficialStale(age: now.timeIntervalSince(readAt)) {
                stale = stale ?? RelayOffer(provider: other.provider, state: .stale(readAt: readAt))
                continue
            }
            return RelayOffer(provider: other.provider, state: .ready(topPercent: other.tightest?.clampedPercent ?? 0, readAt: readAt))
        }
        return stale
    }

    public var name: String { provider.displayName }

    /// 另一只宠物说的话
    public var line: String { tr("她先歇会儿，这边我帮你看着。", "She's resting. I've got this side covered.") }

    /// 台词下面一行：另一家最高已用多少、读数多新
    public func detail(now: Date) -> String? {
        guard case .ready(let top, let readAt) = state else { return nil }
        return tr("\(name) 最高已用 \(Fmt.percent(top)) · 官方读数 \(Fmt.ago(readAt, now: now))",
                  "\(name) at \(Fmt.percent(top)) · official reading \(Fmt.ago(readAt, now: now))")
    }

    public var buttonTitle: String { tr("查看 \(name)", "View \(name)") }

    /// 读数过期时接力位置唯一的一行：Codex · 上次读数 2 小时前
    public func staleText(now: Date) -> String? {
        guard case .stale(let readAt) = state else { return nil }
        return tr("\(name) · 上次读数 \(Fmt.ago(readAt, now: now))", "\(name) · last reading \(Fmt.ago(readAt, now: now))")
    }
}
