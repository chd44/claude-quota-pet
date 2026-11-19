import AppKit
import Combine
import QuotaPetCore

/// 调度刷新：文件一变（FSEvents）就重算那一家，另外每分钟兜底把几家都重算一次（重置倒计时要走）。
/// 真正的计算在同一个后台串行队列上跑；每家算完就单独更新，不用等别家。
@MainActor
final class UsageStore: ObservableObject {
    /// 各家的最新快照，顺序和 providers 一样（Claude 在前）；算出错的那家保留上一次的结果
    @Published private(set) var snapshots: [UsageSnapshot] = []
    /// 算出错的原因，按数据源
    @Published private(set) var errors: [ProviderID: String] = [:]
    /// 宠物对每一家记得的事（刚恢复、刚才的警报），心情和台词要用。只记在内存里，重启 App 就忘了
    private(set) var memory: [ProviderID: PetMemory] = [:]
    /// 每次兜底刷新时走一下。宠物的心情和时间有关（刚恢复十分钟、闲了半小时），
    /// 读取一直出错时快照和错误信息都不变，靠它让菜单栏和面板照样重算
    @Published private(set) var tick = Date()
    /// 「用命令行补官方读数」的状态，设置页上说明用；没有 Claude 数据源（演示模式）时是 nil
    @Published private(set) var cliProbeStatus: ClaudeCLIProbeStatus?
    private var cliProbe: CLIProbe?

    /// 每次拿到某一家的新数据时回调（旧快照，新快照，是不是改设置引起的），用来发通知。
    /// 改设置引起的变化（关掉实时估算掉到 0%、再打开又涨回去）不是真的用量变化：只更新提醒记录，不发提醒
    var onUpdate: ((UsageSnapshot?, UsageSnapshot, _ settingsChanged: Bool) -> Void)?

    private let providers: [UsageProvider]
    private let settings: AppSettings
    private let queue = DispatchQueue(label: "QuotaPet.usage", qos: .utility)
    private var watcher: FileWatcher?
    /// 正在监听的目录（启动时还不存在的目录，兜底刷新时会补上）
    private var watchedPaths: [String] = []
    private var pollTimer: Timer?
    /// 每家的刷新排期：文件事件的防抖和限频（从真正开始算起 5 秒）、算的时候又有新变化要不要再算（规则在 Core 里，能进自检）
    private let gate = RefreshGate()
    /// 单调时钟：改系统时间、休眠不影响限频
    private var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
    /// 排着队或正在算的几家（和 gate 里的阶段一致，算完才去掉）
    private var running: Set<ProviderID> = []
    /// 改了设置、要按新设置重算的几家：下一次开始算的那次结果算「改设置引起的」。
    /// 改设置时正在算的那次可能已经读到了新设置（另记在 settingsChangedRunning），也一样算
    private var settingsChanged: Set<ProviderID> = []
    private var settingsChangedRunning: Set<ProviderID> = []
    private var cancellables: Set<AnyCancellable> = []

    init(providers: [UsageProvider], settings: AppSettings) {
        self.providers = providers
        self.settings = settings
        applyConfig(settings.providerConfig)
        if let claude = providers.first(where: { $0 is ClaudeProvider }) as? ClaudeProvider, let archive = claude.cliArchive {
            let probe = CLIProbe(settings: settings, archive: archive, desktopOrg: { claude.desktopOrg })
            probe.onStatus = { [weak self] status in self?.cliProbeStatus = status }
            probe.onReading = { [weak self] in self?.refresh([.claude]) }
            cliProbe = probe
            cliProbeStatus = probe.status
        }
    }

    /// 命令行的位置（找不到时设置页不给登录按钮）
    var cliBinary: URL? { cliProbe?.binary }

    /// 设置页上的一键「开启并登录」
    func connectCLI() { cliProbe?.connect() }

    /// 用户点了刷新：本机文件马上重读，打开了「用命令行补官方读数」的话也让命令行查一次
    func refreshNow() {
        refresh()
        cliProbe?.requestNow()
    }

    /// 面板和菜单栏要显示的几家
    var shown: [UsageSnapshot] { UsageSnapshot.visible(snapshots, hidden: settings.hiddenProviders) }

    /// 宠物和菜单栏跟着的那家：最紧张的
    var focus: UsageSnapshot? { UsageSnapshot.focus(of: shown) }

    func snapshot(for provider: ProviderID) -> UsageSnapshot? {
        snapshots.first { $0.provider == provider }
    }

    func start() {
        updateWatcher()

        let timer = Timer(timeInterval: providers.map(\.pollInterval).min() ?? 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateWatcher()
                self?.refresh()
                self?.tick = Date()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        // 改了实时估算 / 自动学习 / 每周重置时间 / 命令行读数，立刻重算（只影响 Claude）
        Publishers.CombineLatest4(settings.$liveEstimate, settings.$autoLearn, settings.$weeklyResetAnchor, settings.$claudeCLIProbe)
            .dropFirst()
            .sink { [weak self] live, learn, anchor, cli in
                guard let self else { return }
                applyConfig(AppSettings.providerConfig(liveEstimate: live, autoLearn: learn, weeklyResetAnchor: anchor,
                                                       useCLIReadings: cli))
                settingsChanged.insert(.claude)
                if running.contains(.claude) { settingsChangedRunning.insert(.claude) }
                refresh([.claude])
            }
            .store(in: &cancellables)

        // 打开「用命令行补官方读数」：马上查一次，设置页上就有结果
        settings.$claudeCLIProbe
            .dropFirst()
            .sink { [weak self] on in self?.cliProbe?.settingChanged(on: on) }
            .store(in: &cancellables)

        // 换了界面语言：快照里的窗口名、说明文字要用新语言重算
        settings.$language
            .dropFirst()
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        refresh()
    }

    /// 要监听的目录可能是后来才有的（比如 App 开着的时候才第一次用 Codex）：目录有变化就重建监听。
    /// 监听真的启动了才记下来；启动失败（FSEvents 没起来）就不记，下次兜底刷新再试，期间靠每分钟的兜底刷新撑着
    private func updateWatcher() {
        let existing = providers.flatMap(\.watchPaths).filter { FileManager.default.fileExists(atPath: $0) }
        guard existing != watchedPaths else { return }
        guard !existing.isEmpty else {
            watcher = nil
            watchedPaths = []
            return
        }
        let new = FileWatcher(paths: existing) { [weak self] events in
            MainActor.assumeIsolated {
                guard let self else { return }
                let changed = WatchRouting.providersAffected(by: events, providers: self.providers)
                if !changed.isEmpty { self.scheduleRefresh(changed) }
            }
        }
        guard let new else { return }
        watcher = new
        watchedPaths = existing
    }

    /// 文件事件会连着来一串，合并成一次刷新；同一家离上一次真正开始算不到 5 秒时等到点再算（RefreshGate）。
    /// 已经排着队的那家不用再排：开始算时读的是那时候的文件，这期间的变化都算得到；开始算以后又变了的，算完会按限频再排一次
    func scheduleRefresh(_ ids: Set<ProviderID>) {
        for id in ids { arm(gate.fileChanged(id, now: uptime), for: id) }
    }

    private func arm(_ schedule: RefreshGate.Schedule, for id: ProviderID) {
        guard case .after(let delay, let token) = schedule else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, gate.timerFired(id, token: token) else { return }
            launch(id)
        }
    }

    /// 重算这几家（nil = 全部），不受限频管。某一家正在算时，等它算完再算一次
    func refresh(_ ids: Set<ProviderID>? = nil) {
        for provider in providers where ids?.contains(provider.id) ?? true {
            if gate.request(provider.id) { launch(provider.id) }
        }
    }

    /// 交给后台队列：轮到它、真正开始算的时候才记开始时间（限频从这里起算，排队的时间不算）
    private func launch(_ id: ProviderID) {
        guard let provider = providers.first(where: { $0.id == id }) else { return }
        running.insert(id)
        let afterSettings = settingsChanged.remove(id) != nil
        let gate = gate
        queue.async { [weak self] in
            gate.began(id, now: ProcessInfo.processInfo.systemUptime)
            let result = Result { try provider.snapshot(now: Date()) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finish(id, result, afterSettings: afterSettings) }
            }
        }
    }

    private func finish(_ id: ProviderID, _ result: Result<UsageSnapshot, Error>, afterSettings: Bool) {
        running.remove(id)
        let settingsChange = settingsChangedRunning.remove(id) != nil || afterSettings
        switch result {
        case .success(let new):
            let old = snapshot(for: id)
            // 要在 snapshots 赋值之前记好：订阅者收到新快照时会来读。改设置引起的掉到 0% 不算「刚恢复」
            memory[id] = (memory[id] ?? PetMemory()).updated(from: settingsChange ? nil : old, to: new, now: new.generatedAt)
            let next = providers.compactMap { $0.id == id ? new : snapshot(for: $0.id) }
            if next != snapshots { snapshots = next }
            if errors[id] != nil { errors[id] = nil }
            onUpdate?(old, new, settingsChange)
            if id == .claude { cliProbe?.consider(new) }
        case .failure(let error):
            if errors[id] != error.localizedDescription { errors[id] = error.localizedDescription }
            if settingsChange { settingsChanged.insert(id) }  // 这次没算出来，下一次成功的还算改设置引起的
        }
        switch gate.finished(id, now: uptime) {
        case .none: break
        case .runNow: launch(id)
        case .after(let delay, let token): arm(.after(delay, token: token), for: id)
        }
    }

    private func applyConfig(_ config: ClaudeProvider.Config) {
        for case let provider as ClaudeProvider in providers {
            provider.config = config
        }
    }
}
