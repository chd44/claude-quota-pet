import Foundation

/// 每一家数据源的刷新怎么排期（UsageStore 用，放在 Core 里是为了能进自检；时间由调用方传入，自检里用假时钟）。
///
/// Claude Code 干活时日志大约每秒写一次，每次都把日志目录整个走一遍、把快照整个重算一遍太费电，所以文件事件触发的重算要限频。
/// 限频从「真正开始算」那一刻起算（`began`，在后台队列上轮到它的时候），不是从排进队列、也不是从防抖到点的时候：
/// 队列上前面还有别的活，或者上一次还没算完时，排队的时间不能算进那 5 秒。时间用单调时钟（ProcessInfo.systemUptime），改系统时间不影响。
///
/// 每家有三个阶段：空闲、排着队（已经交给后台队列、还没开始）、正在算。
/// - 文件变了（`fileChanged`）：空闲时按「防抖、离上一次真正开始满 minInterval」安排一个定时器；已经有定时器的不再排；
///   排着队的不用管（开始算时读的是那时候的文件，这期间的变化都算得到）；正在算的记一笔「脏」，算完再按限频排一次。
/// - 立刻重算（`request`：手动刷新、每分钟兜底、改设置、唤醒）：不受限频管。空闲就马上排队；不空闲就记「再来一次」，算完马上再算。
/// - 真正开始算（`began`）时，之前排着的定时器作废：这次读的文件已经包含了那些变化。
public final class RefreshGate: @unchecked Sendable {
    public enum Schedule: Equatable, Sendable {
        /// 不用做什么
        case none
        /// 过 delay 秒后，带着 token 调 `timerFired`
        case after(TimeInterval, token: Int)
    }

    public enum Finish: Equatable, Sendable {
        case none
        /// 马上再算一次（已经记成排着队了，调用方直接交给后台队列，不用再调 `request`）
        case runNow
        /// 算的时候文件又变了：按限频排一个定时器
        case after(TimeInterval, token: Int)
    }

    private enum Phase { case idle, queued, running }

    private struct State {
        var phase = Phase.idle
        var again = false
        var dirty = false
        var token = 0
        var armed: Int?  // 现在有效的定时器
        var lastBegan: TimeInterval?
    }

    public let minInterval: TimeInterval
    public let debounce: TimeInterval
    private let lock = NSLock()
    private var states: [ProviderID: State] = [:]
    private var nextToken = 0

    public init(minInterval: TimeInterval = 5, debounce: TimeInterval = 0.8) {
        self.minInterval = minInterval
        self.debounce = debounce
    }

    private func with<T>(_ id: ProviderID, _ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        var state = states[id] ?? State()
        let result = body(&state)
        states[id] = state
        return result
    }

    private func newToken() -> Int {
        nextToken += 1
        return nextToken
    }

    /// 离上一次真正开始满 minInterval 还要等多久，至少等 debounce（连着来的一串事件合并成一次）
    private func wait(_ state: State, now: TimeInterval) -> TimeInterval {
        let cooldown = state.lastBegan.map { $0 + minInterval - now } ?? 0
        return max(debounce, cooldown)
    }

    /// 这一家的文件变了
    public func fileChanged(_ id: ProviderID, now: TimeInterval) -> Schedule {
        lock.lock()
        let token = newToken()
        lock.unlock()
        return with(id) { state in
            switch state.phase {
            case .queued:
                return .none
            case .running:
                state.dirty = true
                return .none
            case .idle:
                if state.armed != nil { return .none }
                state.armed = token
                return .after(wait(state, now: now), token: token)
            }
        }
    }

    /// 定时器到点了：true = 现在就该开始算（已经记成排着队了）。token 对不上、或者这期间已经开始算过了，就不算
    public func timerFired(_ id: ProviderID, token: Int) -> Bool {
        with(id) { state in
            guard state.armed == token else { return false }
            state.armed = nil
            guard state.phase == .idle else { return false }
            state.phase = .queued
            return true
        }
    }

    /// 要立刻重算（不受限频管）：true = 空闲，已经记成排着队了，调用方交给后台队列；false = 不空闲，算完会再算一次
    public func request(_ id: ProviderID) -> Bool {
        with(id) { state in
            if state.phase == .idle {
                state.phase = .queued
                return true
            }
            state.again = true
            return false
        }
    }

    /// 后台队列上轮到这一家、真正开始算了
    public func began(_ id: ProviderID, now: TimeInterval) {
        with(id) { state in
            state.phase = .running
            state.lastBegan = now
            state.armed = nil  // 之前排着的定时器作废：这次读的文件已经带上了那些变化
            state.dirty = false
        }
    }

    /// 这一家算完了
    public func finished(_ id: ProviderID, now: TimeInterval) -> Finish {
        lock.lock()
        let token = newToken()
        lock.unlock()
        return with(id) { state in
            state.phase = .idle
            if state.again {
                state.again = false
                state.dirty = false
                state.phase = .queued
                return .runNow
            }
            if state.dirty {
                state.dirty = false
                state.armed = token
                return .after(wait(state, now: now), token: token)
            }
            return .none
        }
    }
}
