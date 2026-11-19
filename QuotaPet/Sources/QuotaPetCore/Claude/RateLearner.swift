import Foundation

/// 从区间记录里学「多少美元的额度加权花费 ≈ 1% 额度」。
///
/// 换算率 = Σ 权重 × 本机额度加权花费 ÷ Σ 权重 × 官方增量：
/// - 只用本机确实在用（≥ $0.02）、中间没有重置的区间；纯网页端的区间没有本机花费，自动排除。
///   同时在其他端用过、官方涨得明显比本机多的区间，以及旧版本记下的、没有缓存读花费的区间也不用。
/// - 越近的区间权重越大（半衰期 3 小时）：同一个会话里换算率也会慢慢变，要跟得上；两天以前的不再算。
///   回测（usage_lab.py backtest）：半衰期 3 小时比 2 天的误差小，往回跳的次数也少。
///   时间从最近一个区间往前算，隔几天不用也不会把学到的忘掉。
/// - 加一点默认值当先验（相当于 $2 的数据），刚开始记录少时不会乱跳。
/// 官方读数是整数，单个区间误差大，但求和时误差会互相抵消。
public enum RateLearner {
    public struct Result: Equatable, Sendable {
        public var usdPerPercent: Double
        /// 用到了多少个区间；0 表示还在用默认值
        public var intervals: Int
        /// 最近一个用到的区间的结束时间
        public var latest: Date?
    }

    public static func learn(_ intervals: [UsageInterval], delta: (UsageInterval) -> Double?, prior: Double,
                             priorUSD: Double = 2, halfLife: TimeInterval = 3 * 3600) -> Result {
        typealias Item = (end: Date, usd: Double, delta: Double)
        var usable: [Item] = intervals.compactMap { interval in
            guard interval.usd >= 0.02, let usd = interval.quotaUSD, let d = delta(interval) else { return nil }
            return (interval.end, usd, d)
        }
        guard let latest = usable.map(\.end).max() else {
            return Result(usdPerPercent: prior, intervals: 0, latest: nil)
        }
        // 16 个半衰期以前的区间，权重不到十万分之二，不用再算（记录只追加，会越来越多）
        usable = usable.filter { latest.timeIntervalSince($0.end) < 16 * halfLife }
        func weight(_ end: Date) -> Double { pow(0.5, latest.timeIntervalSince(end) / halfLife) }

        func fit(_ items: [Item]) -> Double {
            var cost = priorUSD
            var gained = priorUSD / prior
            for item in items {
                cost += weight(item.end) * item.usd
                gained += weight(item.end) * item.delta
            }
            return gained > 0 ? cost / gained : prior
        }

        /// 每段「花费 ÷ 官方增量」按权重（时间衰减 × 本机花费）取中位数，不到一半的混用区间拉不动它。
        /// 按花费加权而不是按增量：混用的区间增量偏大，按增量加权会偏向它们。官方没涨的段算无穷大
        func median(_ items: [Item]) -> Double? {
            let points = items.map { (rate: $0.delta > 0 ? $0.usd / $0.delta : .infinity, weight: weight($0.end) * $0.usd) }
                .sorted { $0.rate < $1.rate }
            let half = points.reduce(0) { $0 + $1.weight } / 2
            var sum = 0.0
            for point in points {
                sum += point.weight
                if sum >= half { return point.rate.isFinite ? point.rate : nil }
            }
            return nil
        }

        // 同时在网页 / 手机上用过的区间，官方涨得比本机花费能解释的多一截，不能拿来学。先用中位数挑出这种区间，
        // 再用剩下的区间学到的换算率重新挑，直到挑出来的不再变：最后和面板算其他端（OtherUsage）用的是同一个换算率、同一个规则
        var rate = median(usable) ?? fit(usable)
        var mixed: [Bool] = []
        // 换算率越高挑出来的越多、挑掉的越多换算率越高，是单调的，最多 usable.count + 1 轮一定停（一般一两轮）
        for _ in 0...usable.count {
            let flags = usable.map { OtherUsage.isOther(excess: $0.delta - $0.usd / rate, local: $0.usd / rate) }
            if flags == mixed { break }
            mixed = flags
            let clean = zip(usable, flags).filter { !$0.1 }.map(\.0)
            if !clean.isEmpty { rate = fit(clean) }
        }
        // 挑完一个有效的区间都没剩（只有的那几段全是混用的）：rate 是挑掉之前学到的，不能用，回到起始值。
        // 这样「用到了 0 个区间」和「换算率是起始值」永远是一回事
        let clean = mixed.filter { !$0 }.count
        guard clean > 0 else { return Result(usdPerPercent: prior, intervals: 0, latest: nil) }
        return Result(usdPerPercent: min(max(rate, prior / 10), prior * 10), intervals: clean, latest: latest)
    }
}
