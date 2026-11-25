import AppKit
import Combine
import QuotaPetCore

/// 带读取时刻的官方读数
protocol TimedReading: Codable, Sendable {
    var checkedAt: Date { get }
    /// 读到了可用的额度（只缓存这种）
    var isUsable: Bool { get }
    /// 没读到可靠读数、也说不出明确原因（超时、面板没出来、版式没认出）
    var isUnknown: Bool { get }
    /// 读不到时官方 CLI 给的原因（可能为空）
    var message: String { get }
}

extension AgyQuotaReading: TimedReading {
    var isUsable: Bool { status == .available }
    var isUnknown: Bool { status == .unknown }
}
extension ClaudeUsageReading: TimedReading {
    var isUsable: Bool { status == .available }
    var isUnknown: Bool { status == .unknown }
}

/// Reads only an official CLI while that service is selected; no background service.
/// 选中时立刻读一次，之后每 15 分钟一次；切走、睡眠、退出时停止。agy 和 Claude 共用这一份调度。
@MainActor
final class CLIQuotaMonitor<Reading: TimedReading> {
    private(set) var reading: Reading?
    /// 最近一次读取本身的结果（失败也记）：偶发失败时 reading 还留着上一次的可用读数，手动刷新的提示要按这一次报成败和原因
    private(set) var lastResult: Reading?
    /// 最近 25 小时的读数，只在内存里（算按官方读数的消耗速度用）
    private(set) var history: [Reading] = []
    private(set) var querying = false
    /// 最近一次查询结束（不论成败）的时间：自动跟随用它认出 QuotaPet 自己查额度时 CLI 留下的写入
    private(set) var lastQueryEnded: Date?
    /// 最近一次查询开始的时间：和 lastQueryEnded 一起框出 CLI 进程在跑的那段时间
    private(set) var lastQueryStarted: Date?
    var onChange: (() -> Void)?
    private let enabled: Bool
    private let probe: @Sendable () async -> Reading
    /// 下一次界面要变的时刻（读数过期、窗口重置），到时候也唤醒一次
    private let nextChange: (Reading?, Date) -> Date?
    private var policy = AgyRefreshPolicy()
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var generation = 0
    private var observations: Set<AnyCancellable> = []

    /// 最近一次可用读数存在本机设置里：重启或刚打开时，有效期内的先拿出来显示，同时照常去读新的
    private let cacheKey: String?
    private let defaults: UserDefaults

    init(enabled: Bool, cacheKey: String? = nil, defaults: UserDefaults = .standard,
         probe: @escaping @Sendable () async -> Reading, nextChange: @escaping (Reading?, Date) -> Date?) {
        self.enabled = enabled
        self.cacheKey = enabled ? cacheKey : nil
        self.defaults = defaults
        self.probe = probe
        self.nextChange = nextChange
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.publisher(for: NSWorkspace.willSleepNotification).sink { [weak self] _ in
            Task { @MainActor in self?.sleep() }
        }.store(in: &observations)
        workspace.publisher(for: NSWorkspace.didWakeNotification).sink { [weak self] _ in
            Task { @MainActor in self?.wake() }
        }.store(in: &observations)
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }.store(in: &observations)
    }

    func select(_ requestedSelection: Bool) {
        let selected = enabled && requestedSelection
        guard policy.selected != selected else { return }
        policy.select(selected)
        generation += 1
        reading = nil
        history = []
        if selected {
            if let cached = loadCache(), (0..<AgyRefreshPolicy.interval).contains(Date().timeIntervalSince(cached.checkedAt)) {
                reading = cached
                history = [cached]
            }
            armTimer()
            refreshIfDue()
        } else {
            timer?.invalidate()
            timer = nil
            task?.cancel()
            querying = false
        }
        onChange?()
    }

    func stop() {
        select(false)
        observations.removeAll()
    }

    private func sleep() {
        policy.setSleeping(true)
        generation += 1
        timer?.invalidate()
        timer = nil
        task?.cancel()
        querying = false
        onChange?()
    }

    private func wake() {
        policy.setSleeping(false)
        if policy.selected {
            armTimer()
            refreshIfDue()
        }
        onChange?()
    }

    private func armTimer() {
        timer?.invalidate()
        guard policy.selected, !policy.sleeping else { return }
        // Common modes allow expiry to update even while the menu is tracking.
        let now = Date()
        var delay = policy.delayUntilDue(now: now)
        if let change = nextChange(reading, now), change > now { delay = min(delay, change.timeIntervalSince(now)) }
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.refreshIfDue()
                self?.onChange?()
                self?.armTimer()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func loadCache() -> Reading? {
        guard let cacheKey, let data = defaults.data(forKey: cacheKey) else { return nil }
        return try? JSONDecoder().decode(Reading.self, from: data)
    }

    private func saveCache(_ reading: Reading) {
        guard let cacheKey, let data = try? JSONEncoder().encode(reading) else { return }
        defaults.set(data, forKey: cacheKey)
    }

    private func refreshIfDue() {
        guard policy.begin(now: Date()) else { return }
        startQuery()
    }

    /// 手动刷新还要等几秒；不用等时是 nil
    func manualWait(now: Date = Date()) -> TimeInterval? { policy.manualWait(now: now) }

    /// 用户点了刷新：马上读一次（离上次开始读不到 30 秒、或正在读时不重复启动）。返回是否真的开始读了
    @discardableResult
    func refreshNow() -> Bool {
        guard policy.beginManual(now: Date()) else { return false }
        startQuery()
        return true
    }

    /// 检测到在用（比如 Claude Code 的对话文件有写入）：离上次读够久就读一次。返回是否开始读了
    @discardableResult
    func refreshForActivity() -> Bool {
        guard policy.beginActivity(now: Date()) else { return false }
        startQuery()
        return true
    }

    /// 每次查询的编号：看门狗放弃一次查询后，它迟到的结果按编号认出来丢掉
    private var queryID = 0
    private var watchdog: Task<Void, Never>?

    private func startQuery() {
        querying = true
        lastQueryStarted = Date()
        queryID += 1
        let id = queryID
        let requestGeneration = generation
        let probe = self.probe
        onChange?()
        task = Task { [weak self] in
            let result = await probe()
            guard let self, id == self.queryID else { return }  // 已被看门狗放弃
            self.watchdog?.cancel()
            self.watchdog = nil
            self.lastQueryEnded = Date()
            self.task = nil
            if requestGeneration == self.generation, self.policy.selected, !self.policy.sleeping {
                // 失败了就隔几分钟重试（见 AgyRefreshPolicy.dueInterval）
                self.policy.finish(usable: result.isUsable)
                // 偶发失败不顶掉还在有效期内的上一次读数
                let keep = AgyRefreshPolicy.keepsPrevious(previousUsable: self.reading?.isUsable == true,
                                                          previousCheckedAt: self.reading?.checkedAt,
                                                          newUsable: result.isUsable, newIsUnknown: result.isUnknown, now: Date())
                if !keep { self.reading = result }
                self.lastResult = result
                self.history = (self.history + [result]).filter { result.checkedAt.timeIntervalSince($0.checkedAt) < 25 * 3600 }
                if result.isUsable { self.saveCache(result) }
                self.querying = false
                self.onChange?()
                self.armTimer()
            } else {
                // A cancelled process must finish before a new selection may read.
                self.policy.finish()
                self.querying = false
                self.refreshIfDue()
            }
        }
        // 看门狗：探测自己最长 45 秒加几秒收尾，超过 2 分钟还没回来就是卡住了（不管什么原因），
        // 当这次失败放掉，后面的定时、活动和手动刷新照常进行，不再一直显示「正在读取」
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(AgyRefreshPolicy.queryTimeout * 1_000_000_000))
            guard !Task.isCancelled, let self, id == self.queryID, self.task != nil else { return }
            self.abandonQuery()
        }
    }

    private func abandonQuery() {
        queryID += 1  // 迟到的结果丢掉
        task?.cancel()
        task = nil
        watchdog = nil
        lastQueryEnded = Date()
        lastResult = nil  // 手动刷新的提示报「没读到新的额度」
        policy.finish(usable: false)
        querying = false
        onChange?()
        armTimer()
    }

}

typealias AgyQuotaMonitor = CLIQuotaMonitor<AgyQuotaReading>
typealias ClaudeQuotaMonitor = CLIQuotaMonitor<ClaudeUsageReading>

extension CLIQuotaMonitor where Reading == AgyQuotaReading {
    convenience init(enabled: Bool) {
        self.init(enabled: enabled, cacheKey: "lastAgyUsageReading", probe: { await AgyQuotaProbe().read() }, nextChange: { reading, now in
            let presentation = AgyQuotaPresentation(reading: reading, now: now)
            let delay = presentation.nextUpdateDelay(defaultDelay: .infinity, now: now)
            return delay.isFinite ? now.addingTimeInterval(delay) : nil
        })
    }

    var mood: PetMood { AgyQuotaPresentation(reading: reading).primaryMood }

    var summary: String {
        let presentation = AgyQuotaPresentation(reading: reading)
        if let window = presentation.primaryWindow, let used = window.usedPercent {
            let percent = Fmt.percent(used)
            return used >= 100
                ? tr("\(window.title) 已用完", "\(window.title) is exhausted")
                : tr("\(window.title) · 已用 \(percent)", "\(window.title) · \(percent) used")
        }
        if querying { return tr("额度未知 · 正在读取官方 CLI", "Quota unknown · Reading official CLI") }
        guard let reading else { return tr("额度未知", "Quota unknown") }
        switch reading.status {
        case .signInRequired: return tr("额度未知 · 请先在 agy CLI 登录", "Quota unknown · Sign in to agy CLI first")
        case .confirmationRequired: return tr("额度未知 · 请在 agy CLI 完成确认", "Quota unknown · Complete confirmation in agy CLI")
        case .unavailable: return tr("额度未知 · 官方 CLI 暂不可用", "Quota unknown · Official CLI unavailable")
        case .available: return tr("额度未知 · 读数已过期或不完整", "Quota unknown · Reading expired or incomplete")
        case .unknown: return tr("额度未知 · 无可靠官方读数", "Quota unknown · No reliable official reading")
        }
    }
}
