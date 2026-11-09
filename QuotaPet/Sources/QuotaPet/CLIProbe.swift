import AppKit
import Foundation
import QuotaPetCore

/// 用 Claude 官方命令行补官方读数（设置 → Claude → 官方读数，默认开启、可关）。
///
/// 打开后，QuotaPet 在「你正在用、官方读数又旧了」时让命令行发一个最小请求（haiku、一个字、不带工具、不存会话），
/// 从响应里的 `rate_limit_event` 取 5 小时和每周额度的已用百分比和重置时间，存进 cli-readings.jsonl（见 ClaudeCLIReadings）。
/// 联网的是命令行，用它自己的登录：QuotaPet 不读钥匙串、不读 ~/.claude 里的凭据，只看 `auth status` 的 loggedIn / orgId。
/// 时机的判断在 Core 的 ClaudeCLIProbePolicy（能进自检）。
@MainActor
final class CLIProbe {
    private let settings: AppSettings
    private let archive: CLIReadingArchive
    private let desktopOrg: () -> String?
    /// 状态变了（设置页上显示）；读数写进去之后要重算 Claude 那一家
    var onStatus: ((ClaudeCLIProbeStatus) -> Void)?
    var onReading: (() -> Void)?

    private(set) var status: ClaudeCLIProbeStatus = .idle {
        didSet { if status != oldValue { onStatus?(status) } }
    }
    private var lastAttempt: Date?
    private var failures = 0
    private var running = false

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

    /// 开关变了：关掉就回到初始状态，打开就查一次让设置页上有结果。
    /// on 是订阅传进来的新值：@Published 在赋值前就通知，这时 settings.claudeCLIProbe 还是旧的
    func settingChanged(on: Bool, now: Date = Date()) {
        failures = 0
        lastAttempt = nil
        status = .idle
        guard on, !running else { return }
        run(now: now)
    }

    /// quiet：等登录时反复看一眼，设置页上不闪「正在查询」，没登录也不算失败（不拉长之后的退避）
    private func run(now: Date, quiet: Bool = false) {
        running = true
        lastAttempt = now
        if !quiet { status = .querying }
        let archive = archive, expectedOrg = desktopOrg()
        Task.detached(priority: .utility) { [weak self] in
            let outcome = CLIProbeRunner.run(archive: archive, expectedOrg: expectedOrg)
            await self?.finish(outcome, quiet: quiet)
        }
    }

    private func finish(_ outcome: ClaudeCLIProbeStatus, quiet: Bool = false) {
        running = false
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

    func connect() {
        if settings.claudeCLIProbe {
            if status.needsLogin { beginLogin(logoutFirst: status == .wrongAccount) }
        } else {
            loginAfterCheck = true
            settings.claudeCLIProbe = true  // settingChanged 随后会查一次，finish 里接着往下走
        }
    }

    /// 在终端里打开官方命令行的 auth login（脚本见 ClaudeCLI.loginScript）：登录在浏览器里由用户自己完成。
    /// 之后每隔几秒看一眼登录好了没有，最多等 10 分钟
    func beginLogin(logoutFirst: Bool) {
        guard let binary else { return }
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("QuotaPet-claude-login.command")
        do {
            try ClaudeCLI.loginScript(binary, logoutFirst: logoutFirst).write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        } catch { return }
        if let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(script)
        }
        loginWatch?.cancel()
        loginWatch = Task { [weak self] in
            for _ in 0..<75 {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard !Task.isCancelled, let self else { return }
                guard self.settings.claudeCLIProbe, self.status.needsLogin else { return }
                if !self.running { self.run(now: Date(), quiet: true) }
            }
        }
    }
}

/// 在后台线程上跑命令行（会阻塞，别在主线程调）
enum CLIProbeRunner {
    /// 额度读数里要读的字段在命令行的 stream-json 输出里；认不出来就是失败，退回估算
    static func run(archive: CLIReadingArchive, expectedOrg: String?) -> ClaudeCLIProbeStatus {
        guard let binary = ClaudeCLI.locate() else { return .notFound }
        let dir = archive.url.deletingLastPathComponent().appendingPathComponent("cli-probe")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // 先看登录状态（本地命令，不发请求）：只取 loggedIn、authMethod、orgId，别的字段（邮箱等）不读
        // 没登录时它的退出码不是 0，输出里 loggedIn 是 false
        guard let status = execute(binary, ["auth", "status", "--json"], in: dir, timeout: 20, requireSuccess: false),
              let object = try? JSONSerialization.jsonObject(with: status) as? [String: Any] else { return .failed(at: Date()) }
        guard object["loggedIn"] as? Bool == true else { return .notLoggedIn }
        // 用 API Key 登的不是订阅额度，读数不对，查一次还会按量计费
        guard object["authMethod"] as? String == "claude.ai" else { return .notLoggedIn }
        let org = object["orgId"] as? String
        if let expectedOrg {
            // 桌面端的组织已知：命令行没给组织就核对不了是不是同一个账号，不查（读数也不会被用）
            guard let org else { return .failed(at: Date()) }
            if org != expectedOrg { return .wrongAccount }
        }

        // --safe-mode：不加载用户的钩子、插件、CLAUDE.md，更快也更不会干扰。老版本命令行没有这个参数，先看一眼 --help，
        // 不是失败了就去掉重试：那样断网时会带着用户的钩子、插件再跑一遍
        var arguments = ["-p", "ok", "--model", "haiku", "--tools", "", "--no-session-persistence",
                         "--output-format", "stream-json", "--verbose"]
        if supportsSafeMode(binary, in: dir) { arguments.append("--safe-mode") }
        guard let output = execute(binary, arguments, in: dir, timeout: 60),
              let reading = ClaudeCLIReadings.parse(String(decoding: output, as: UTF8.self), org: org, now: Date()) else {
            return .failed(at: Date())
        }
        return archive.append(reading) ? .ok(at: reading.time) : .failed(at: Date())
    }

    /// 命令行认不认 --safe-mode（看 --help，每个命令行只问一次）
    private static func supportsSafeMode(_ binary: URL, in directory: URL) -> Bool {
        safeModeLock.lock()
        defer { safeModeLock.unlock() }
        if let known = safeModeSupport[binary.path] { return known }
        let help = execute(binary, ["--help"], in: directory, timeout: 20, requireSuccess: false)
        let supported = help.map { String(decoding: $0, as: UTF8.self).contains("--safe-mode") } ?? false
        if help != nil { safeModeSupport[binary.path] = supported }
        return supported
    }

    nonisolated(unsafe) private static var safeModeSupport: [String: Bool] = [:]
    private static let safeModeLock = NSLock()

    /// 跑一个命令，返回 stdout；超时、没跑起来、退出码不是 0（requireSuccess 时）都是 nil。
    /// stdout 写到临时文件再读，不用管道：输出多了不会把子进程堵住。stderr 丢掉（可能带账号信息）
    private static func execute(_ binary: URL, _ arguments: [String], in directory: URL, timeout: TimeInterval,
                                requireSuccess: Bool = true) -> Data? {
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
        // 要用订阅的登录：环境里的 API Key、第三方云的开关会让命令行改走别的通道（按量计费）
        var environment = ProcessInfo.processInfo.environment
        for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX",
                    "CLAUDE_CODE_USE_FOUNDRY"] {
            environment.removeValue(forKey: key)
        }
        process.environment = environment

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if done.wait(timeout: .now() + 5) == .timedOut { kill(process.processIdentifier, SIGKILL) }  // 不听 SIGTERM 的不留着
            return nil
        }
        guard !requireSuccess || process.terminationStatus == 0 else { return nil }
        try? handle.synchronize()
        return try? Data(contentsOf: out)
    }
}
