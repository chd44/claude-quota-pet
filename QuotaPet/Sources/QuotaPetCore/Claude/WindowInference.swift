import Foundation

/// 某个窗口（5 小时 / 每周）的一条官方读数
public struct UsageSample: Equatable, Sendable {
    public var time: Date
    public var value: Double

    public init(time: Date, value: Double) {
        self.time = time
        self.value = value
    }
}

public struct InferredWindow: Equatable, Sendable {
    public var start: Date
    public var end: Date
}

public struct WindowInferenceResult: Equatable, Sendable {
    /// 当前的窗口；nil 表示上个窗口已经结束、还没有新的使用
    public var current: InferredWindow?
    /// 最近一次（推算的）重置时间
    public var lastReset: Date?
    /// 是按看到过的重置每 duration 循环推的（fixedCadence），不是按第一次使用猜的
    public var fromCadence = false
}

/// 推算额度窗口什么时候开始、什么时候重置。
///
/// 桌面端的读数里没有重置时间，只能推：
/// 1. 窗口从「上一个窗口结束后的第一次使用」开始，持续固定时长（5 小时 / 7 天）。
///    使用时间来自本机 Claude Code 请求（精确），以及官方读数的上涨（网页 / 手机端用量，
///    只知道发生在两次读数之间，取中点）。
/// 2. 读数明显下跌说明发生了重置（锚点）。如果推出来的窗口比锚点结束得晚，
///    说明窗口其实开始得更早（比如先在网页端用的），以锚点为准。
/// 3. 桌面端最早的读数是 0 时，当作「在这之前的窗口都结束了」。
/// 4. 限流消息给出的恢复时间是精确的重置时间（knownResets），优先于上面推出来的。
///
/// 每周额度按固定时间重置（fixedCadence），不管有没有用：看到过一次重置之后，就按它每 7 天重置一次，
/// 不再按第一次使用推。还没看到过重置时只能按上面的规则推，会偏晚（比如一周前几天没用）。
public enum WindowInference {
    /// 桌面端大约每 15 分钟记一次
    public static let sampleSpacing: TimeInterval = 15 * 60

    struct Anchor {
        let after: Date      // 重置发生在 (after, by] 之间
        let by: Date
        let newUsage: Bool   // 重置后的第一个读数已经 > 0：新窗口也在这段时间里开始了
        var exact: Date?     // 限流消息给出的精确重置时间
        /// 能确定重置时刻的锚点才用来定固定周期：规则 3 的锚点只说明之前的窗口结束了；1 → 0 这种小幅回落可能是噪声
        var observed = true
    }

    /// 读数从 a 变成 b 算不算一次重置。小幅回落（比如 3 → 1）是噪声，不算。
    static func isReset(from a: Double, to b: Double) -> Bool {
        let drop = a - b
        return drop > 0 && (b == 0 || drop >= max(3, a / 2))
    }

    /// origin：之前推出来的窗口开始时间（见 ClaudeProvider 的 weeklyOrigin）。它之前的使用都属于更早、已经结束的窗口，
    /// 从它接着推；不然本机日志只留 8 天，最早的请求滚出去之后从剩下的推，按第一次使用定的起点会每天往后挪
    public static func infer(samples: [UsageSample], activity: [Date], duration: TimeInterval, now: Date,
                             knownResets: [Date] = [], fixedCadence: Bool = false, origin: Date? = nil) -> WindowInferenceResult {
        let exact = activity.filter { $0 <= now }.sorted()
        var events = exact
        var anchors: [Anchor] = []

        if let first = samples.first, first.value == 0 {
            anchors.append(Anchor(after: first.time.addingTimeInterval(-1), by: first.time, newUsage: false, observed: false))
        }
        for i in samples.indices.dropFirst() {
            let a = samples[i - 1], b = samples[i]
            guard b.time > a.time, b.time <= now else { continue }
            if isReset(from: a.value, to: b.value) {
                anchors.append(Anchor(after: a.time, by: b.time, newUsage: b.value > 0, observed: a.value - b.value >= 3))
            }
            // 读数上涨：这段时间里有使用。隔了一个窗口以上还不是 0（比如 5 小时额度隔了一夜 50 → 30、100 → 100）也一样：
            // 之前的窗口早就结束了，这个读数是这段时间里新开的窗口的，不然会被当成上一个窗口的读数，一直用到下次本机使用
            if b.value > a.value || (b.value > 0 && b.time.timeIntervalSince(a.time) >= duration) {
                // 本机已经有精确请求记录的话，就不用这个粗略的时间点
                let lo = max(a.time, b.time.addingTimeInterval(-sampleSpacing))
                if firstEvent(in: exact, after: lo, upTo: b.time) == nil {
                    events.append(lo.addingTimeInterval(b.time.timeIntervalSince(lo) / 2))
                }
            }
        }
        for reset in knownResets.sorted() where reset <= now {
            if let i = anchors.firstIndex(where: { reset > $0.after && reset <= $0.by }) {
                // 一段读数空档里有好几次精确重置：读数跳变属于最后一次（跳变之后的读数是它之后的窗口），更早的各自单独成锚点
                if let earlier = anchors[i].exact {
                    anchors.append(Anchor(after: earlier, by: earlier, newUsage: false, exact: earlier))
                }
                anchors[i].exact = reset
            } else {
                anchors.append(Anchor(after: reset, by: reset, newUsage: false, exact: reset))
            }
        }
        // 有精确时间的锚点在那个时刻生效，其他的在跳变之后的那次读数生效
        anchors.sort { ($0.exact ?? $0.by) < ($1.exact ?? $1.by) }
        // 空档一周以上的跳变说明不了重置在一周里的哪个时刻
        if fixedCadence, let reset = cadenceReset(anchors.filter { $0.observed && $0.by.timeIntervalSince($0.after) < duration },
                                                  duration: duration) {
            let window = cycle(from: reset, duration: duration, now: now)
            return WindowInferenceResult(current: window, lastReset: window.start, fromCadence: true)
        }
        var start: Date?
        var lastReset: Date?
        var nextAnchor = 0
        if let origin, origin <= now {
            events = events.filter { $0 > origin } + [origin]
            lastReset = origin  // 上一个窗口最晚在这时结束：更早的读数不属于之后的窗口
        }
        events.sort()

        // 处理 t 之前生效的锚点：当前窗口若开始于重置之前，说明它已经在锚点处被重置
        func applyAnchors(upTo t: Date) {
            while nextAnchor < anchors.count, (anchors[nextAnchor].exact ?? anchors[nextAnchor].by) <= t {
                let anchor = anchors[nextAnchor]
                nextAnchor += 1
                guard let s = start, s <= (anchor.exact ?? anchor.after) else {
                    // 没有在跑的窗口（重置之后还没有使用）：精确的重置照样生效，这之前的官方读数属于上一个窗口，不能再用
                    if start == nil, let exact = anchor.exact, lastReset.map({ exact > $0 }) ?? true { lastReset = exact }
                    continue
                }
                let natural = s.addingTimeInterval(duration)
                let reset = anchor.exact ?? ((natural > anchor.after && natural <= anchor.by)
                    ? natural
                    : anchor.after.addingTimeInterval(anchor.by.timeIntervalSince(anchor.after) / 2))
                lastReset = reset
                start = nil
                if anchor.newUsage {
                    // 重置后马上又用了：新窗口从重置后的第一次使用开始
                    start = firstEvent(in: exact, after: reset, upTo: anchor.by)
                        ?? reset.addingTimeInterval(anchor.by.timeIntervalSince(reset) / 2)
                }
            }
        }

        for t in events {
            applyAnchors(upTo: t)
            if let s = start {
                let end = s.addingTimeInterval(duration)
                if t < end { continue }  // 还在当前窗口里
                lastReset = end
            }
            start = t
        }
        applyAnchors(upTo: now)
        if let s = start, now >= s.addingTimeInterval(duration) {
            lastReset = s.addingTimeInterval(duration)
            start = nil
        }
        return WindowInferenceResult(
            current: start.map { InferredWindow(start: $0, end: $0.addingTimeInterval(duration)) },
            lastReset: lastReset
        )
    }

    /// 从某次重置起每 duration 循环一次，now 所在的那个窗口
    public static func cycle(from reset: Date, duration: TimeInterval, now: Date) -> InferredWindow {
        let periods = (now.timeIntervalSince(reset) / duration).rounded(.down) + 1
        let end = reset.addingTimeInterval(periods * duration)
        return InferredWindow(start: end.addingTimeInterval(-duration), end: end)
    }

    /// 固定周期的重置时刻：读数跳变只能说明重置在两次读数之间，把各次跳变挪到最近那次的周期里取交集，
    /// 桌面端没开的空档再长，看到的次数多了也能收窄。对不上说明重置时间变过，只用更近的那些。
    /// 取交集里最晚的时刻：宁可晚一点宣布重置，也不要提前，不然重置前的最后一次读数会被当成新窗口的（数字来回跳、误发提醒）
    static func cadenceReset(_ anchors: [Anchor], duration: TimeInterval) -> Date? {
        guard let latest = anchors.last else { return nil }
        var lo = latest.exact ?? latest.after, hi = latest.exact ?? latest.by
        for a in anchors.dropLast().reversed() {
            let shift = (hi.timeIntervalSince(a.exact ?? a.by) / duration).rounded() * duration
            let newLo = max(lo, (a.exact ?? a.after).addingTimeInterval(shift))
            let newHi = min(hi, (a.exact ?? a.by).addingTimeInterval(shift))
            if newLo > newHi { break }
            lo = newLo
            hi = newHi
        }
        return hi
    }

    /// sorted 中第一个落在 (lo, hi] 的时间
    static func firstEvent(in sorted: [Date], after lo: Date, upTo hi: Date) -> Date? {
        var low = 0, high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid] <= lo { low = mid + 1 } else { high = mid }
        }
        return low < sorted.count && sorted[low] <= hi ? sorted[low] : nil
    }
}
