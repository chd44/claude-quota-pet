import AppKit
import Foundation
import QuotaPetCore

/// 用 Claude 官方命令行补官方读数（设置 → Claude → 官方读数，默认开启、可关）。
///
/// 打开后，QuotaPet 在「你正在用、官方读数又旧了」时让命令行发一个最小请求（haiku、一个字、不带工具、不存会话），
/// 从响应里的 `rate_limit_event` 取 5 小时和每周额度的已用百分比和重置时间，存进 cli-readings.jsonl（见 ClaudeCLIReadings）。
/// 联网的是命令行，用它自己的登录：QuotaPet 不读钥匙串、不读 ~/.claude 里的凭据，只看 `auth status` 的几个字段。
/// 发请求的安全前提（最小环境、官方通道、隔离参数）在 Core 的 ClaudeCLIProber 里，时机的判断在 ClaudeCLIProbePolicy（都能进自检）。
///
/// 关掉开关（或关了又开）之后，在途的任务作废：不再发请求、不存结果、不弹终端。每个任务带着启动时的代数（generation）
/// 和取消令牌，回来时代数对不上就丢掉。
@MainActor
final class CLIProbe {
    private let settings: AppSettings
    private let archive: CLIReadingArchive
    private let desktopOrg: () -> String?
    private let prober = ClaudeCLIProber(executor: ProcessCommandExecutor())
    /// 状态变了（设置页上显示）；读数写进去之后要重算 Claude 那一家
    var onStatus: ((ClaudeCLIProbeStatus) -> Void)?
    var onReading: (() -> Void)?

    private(set) var status: ClaudeCLIProbeStatus = .idle {
        didSet { if status != oldValue { onStatus?(status) } }
    }
    private var lastAttempt: Date?
    private var failures = 0
    private var running = false
    /// 每次开关变化加一；任务回来时和启动时的比，不一样说明这个任务已经作废
    private var generation = 0
    private var cancellation: CLIProbeCancellation?

    init(settings: AppSettings, archive: CLIReadingArchive, desktopOrg: @escaping () -> String?) {
        self.settings = settings
        self.archive = archive
        self.desktopOrg = desktopOrg
    }

    /// 命令行的位置（登录命令要用）；没找到是 nil
    var binary: URL? { ClaudeCLI.locate() }

    /// 每次 Claude 的快照更新时（每分钟、文件变了）看一下要不要查
    func consider(_ snapshot: UsageSnapshot, now: Date = Date()) {
        guard settings.claudeCLIProbe, !running else { return }
        let end = snapshot.window("five_hour").flatMap { $0.startedAt != nil ? $0.resetsAt : nil }
        guard ClaudeCLIProbePolicy.shouldProbe(now: now, sessionEndsAt: end, officialAt: snapshot.officialAt,
                                               lastActiveAt: snapshot.lastActiveAt, lastAttempt: lastAttempt, failures: failures)
        else { return }
        run(now: now)
    }

    /// 手动刷新、刚打开开关：马上查一次（连点除外）
    func requestNow(now: Date = Date()) {
        guard settings.claudeCLIProbe, !running,
              ClaudeCLIProbePolicy.shouldProbeManually(now: now, lastAttempt: lastAttempt) else { return }
        run(now: now)
    }

    /// 开关变了：先作废在途的一切（任务、等登录的轮询、还没弹的终端）。关掉就回到初始状态，打开就查一次让设置页上有结果。
    /// on 是订阅传进来的新值：@Published 在赋值前就通知，这时 settings.claudeCLIProbe 还是旧的
    func settingChanged(on: Bool, now: Date = Date()) {
        generation += 1
        cancellation?.cancel()
        cancellation = nil
        running = false
        failures = 0
        lastAttempt = nil
        status = .idle
        if !on {
            loginAfterCheck = false
            loginWatch?.cancel()
            loginWatch = nil
            removeLoginScript()
            return
        }
        run(now: now)
    }

    /// quiet：等登录时反复看一眼，设置页上不闪「正在查询」，没登录也不算失败（不拉长之后的退避）
    private func run(now: Date, quiet: Bool = false) {
        running = true
        lastAttempt = now
        if !quiet { status = .querying }
        let token = CLIProbeCancellation()
        cancellation = token
        let generation = generation
        let archive = archive, expectedOrg = desktopOrg(), binary = ClaudeCLI.locate(), prober = prober
        Task.detached(priority: .utility) { [weak self] in
            let outcome = prober.run(binary: binary, archive: archive, expectedOrg: expectedOrg, cancellation: token)
            await self?.finish(outcome, quiet: quiet, generation: generation)
        }
    }

    private func finish(_ outcome: ClaudeCLIProbeStatus?, quiet: Bool, generation: Int) {
        // 开关在这期间变过（或已经关了）：这个任务作废，什么都不改
        guard generation == self.generation else { return }
        running = false
        cancellation = nil
        guard settings.claudeCLIProbe, let outcome else { return }
        status = outcome
        switch outcome {
        case .ok:
            failures = 0
            onReading?()
        case .notLoggedIn where quiet:
            break
        default:
            failures += 1
        }
        if loginAfterCheck {
            loginAfterCheck = false
            if outcome.needsLogin { beginLogin(logoutFirst: outcome == .wrongAccount) }
        }
    }

    // MARK: - 一键登录

    /// 设置页上的「开启并登录」：先打开开关查一次，结果是没登录（或账号不对）才弹终端，已经登录了就不打扰
    private var loginAfterCheck = false
    private var loginWatch: Task<Void, Never>?
    private var loginScript: URL?

    func connect() {
        if settings.claudeCLIProbe {
            if status.needsLogin { beginLogin(logoutFirst: status == .wrongAccount) }
        } else {
            loginAfterCheck = true
            settings.claudeCLIProbe = true  // settingChanged 随后会查一次，finish 里接着往下走
        }
    }

    /// 在终端里打开官方命令行的 auth login（脚本见 ClaudeCLI.loginScript）：登录在浏览器里由用户自己完成。
    /// 脚本用和探测同一份最小环境（同一个 CLAUDE_CONFIG_DIR），放在自己的私有临时目录里。
    /// 之后每隔几秒看一眼登录好了没有，最多等 10 分钟
    func beginLogin(logoutFirst: Bool) {
        guard settings.claudeCLIProbe, let binary else { return }
        removeLoginScript()
        let text = ClaudeCLI.loginScript(binary, logoutFirst: logoutFirst, environment: prober.probeEnvironment)
        guard let script = try? ClaudeCLI.writeLoginScript(text) else { return }
        loginScript = script
        if let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(script)
        }
        let generation = generation
        loginWatch?.cancel()
        loginWatch = Task { [weak self] in
            for _ in 0..<75 {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard !Task.isCancelled, let self, self.generation == generation else { return }
                guard self.settings.claudeCLIProbe, self.status.needsLogin else { break }
                if !self.running { self.run(now: Date(), quiet: true) }
            }
            self?.removeLoginScript()
        }
    }

    private func removeLoginScript() {
        if let loginScript { ClaudeCLI.removeLoginScript(loginScript) }
        loginScript = nil
    }
}

/// 真的跑子进程（会阻塞，别在主线程调）
struct ProcessCommandExecutor: CLICommandExecutor {
    /// stdout 写到临时文件再读，不用管道：输出多了不会把子进程堵住。stderr 丢掉（可能带账号信息）。
    /// 每 0.1 秒看一眼取消令牌：开关关掉时马上结束子进程，不等超时
    func execute(_ binary: URL, _ arguments: [String], environment: [String: String], directory: URL,
                 timeout: TimeInterval, cancellation: CLIProbeCancellation) -> CLICommandOutput? {
        let out = directory.appendingPathComponent("out-\(UUID().uuidString).txt")
        guard FileManager.default.createFile(atPath: out.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let handle = try? FileHandle(forWritingTo: out) else { return nil }
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: out)
        }
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        process.environment = environment

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        // 检查取消和启动放在同一把锁里：关开关的同一瞬间不会再多起一个进程
        guard cancellation.performIfActive({ (try? process.run()) != nil }) == true else { return nil }

        let deadline = DispatchTime.now() + timeout
        while done.wait(timeout: .now() + 0.1) == .timedOut {
            if cancellation.isCancelled || DispatchTime.now() >= deadline {
                process.terminate()
                if done.wait(timeout: .now() + 5) == .timedOut { kill(process.processIdentifier, SIGKILL) }  // 不听 SIGTERM 的不留着
                return nil
            }
        }
        try? handle.synchronize()
        guard let data = try? Data(contentsOf: out) else { return nil }
        return CLICommandOutput(exitCode: process.terminationStatus, stdout: data)
    }
}
