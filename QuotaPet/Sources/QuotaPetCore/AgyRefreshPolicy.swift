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
