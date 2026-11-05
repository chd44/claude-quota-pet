import Foundation

/// 文件事件触发的重算怎么限频（UsageStore 用，放在 Core 里是为了能进自检）。
/// Claude Code 干活时日志大约每秒写一次，每次都把日志目录整个走一遍、把快照整个重算一遍太费电；
/// 同一家隔几秒算一次，数字照样跟得上。每分钟的兜底刷新、手动刷新、改设置不受它管
public struct RefreshThrottle: Sendable {
    /// 同一家两次文件触发的重算至少隔这么久
    public var minInterval: TimeInterval
    private var lastStarted: [ProviderID: Date] = [:]

    public init(minInterval: TimeInterval = 5) {
        self.minInterval = minInterval
    }

    /// 这一家的文件变了，过多久开始重算：至少等 debounce（连着来的一串事件合并成一次），
    /// 离上一次文件触发的重算也要隔够 minInterval
    public func delay(for id: ProviderID, now: Date, debounce: TimeInterval) -> TimeInterval {
        let cooldown = lastStarted[id].map { $0.addingTimeInterval(minInterval).timeIntervalSince(now) } ?? 0
        return max(debounce, cooldown)
    }

    /// 这一家因为文件事件开始重算了
    public mutating func started(_ id: ProviderID, at time: Date) {
        lastStarted[id] = time
    }
}
