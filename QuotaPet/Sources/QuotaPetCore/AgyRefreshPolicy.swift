import Foundation

/// Scheduling only; never infers quota from local activity.
public struct AgyRefreshPolicy: Sendable {
    public static let interval: TimeInterval = 15 * 60
    public private(set) var selected = false
    public private(set) var sleeping = false
    public private(set) var inFlight = false
    private var lastAttempt: Date?

    public init() {}

    public mutating func select(_ selected: Bool) {
        if self.selected != selected { lastAttempt = nil }
        self.selected = selected
    }

    public mutating func setSleeping(_ sleeping: Bool) { self.sleeping = sleeping }

    public mutating func begin(now: Date) -> Bool {
        guard selected, !sleeping, !inFlight else { return false }
        if let lastAttempt, now.timeIntervalSince(lastAttempt) >= 0,
           now.timeIntervalSince(lastAttempt) < Self.interval { return false }
        lastAttempt = now
        inFlight = true
        return true
    }

    /// 手动刷新的最短间隔：连点不会反复启动官方 CLI
    public static let manualGap: TimeInterval = 30

    /// 用户点了刷新：不等 15 分钟，但离上次开始读至少 manualGap，且不和正在进行的读取并发
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
        guard let lastAttempt else { return Self.interval }
        return max(1, Self.interval - max(0, now.timeIntervalSince(lastAttempt)))
    }

    public mutating func finish() { inFlight = false }
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
