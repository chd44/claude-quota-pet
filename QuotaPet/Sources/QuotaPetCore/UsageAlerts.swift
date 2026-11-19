import Foundation

/// 用量提醒：跨过阈值、照最近的速度快用完了、额度恢复了。每个窗口每个周期，每个阈值和「快用完」各只提醒一次。
/// 进了新的周期（用量掉到 5% 以下，或者重置时间往后跳了半个窗口以上）就重新开始算。
/// 这里只决定发什么、怎么说，发通知和存提醒记录在 App 里（NotificationManager）
public enum UsageAlerts {
    /// 设置里打开了哪些提醒
    public struct Options: Equatable, Sendable {
        /// 用量提醒（总开关）：跨过阈值时提醒
        public var usage: Bool
        public var thresholds: [Int]
        /// 照最近的速度快用完时提前提醒（见 UsageWindow.warningLead），用量提醒关掉时也不发
        public var runningOut: Bool
        /// 额度恢复时提醒
        public var reset: Bool

        public init(usage: Bool, thresholds: [Int], runningOut: Bool, reset: Bool) {
            self.usage = usage
            self.thresholds = thresholds
            self.runningOut = runningOut
            self.reset = reset
        }
    }

    /// 一个窗口的提醒记录（App 存在 UserDefaults 里，重启也不会重复提醒）
    public struct State: Equatable, Sendable {
        /// 上次看到的百分比
        public var last: Double
        /// 这个周期里提醒过的阈值
        public var notified: Set<Int>
        /// 这个周期里已经说过「照这个速度快用完了」：单独提醒过，或者阈值提醒里顺带说了
        public var warned: Bool
        /// 上次看到的重置时间：往后跳了半个窗口以上，说明进了新的周期
        public var cycleEnd: Date?
        /// 第几个周期（真的进了新周期才加一）。发送失败的结果回来时，靠它认出这条提醒属于哪个周期：
        /// 回来时已经进了新周期的，旧周期的提醒不用补
        public var cycle: Int
        /// 发送失败、等着重发的：阈值提醒（那个阈值）和「额度恢复」。「快用完」失败了只是把 warned 放回去，下次还快用完就会再发
        public var retryThresholds: Set<Int>
        public var retryReset: Bool

        public init(last: Double = 0, notified: Set<Int> = [], warned: Bool = false, cycleEnd: Date? = nil,
                    cycle: Int = 0, retryThresholds: Set<Int> = [], retryReset: Bool = false) {
            self.last = last
            self.notified = notified
            self.warned = warned
            self.cycleEnd = cycleEnd
            self.cycle = cycle
            self.retryThresholds = retryThresholds
            self.retryReset = retryReset
        }
    }

    public enum Alert: Equatable, Sendable {
        /// 额度恢复了
        case reset
        /// 跨过了阈值；runsOutAt：照最近的速度会在重置前用完的话，是几点，顺带说一句
        case threshold(Int, runsOutAt: Date?)
        /// 照最近的速度，很快就会在重置前用完
        case runningOut(Date)
    }

    /// 这个窗口的新数据要发哪些提醒，以及更新后的记录。
    /// settingsChanged：这次变化是改设置（实时估算、自动学习、每周重置时间）引起的，不是真的用了或恢复了。
    /// 估算从 80% 掉到 0%、又回到 80% 不是新周期：设置变化只更新比较基准（last、cycleEnd），不清这个周期的提醒记录，
    /// 之后同一周期里再看到 80%，不会把 75% 的提醒重发一遍；也不会算「刚恢复」。
    /// （改设置的同一时刻恰好真的重置了的话，下一次刷新时用量还很低，照常会进新周期。）
    public static func evaluate(_ window: UsageWindow, state: State, options: Options, now: Date,
                                settingsChanged: Bool = false) -> (alerts: [Alert], state: State) {
        var state = state
        var alerts: [Alert] = []
        let percent = window.percent
        // App 没开着时跨过了重置、重新打开时新周期已经用了一些，用量不会掉到 5% 以下，只能看重置时间往后跳了没有。
        // 推算的重置时间会前后挪一点，跳半个窗口以上才算
        var nextCycle = false
        if let old = state.cycleEnd, let end = window.resetsAt { nextCycle = end.timeIntervalSince(old) > window.duration / 2 }
        let newCycle = !settingsChanged && (percent < 5 || nextCycle)
        if newCycle {
            // 用量一直在 5% 以下时每次刷新都算「新周期」，但那还是上次进的那个周期：只有从有用量的状态回来、
            // 或者重置时间往后跳了，才是真的又进了一个周期（周期号加一，旧周期等着重发的作废）
            let sameFreshCycle = state.last < 5 && !nextCycle
            if recovered(from: state.last, to: percent) || (state.retryReset && sameFreshCycle), options.reset {
                alerts.append(.reset)
                state.retryReset = false
            }
            if !sameFreshCycle {
                state.cycle += 1
                state.retryThresholds = []
                state.retryReset = false
            }
            state.notified = []
            state.warned = false
        }
        if let end = window.resetsAt { state.cycleEnd = end }
        let runsOut = window.projectedExhaustion(now: now)
        let soon = runsOut.map { $0.timeIntervalSince(now) <= window.warningLead } ?? false
        // 「快用完」预警：单独的和并进阈值提醒里的是同一条，共用开关（用量提醒 + 快用完预警）和每周期一次的规则。
        // 阈值提醒里「几点用完」也属于它：预警关着、或者这个周期已经预警过了，阈值提醒里就不再说
        let mention: Date? = options.runningOut && !state.warned ? runsOut : nil
        let warn: Date? = soon && options.usage && options.runningOut && !state.warned ? runsOut : nil
        if options.usage {
            let reached = options.thresholds.filter { percent >= Double($0) && !state.notified.contains($0) }
            // 只提醒这次刚跨过的。上次就已经在它上面了还没提醒过的（刚在设置里打开的阈值、提醒关着时跨过的），
            // 记上但不补发：已经用到 95% 了再说「已用 50%」是旧消息，台词也对不上。
            // 发送失败等着重发的阈值（retryThresholds）例外：它本来就是这次要发的
            let floor = newCycle ? 0 : state.last
            let retry = state.retryThresholds
            if let top = reached.filter({ Double($0) > floor || retry.contains($0) }).max() {
                alerts.append(.threshold(top, runsOutAt: mention))
                if warn != nil { state.warned = true }  // 这条里已经说了几点用完，而且就快用完了：不用再单独提醒一次
            }
            state.notified.formUnion(reached)
            state.retryThresholds = []
        }
        if let warn, !state.warned {
            alerts.append(.runningOut(warn))
            state.warned = true
        }
        state.last = percent
        return (alerts, state)
    }

    /// 一条提醒没发出去（系统没收下）时，把记录改回「还没发」：state 是回调回来时当前的记录（这期间可能已经更新过几次），
    /// cycle 是评估这条提醒时的周期号，对不上说明已经进了新周期，旧周期的提醒不用补。
    /// 只动这一条提醒对应的记录：阈值提醒从 notified 里拿掉、记进待重发；「额度恢复」记进待重发；
    /// 「快用完」（单独的，或者并在阈值提醒里的，见 carriesWarning）把 warned 放回去
    public static func deliveryFailed(_ alert: Alert, cycle: Int, carriesWarning: Bool = false, in state: State) -> State {
        guard state.cycle == cycle else { return state }
        var state = state
        switch alert {
        case .reset:
            state.retryReset = true
        case .threshold(let threshold, _):
            state.notified.remove(threshold)
            state.retryThresholds.insert(threshold)
            if carriesWarning { state.warned = false }
        case .runningOut:
            state.warned = false
        }
        return state
    }

    /// 这条提醒是不是同时承担了「快用完」预警（记了 warned）：单独的预警，或者阈值提醒里说的用完时间就在预警提前量以内。
    /// 只是顺带说一句、还不算快用完的阈值提醒，不记 warned
    public static func carriesWarning(_ alert: Alert, window: UsageWindow, now: Date) -> Bool {
        switch alert {
        case .runningOut: return true
        case .threshold(_, let runsOutAt): return runsOutAt.map { $0.timeIntervalSince(now) <= window.warningLead } ?? false
        case .reset: return false
        }
    }

    /// 额度恢复了：上次看到用了六成以上，现在掉到了 5% 以下（没怎么用就重置的不值得说）
    public static func recovered(from last: Double, to percent: Double) -> Bool { percent < 5 && last >= 60 }

    public static func title(_ alert: Alert, window: UsageWindow, provider: ProviderID) -> String {
        let name = provider.displayName
        switch alert {
        case .reset:
            return tr("\(name) \(window.displayTitle)已恢复", "\(name) · \(window.displayTitle) has reset")
        case .threshold(let threshold, _):
            return threshold >= 100
                ? tr("\(name) \(window.displayTitle)用完了", "\(name) · \(window.displayTitle) used up")
                : tr("\(name) \(window.displayTitle)已用 \(threshold)%", "\(name) · \(window.displayTitle) \(threshold)% used")
        case .runningOut:
            return tr("\(name) \(window.displayTitle)快用完了", "\(name) · \(window.displayTitle) is running out")
        }
    }

    public static func body(_ alert: Alert, window: UsageWindow, now: Date) -> String {
        switch alert {
        case .reset:
            return tr("满血复活！可以继续干活了 🎉", "Fully recharged, back to work! 🎉")
        case .threshold(let threshold, let runsOut):
            var parts: [String] = []
            if let reset = window.resetsAt {
                let when = Fmt.fromNow(reset.timeIntervalSince(now)), clock = Fmt.clock(reset, now: now)
                parts.append(threshold >= 100
                    ? tr("\(when)恢复（\(clock)）。", "Back \(when) (\(clock)). ")
                    : tr("\(when)重置（\(clock)）。", "Resets \(when) (\(clock)). "))
            }
            if let runsOut {
                let clock = Fmt.clock(runsOut, now: now)
                parts.append(tr("照最近的速度 \(clock) 左右就会用完。", "At the recent pace it runs out around \(clock). "))
            }
            parts.append(threshold >= 100
                ? tr("小家伙睡着了，先去喝杯水吧 ☕️", "Your pet fell asleep. Go grab a drink ☕️")
                : PetMood.from(percent: Double(threshold)).line)
            return parts.joined()
        case .runningOut(let runsOut):
            let clock = Fmt.clock(runsOut, now: now), when = Fmt.fromNow(runsOut.timeIntervalSince(now))
            guard let reset = window.resetsAt else {
                return tr("照最近的速度，\(clock) 左右用完（\(when)）。", "At the recent pace it runs out around \(clock) (\(when)).")
            }
            let early = Fmt.duration(reset.timeIntervalSince(runsOut))
            return tr("照最近的速度，\(clock) 左右用完（\(when)），比重置早 \(early)。",
                      "At the recent pace it runs out around \(clock) (\(when)), \(early) before the reset.")
        }
    }
}
