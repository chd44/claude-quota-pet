import Foundation

/// Scheduling only; never infers quota from local activity.
public struct AgyRefreshPolicy: Sendable {
    /// 读数的有效期（超过即未知，绝不放宽）
    public static let validity: TimeInterval = 15 * 60
    public static let interval: TimeInterval = validity
    /// 定时读取的间隔：在 15 分钟有效期结束前提前 3 分钟发起，偶发失败后能在过期前重试一次
    public static let refreshInterval: TimeInterval = 12 * 60
    public private(set) var selected = false
    public private(set) var sleeping = false
    public private(set) var inFlight = false
    private var lastAttempt: Date?
    private var lastFailureAt: Date?
    /// 连续读失败的次数；读到可用读数就清零
    public private(set) var failures = 0

    /// 读失败后第一次重试的间隔，之后每次翻倍，最长回到 refreshInterval
    public static let retryBase: TimeInterval = 60

    /// 一次查询最长等多久：探测本身最长 45 秒加几秒收尾，超过这个就当卡住了放弃
    public static let queryTimeout: TimeInterval = 2 * 60

    /// 因睡眠或切走而被取消的查询，最多再等这么久就释放并发占位
    public static let cancelledTimeout: TimeInterval = 15

    /// 唤醒后先等系统 Wi-Fi / DNS 恢复再发起首次查询
    public static let wakeDelay: TimeInterval = 6

    /// 网络从断开恢复时触发快速重试的最短间隔
    public static let networkRecoveryGap: TimeInterval = 15

    public init() {}

    /// 下一次定时读取离上次开始（或失败）的间隔：正常 12 分钟；刚失败过就 1、2、4、8 分钟后重试，最长回到 12 分钟
    public var dueInterval: TimeInterval {
        guard failures > 0 else { return Self.refreshInterval }
        return min(Self.refreshInterval, Self.retryBase * pow(2, Double(min(failures, 8) - 1)))
    }

    private var scheduleAnchor: Date? { failures > 0 ? (lastFailureAt ?? lastAttempt) : lastAttempt }

    public mutating func select(_ selected: Bool) {
        if self.selected != selected {
            lastAttempt = nil
            lastFailureAt = nil
            failures = 0
        }
        self.selected = selected
    }

    public mutating func setSleeping(_ sleeping: Bool) { self.sleeping = sleeping }

    public mutating func begin(now: Date) -> Bool {
        guard selected, !sleeping, !inFlight else { return false }
        if let anchor = scheduleAnchor, now.timeIntervalSince(anchor) >= 0,
           now.timeIntervalSince(anchor) < dueInterval { return false }
        lastAttempt = now
        inFlight = true
        return true
    }

    /// 断网恢复时：之前读失败过且当前没在读，隔开防抖时间后立即重试一次
    public mutating func beginOnNetworkRecovery(now: Date) -> Bool {
        guard selected, !sleeping, !inFlight, failures > 0 else { return false }
        if let recent = [lastAttempt, lastFailureAt].compactMap({ $0 }).max(),
           now.timeIntervalSince(recent) >= 0,
           now.timeIntervalSince(recent) < Self.networkRecoveryGap { return false }
        lastAttempt = now
        inFlight = true
        return true
    }

    /// 手动刷新的最短间隔：连点不会反复启动官方 CLI
    public static let manualGap: TimeInterval = 30

    /// 手动刷新还要等几秒（离上次开始读不到 manualGap 时）；不用等时是 nil
    public func manualWait(now: Date) -> TimeInterval? {
        guard let lastAttempt else { return nil }
        let since = now.timeIntervalSince(lastAttempt)
        guard since >= 0, since < Self.manualGap else { return nil }
        return Self.manualGap - since
    }

    /// 用户点了刷新：不等定时周期，但离上次开始读至少 manualGap，且不和正在进行的读取并发
    public mutating func beginManual(now: Date) -> Bool {
        guard selected, !sleeping, !inFlight else { return false }
        if let lastAttempt, now.timeIntervalSince(lastAttempt) >= 0, now.timeIntervalSince(lastAttempt) < Self.manualGap { return false }
        lastAttempt = now
        inFlight = true
        return true
    }

    /// 检测到 Claude Code 在干活（对话文件有写入）时自动读：活动停下 activityQuiet 后读一次，连续干活时最多每 activityGap 一次
    public static let activityQuiet: TimeInterval = 45
    public static let activityGap: TimeInterval = 180

    public mutating func beginActivity(now: Date) -> Bool {
        guard selected, !sleeping, !inFlight else { return false }
        if let lastAttempt, now.timeIntervalSince(lastAttempt) >= 0, now.timeIntervalSince(lastAttempt) < Self.activityGap { return false }
        lastAttempt = now
        inFlight = true
        return true
    }

    public func delayUntilDue(now: Date) -> TimeInterval {
        guard let anchor = scheduleAnchor else { return Self.refreshInterval }
        return max(1, dueInterval - max(0, now.timeIntervalSince(anchor)))
    }

    /// 一次读取结束；usable：读到了可用的额度。nil：读取作废（切走、睡眠），不算成败
    public mutating func finish(usable: Bool? = nil, now: Date? = nil) {
        inFlight = false
        guard let usable else { return }
        if usable {
            failures = 0
            lastFailureAt = nil
        } else {
            failures += 1
            lastFailureAt = now ?? lastAttempt
        }
    }

    /// 新一次读取没读到可靠读数（status 是未知：超时、面板没出来、版式没认出）时，
    /// 上一次可用读数还在有效期内就继续显示它，不让一次偶发失败把还能用的数字换成「额度未知」。
    /// 明确的状态（要登录、要确认、没装 CLI）照常替换：那是现在的真实情况
    public static func keepsPrevious(previousUsable: Bool, previousCheckedAt: Date?, newUsable: Bool, newIsUnknown: Bool, now: Date) -> Bool {
        guard !newUsable, newIsUnknown, previousUsable, let previousCheckedAt else { return false }
        return (0..<validity).contains(now.timeIntervalSince(previousCheckedAt))
    }
}

/// Claude Code 干活后的自动读取：每次检查时做什么
public enum ActivityRefresh {
    public enum Step: Equatable, Sendable {
        /// 什么都不做，下次再看
        case wait
        /// 去读一次（被限频拒绝也继续等，不丢）
        case refresh
        /// 活动之后已经读到新读数，这一轮结束
        case done
    }

    public static let checkEvery: TimeInterval = 15

    public static func step(now: Date, lastActivity: Date, latestReadingAt: Date?, querying: Bool) -> Step {
        if let latest = latestReadingAt, latest > lastActivity, now.timeIntervalSince(lastActivity) >= AgyRefreshPolicy.activityQuiet {
            return .done
        }
        if querying { return .wait }
        if now.timeIntervalSince(lastActivity) >= AgyRefreshPolicy.activityQuiet { return .refresh }
        // 一直在干活：离上次读数够久也读一次
        if let latest = latestReadingAt, now.timeIntervalSince(latest) < AgyRefreshPolicy.activityGap { return .wait }
        return .refresh
    }
}
