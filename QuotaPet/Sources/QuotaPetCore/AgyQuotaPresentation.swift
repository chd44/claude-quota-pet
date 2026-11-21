import Foundation

/// A quota may drive artwork only while the official reading is complete and fresh.
public struct AgyQuotaPresentation: Sendable {
    /// One official window as the panel shows it. A window past its own reset is unknown.
    public struct WindowState: Equatable, Sendable, Identifiable {
        public var id: String { group + " · " + window }
        public let group: String
        public let window: String
        public let usedPercent: Double?
        public let remainingPercent: Double?
        public let resetsAt: Date?
        public let isTightest: Bool
        public var title: String { AgyQuotaPresentation.label(group: group, window: window) }
    }

    public let usedPercent: Double?
    public let validUntil: Date?
    /// Every window of a fresh, complete reading in official order; empty when unknown.
    public let windows: [WindowState]
    public func nextUpdateDelay(defaultDelay: TimeInterval, now: Date) -> TimeInterval {
        // Any window reaching its own reset turns that card unknown, so wake then too.
        let changes = ([validUntil] + windows.map(\.resetsAt)).compactMap { $0 }.filter { $0 > now }
        guard let next = changes.min() else { return defaultDelay }
        return min(defaultDelay, next.timeIntervalSince(now))
    }

    public static func scopeLabel(_ reading: AgyQuotaReading) -> String {
        let group = reading.groupTitle ?? reading.groupName ?? "agy"
        guard let window = reading.windowTitle else { return group }
        return label(group: group, window: window)
    }

    public static func label(group: String, window: String) -> String {
        let label: String
        switch window {
        case "每周", "weekly": label = tr("每周窗口", "weekly window")
        case "五小时", "five_hour": label = tr("五小时窗口", "5-hour window")
        default: label = window
        }
        return group + " · " + label
    }
    public var mood: PetMood { usedPercent.map(PetMood.from(percent:)) ?? .normal }

    /// agy 以 Gemini 这一组为准（用户指定）：取这组里用得最多、且还没过重置点的窗口。
    /// 官方面板里没有 Gemini 组时退回所有窗口里最紧张的那个
    public static let primaryGroup = "Gemini"

    public var primaryWindow: WindowState? {
        let group = windows.filter { $0.group == Self.primaryGroup }
        guard !group.isEmpty else { return usedPercent == nil ? nil : windows.first(where: \.isTightest) }
        return group.filter { $0.usedPercent != nil }.max { ($0.usedPercent ?? 0) < ($1.usedPercent ?? 0) }
    }

    /// 菜单栏数字、切换条、宠物表情都用它
    public var primaryUsedPercent: Double? { primaryWindow?.usedPercent }
    public var primaryMood: PetMood { primaryUsedPercent.map(PetMood.from(percent:)) ?? .normal }

    /// agy 宠物的表情：额度档位之外，再看读取状态和最近几次读数的变化（只用官方读数，不推算额度）。
    /// - 第一次读取中：醒过来中；读不到（要登录、CLI 不可用、版式变了）：有点懵
    /// - 快用完 / 用完：照档位（快撑不住、睡着）
    /// - 一小时内最紧张的窗口回落 40 点以上：刚恢复
    /// - 半小时到一小时内涨了 15 点以上：有点慌
    /// - 一个半小时以上没变化：歇着呢
    public static func trendMood(reading: AgyQuotaReading?, history: [AgyQuotaReading], querying: Bool, now: Date) -> PetMood {
        let current = AgyQuotaPresentation(reading: reading, now: now)
        guard let used = current.primaryUsedPercent, let reading else {
            if reading == nil { return querying ? .loading : .normal }
            return reading?.status == .available ? .normal : .confused
        }
        let tier = PetMood.from(percent: used)
        if used >= 90 { return tier }
        let past = history.filter { $0.checkedAt < reading.checkedAt && reading.checkedAt.timeIntervalSince($0.checkedAt) <= 3 * 3600 }
            .compactMap { old in AgyQuotaPresentation(reading: old, now: old.checkedAt).primaryUsedPercent.map { (old.checkedAt, $0) } }
        let age = { (time: Date) in reading.checkedAt.timeIntervalSince(time) }
        if used < 50, past.contains(where: { age($0.0) <= 3600 && $0.1 >= 60 && $0.1 - used >= 40 }) { return .revived }
        if used >= 40, past.contains(where: { (1800...3600).contains(age($0.0)) && used - $0.1 >= 15 }) { return .nervous }
        if tier == .tired { return tier }
        if let oldest = past.first, age(oldest.0) >= 5400, past.allSatisfy({ abs($0.1 - used) < 0.5 }) { return .resting }
        return tier
    }
    public init(reading: AgyQuotaReading?, now: Date = Date()) {
        guard let reading, reading.status == .available,
              let remaining = reading.remainingPercent, remaining.isFinite, (0...100).contains(remaining),
              reading.groupName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              (0..<AgyRefreshPolicy.interval).contains(now.timeIntervalSince(reading.checkedAt)) else {
            usedPercent = nil
            validUntil = nil
            windows = []
            return
        }
        let tightestIndex = reading.windows.firstIndex {
            $0.group + " · " + $0.window == reading.groupName && $0.remainingPercent == remaining
        }
        // Readings built without the full list still describe their tightest window.
        let listed = reading.windows.isEmpty
            ? [AgyQuotaReading.Window(group: reading.groupTitle ?? reading.groupName ?? "agy",
                                      window: reading.windowTitle ?? "", remainingPercent: remaining, resetsAt: reading.resetsAt)]
            : reading.windows
        windows = listed.enumerated().map { index, window in
            let valid = window.remainingPercent.isFinite && (0...100).contains(window.remainingPercent)
                && (window.resetsAt.map { now < $0 } ?? true)
            return WindowState(group: window.group, window: window.window,
                               usedPercent: valid ? 100 - window.remainingPercent : nil,
                               remainingPercent: valid ? window.remainingPercent : nil,
                               resetsAt: window.resetsAt, isTightest: reading.windows.isEmpty || index == tightestIndex)
        }
        let deadline = min(reading.checkedAt.addingTimeInterval(AgyRefreshPolicy.interval), reading.resetsAt ?? .distantFuture)
        guard now < deadline else {
            usedPercent = nil
            validUntil = nil
            return
        }
        validUntil = deadline
        usedPercent = 100 - remaining
    }
}

/// The number beside the menu-bar pet: the tightest official used percentage, only when it is reliable.
public enum MenuBarPercent {
    public static func text(usedPercent: Double?, mode: MenuBarTextMode) -> String? {
        guard mode != .petOnly, let used = usedPercent, used.isFinite else { return nil }
        return Fmt.percent(min(max(used, 0), 100))
    }
}

extension AgyQuotaPresentation.WindowState {
    /// 窗口长度：官方面板写明的每周 / 五小时
    public var duration: TimeInterval? {
        switch window {
        case "每周": return 7 * 86400
        case "五小时": return 5 * 3600
        default: return nil
        }
    }

    /// 平均节奏：只用官方给的重置时间和固定的窗口长度推出这一周的起点，不估算用量。
    /// 和旧版一样只对一天以上的窗口（每周）有；没有重置时间、已经过了重置点时没有
    public func pace(now: Date) -> UsageWindow.Pace? {
        guard let used = usedPercent, let reset = resetsAt, let duration else { return nil }
        return UsageWindow(id: id, title: title, duration: duration, percent: used, official: used,
                           startedAt: reset.addingTimeInterval(-duration), resetsAt: reset, scheduleKnown: true).pace(now: now)
    }
}
