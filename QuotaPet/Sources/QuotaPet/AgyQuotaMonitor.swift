import AppKit
import Combine
import QuotaPetCore

/// 带读取时刻的官方读数
protocol TimedReading: Codable, Sendable {
    var checkedAt: Date { get }
    /// 读到了可用的额度（只缓存这种）
    var isUsable: Bool { get }
}

extension AgyQuotaReading: TimedReading {
    var isUsable: Bool { status == .available }
}
extension ClaudeUsageReading: TimedReading {
    var isUsable: Bool { status == .available }
}

/// Reads only an official CLI while that service is selected; no background service.
/// 选中时立刻读一次，之后每 15 分钟一次；切走、睡眠、退出时停止。agy 和 Claude 共用这一份调度。
@MainActor
final class CLIQuotaMonitor<Reading: TimedReading> {
    private(set) var reading: Reading?
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

    private func startQuery() {
        querying = true
        lastQueryStarted = Date()
        let requestGeneration = generation
        let probe = self.probe
        onChange?()
        task = Task { [weak self] in
            let result = await probe()
            guard let self else { return }
            self.lastQueryEnded = Date()
            self.policy.finish()
            self.task = nil
            if requestGeneration == self.generation, self.policy.selected, !self.policy.sleeping {
                self.reading = result
                self.history = (self.history + [result]).filter { result.checkedAt.timeIntervalSince($0.checkedAt) < 25 * 3600 }
                if result.isUsable { self.saveCache(result) }
                self.querying = false
                self.onChange?()
                self.armTimer()
            } else {
                // A cancelled process must finish before a new selection may read.
                self.querying = false
                self.refreshIfDue()
            }
        }
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
