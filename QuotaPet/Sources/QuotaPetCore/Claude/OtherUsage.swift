import Foundation

/// 其他端用量：官方读数涨了、本机 Claude Code 日志却解释不了的部分，也就是网页、手机、桌面端聊天等的用量。
///
/// 按相邻两次官方读数逐段算「官方增量 − 这段时间本机请求的估算」。官方读数是整数、估算也有误差，所以：
/// - 这段时间里（连同开始前 5 分钟，服务器计数可能慢一点）本机一个请求都没有：官方涨多少都算其他端；
/// - 否则要多出 threshold 以上才算，免得把取整和估算误差当成其他端；
/// - 服务器计数慢一点（lag）：读数前不久的请求，这次读数可能还没算上、下一次读数才涨。这种「官方还没算到的本机用量」
///   记成 credit，带到下一段抵掉；一笔本机用量最多抵一次（用掉就没了），也只在读数前 lag 以内的请求才有。
/// 用真实数据看过：只用 Claude Code 的时段里，逐段的差值都在这个门槛以内。
public enum OtherUsage {
    public struct Segment: Equatable, Sendable {
        public var start: Date
        public var end: Date
        /// 这一段里其他端用了多少个百分点
        public var percent: Double
    }

    /// 本机有请求时，官方增量要比本机估算多出这么多才算其他端：取整误差 ±1，估算误差约 20%。
    /// 与 usage_lab.py 的 OTHER_THRESHOLD 一致
    public static func threshold(local: Double) -> Double { 2 + 0.2 * local }

    /// 官方增量比本机估算多出 excess，算不算其他端用量。nearby：这段时间里（连同开始前 lag）本机有没有请求。
    /// 学换算率时挑混用的区间也用它，两边的规则一致
    static func isOther(excess: Double, local: Double, nearby: Bool = true) -> Bool {
        excess > (nearby ? threshold(local: local) : 0.5)
    }

    /// 服务器计数可能比请求慢一点：这么久以内的本机请求，也可能算进下一段
    static let lag: TimeInterval = 5 * 60

    /// 从 start（那时读数是 startValue）往后，逐段比较 readings（按时间排序，都在 start 之后）。
    /// start 是窗口开始时（0），开启窗口的那个请求也算进第一段。requests 按时间排序，percentOf 把一个请求换算成这个窗口的百分点
    static func segments(start: Date, startValue: Double = 0, readings: [UsageSample], requests: [ClaudeRequest],
                         percentOf: (ClaudeRequest) -> Double) -> [Segment] {
        var result: [Segment] = []
        var from = start
        var high = startValue  // 读数偶尔会往回掉一点（取整），按最高的算，免得回升时被当成新用量
        var credit = 0.0  // 上一段读数前 lag 以内、官方还没算到的本机用量，在这一段抵掉
        var lo = 0
        for reading in readings where reading.time > from {  // 时间戳重复的读数跳过，不然会出现长度为 0 的段
            while lo < requests.count, requests[lo].time <= from.addingTimeInterval(-lag) { lo += 1 }
            var local = 0.0
            var recent = 0.0  // local 里读数前 lag 以内的部分：官方可能还没算到
            var nearby = false
            var i = lo
            while i < requests.count, requests[i].time <= reading.time {
                nearby = true
                // 第一段包含开启窗口的那个请求
                if requests[i].time > from || (from == start && requests[i].time == start) {
                    let cost = percentOf(requests[i])
                    local += cost
                    if requests[i].time > reading.time.addingTimeInterval(-lag) { recent += cost }
                }
                i += 1
            }
            let attributed = local + credit  // 这一段里本机用量的总数：本段的请求，加上上一段迟到、这次才算上的
            let gained = reading.value - high
            let excess = gained - attributed
            if isOther(excess: excess, local: attributed, nearby: nearby) {
                result.append(Segment(start: from, end: reading.time, percent: excess))
            }
            // 官方涨得比本机用量少：差的那部分如果是读数前 lag 以内的请求，多半是服务器还没算到，留给下一段；
            // 本段已经用掉的 credit 不再往后带（一笔只抵一次），所以上限是 recent
            credit = min(recent, max(0, attributed - max(0, gained)))
            from = reading.time
            high = max(high, reading.value)
        }
        return result
    }

    /// [from, now] 这段时间里其他端每小时用多少个百分点，和本机的消耗速度一样按整段时间平均。
    /// 最近一次官方读数之后的其他端用量还看不到，按 0 算；跨过 from 的段按时间比例摊；时间太短时至少按 minSpan 算
    static func burnPerHour(_ segments: [Segment], from: Date, now: Date, minSpan: TimeInterval) -> Double {
        var sum = 0.0
        for s in segments where s.end > from {
            sum += s.percent * s.end.timeIntervalSince(max(s.start, from)) / s.end.timeIntervalSince(s.start)
        }
        return sum * 3600 / max(now.timeIntervalSince(from), minSpan)
    }
}
