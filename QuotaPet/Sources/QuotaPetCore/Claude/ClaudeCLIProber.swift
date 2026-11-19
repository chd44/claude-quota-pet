import Foundation

// 用官方命令行补查读数的执行流程（不依赖 AppKit，自检里用假的命令执行器跑）。
// 联网的是命令行，用它自己的登录：QuotaPet 不读钥匙串、不读 ~/.claude 里的凭据，只看 `auth status` 的几个字段。
//
// 补查的安全前提（缺一个就不发请求）：
// 1. 子进程用最小环境（ClaudeCLI.probeEnvironment）：环境里的 ANTHROPIC_BASE_URL、API Key、第三方云开关等都不传，
//    不然即使登录的是订阅，请求也可能经自定义网关发出去
// 2. `auth status` 在同一个最小环境下报告：订阅登录（claude.ai）、官方通道（apiProvider 是 firstParty）、组织对得上
// 3. 命令行认 --safe-mode / --setting-sources / --strict-mcp-config：不加载用户的钩子、插件、MCP、用户和项目设置
//    （其中的 env、apiKeyHelper 也就不会生效）。`--tools ""` 只是禁用内建工具，管不到这些
// 4. 机器上没有管理员配置（managed settings）：它不能被上面的参数跳过，可能改变请求的去向，没法确认就不查

/// 命令行补查被拦下的原因（设置页和面板上说明用）
public enum ClaudeCLIProbeBlock: Equatable, Sendable {
    /// 命令行太旧、缺隔离参数
    case cliTooOld
    /// 有管理员配置，它可能改变请求的去向
    case managedSettings
    /// 命令行用的不是 Anthropic 官方通道
    case otherProvider
}

/// 取消令牌：关掉补查开关时取消在途的任务。取消后不再启动子进程、不再存结果
public final class CLIProbeCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    /// 没被取消时才执行 body，执行期间 cancel() 会等着：「检查」和「动手」之间不会插进一次取消
    public func performIfActive<T>(_ body: () -> T) -> T? {
        lock.lock(); defer { lock.unlock() }
        return cancelled ? nil : body()
    }
}

public struct CLICommandOutput: Sendable {
    public var exitCode: Int32
    public var stdout: Data

    public init(exitCode: Int32, stdout: Data) {
        self.exitCode = exitCode
        self.stdout = stdout
    }
}

/// 跑一个命令。App 里是真的子进程，自检里是假的（不联网）
public protocol CLICommandExecutor: Sendable {
    /// nil：没跑起来、超时、被取消
    func execute(_ binary: URL, _ arguments: [String], environment: [String: String], directory: URL,
                 timeout: TimeInterval, cancellation: CLIProbeCancellation) -> CLICommandOutput?
}

public final class ClaudeCLIProber: @unchecked Sendable {
    private let executor: CLICommandExecutor
    private let environment: @Sendable () -> [String: String]
    private let managedSettingsPaths: [String]
    private let clock: @Sendable () -> Date
    private let lock = NSLock()
    /// 每个命令行只问一次 --help（问到了才记：超时不算「不支持」）
    private var capabilityCache: [String: ClaudeCLI.Capabilities] = [:]

    public init(executor: CLICommandExecutor,
                environment: @escaping @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment },
                managedSettingsPaths: [String] = ClaudeCLI.managedSettingsPaths,
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.executor = executor
        self.environment = environment
        self.managedSettingsPaths = managedSettingsPaths
        self.clock = clock
    }

    /// 探测和一键登录用的环境：两边必须一样（同一个 CLAUDE_CONFIG_DIR），不然登录的和查询的是两份配置
    public var probeEnvironment: [String: String] { ClaudeCLI.probeEnvironment(from: environment()) }

    /// 会阻塞，别在主线程调。返回 nil 表示中途被取消了（结果不该再用）
    public func run(binary: URL?, archive: CLIReadingArchive, expectedOrg: String?,
                    cancellation: CLIProbeCancellation) -> ClaudeCLIProbeStatus? {
        guard let binary else { return .notFound }
        if cancellation.isCancelled { return nil }
        if ClaudeCLI.hasManagedSettings(at: managedSettingsPaths) { return .blocked(.managedSettings) }

        let dir = archive.url.deletingLastPathComponent().appendingPathComponent("cli-probe")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let env = probeEnvironment

        // 先看登录状态（本地命令，不发请求）：只取 loggedIn、authMethod、apiProvider、orgId，别的字段（邮箱等）不读。
        // 没登录时它的退出码不是 0，输出里 loggedIn 是 false
        guard let status = executor.execute(binary, ["auth", "status", "--json"], environment: env, directory: dir, timeout: 20,
                                            cancellation: cancellation) else {
            return cancellation.isCancelled ? nil : .failed(at: clock())
        }
        if cancellation.isCancelled { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: status.stdout) as? [String: Any] else { return .failed(at: clock()) }
        guard object["loggedIn"] as? Bool == true else { return .notLoggedIn }
        // 用 API Key 登的不是订阅额度，读数不对，查一次还会按量计费
        guard object["authMethod"] as? String == "claude.ai" else { return .notLoggedIn }
        // 请求要走 Anthropic 官方通道：报告里没有这个字段或者不是 firstParty，就确认不了
        guard object["apiProvider"] as? String == "firstParty" else { return .blocked(.otherProvider) }
        let org = object["orgId"] as? String
        if let expectedOrg {
            // 桌面端的组织已知：命令行没给组织就核对不了是不是同一个账号，不查（读数也不会被用）
            guard let org else { return .failed(at: clock()) }
            if org != expectedOrg { return .wrongAccount }
        }

        // 隔离参数在不在：问不到（超时）就先不查，等下次；缺参数是命令行太旧，不退回「不隔离」的查法
        guard let caps = lookupCapabilities(of: binary, in: dir, environment: env, cancellation: cancellation) else {
            return cancellation.isCancelled ? nil : .failed(at: clock())
        }
        if cancellation.isCancelled { return nil }
        guard caps.isolatesCustomizations else { return .blocked(.cliTooOld) }

        let arguments = ClaudeCLI.probeArguments(disableSlashCommands: caps.disableSlashCommands)
        guard let output = executor.execute(binary, arguments, environment: env, directory: dir, timeout: 60, cancellation: cancellation) else {
            return cancellation.isCancelled ? nil : .failed(at: clock())
        }
        guard output.exitCode == 0,
              let reading = ClaudeCLIReadings.parse(String(decoding: output.stdout, as: UTF8.self), org: org, now: clock()) else {
            return cancellation.isCancelled ? nil : .failed(at: clock())
        }
        // 存结果之前再确认一次：这期间开关被关掉了，结果就不要了
        guard let stored = cancellation.performIfActive({ archive.append(reading) }) else { return nil }
        return stored ? .ok(at: reading.time) : .failed(at: clock())
    }

    private func lookupCapabilities(of binary: URL, in directory: URL, environment: [String: String],
                              cancellation: CLIProbeCancellation) -> ClaudeCLI.Capabilities? {
        lock.lock()
        if let known = capabilityCache[binary.path] {
            lock.unlock()
            return known
        }
        lock.unlock()
        guard let help = executor.execute(binary, ["--help"], environment: environment, directory: directory, timeout: 20,
                                          cancellation: cancellation) else { return nil }
        let found = ClaudeCLI.Capabilities(help: String(decoding: help.stdout, as: UTF8.self))
        lock.lock()
        capabilityCache[binary.path] = found
        lock.unlock()
        return found
    }
}

// MARK: - 环境、参数、登录脚本

extension ClaudeCLI {
    /// 命令行认哪些隔离参数（看 --help 的文字）
    public struct Capabilities: Equatable, Sendable {
        public var safeMode: Bool
        public var settingSources: Bool
        public var strictMCPConfig: Bool
        public var disableSlashCommands: Bool

        public init(help: String) {
            safeMode = help.contains("--safe-mode")
            settingSources = help.contains("--setting-sources")
            strictMCPConfig = help.contains("--strict-mcp-config")
            disableSlashCommands = help.contains("--disable-slash-commands")
        }

        /// 钩子、插件、MCP、用户和项目设置都能关掉才查
        public var isolatesCustomizations: Bool { safeMode && settingSources && strictMCPConfig }
    }

    /// 补查进程环境里放行的变量：运行必需的（HOME、语言、临时目录）、同一份配置目录（CLAUDE_CONFIG_DIR）、
    /// 网络出口（代理、证书）。别的都不传：ANTHROPIC_*（BASE_URL、API Key、AUTH_TOKEN……）、CLAUDE_CODE_*（第三方云开关……）
    public static let probeEnvironmentKeys: [String] = [
        "HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "__CF_USER_TEXT_ENCODING",
        "CLAUDE_CONFIG_DIR",
        "HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "NO_PROXY", "https_proxy", "http_proxy", "all_proxy", "no_proxy",
        "SSL_CERT_FILE", "SSL_CERT_DIR", "NODE_EXTRA_CA_CERTS",
    ]

    public static func probeEnvironment(from environment: [String: String]) -> [String: String] {
        var result = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        for key in probeEnvironmentKeys {
            if let value = environment[key], !value.isEmpty { result[key] = value }
        }
        return result
    }

    /// 最小请求的参数。--tools "" 只是禁用内建工具；钩子、插件、MCP、用户和项目设置靠下面几个参数关掉。
    /// --setting-sources local：只读工作目录（QuotaPet 自己的空目录）里的本地设置，不读用户和项目设置
    public static func probeArguments(disableSlashCommands: Bool) -> [String] {
        var arguments = ["-p", "ok", "--model", "haiku", "--tools", "", "--no-session-persistence",
                         "--output-format", "stream-json", "--verbose",
                         "--safe-mode", "--setting-sources", "local", "--strict-mcp-config"]
        if disableSlashCommands { arguments.append("--disable-slash-commands") }
        return arguments
    }

    /// 管理员配置（macOS 上的 managed settings）。只看有没有，不读内容
    public static let managedSettingsPaths = [
        "/Library/Application Support/ClaudeCode/managed-settings.json",
        "/Library/Application Support/ClaudeCode/managed-settings.d",
    ]

    public static func hasManagedSettings(at paths: [String]) -> Bool {
        for path in paths {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
            if !isDirectory.boolValue { return true }
            if !((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).isEmpty { return true }
        }
        return false
    }

    /// 登录脚本要放在自己的私有临时目录里：目录 0700、脚本 0700（创建时就是这个权限，不是先写后改），
    /// 别人猜不到、也换不掉固定文件名的脚本
    public static func writeLoginScript(_ text: String, under base: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let directory = base.appendingPathComponent(loginDirectoryPrefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let script = directory.appendingPathComponent("login.command")
        guard FileManager.default.createFile(atPath: script.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o700]) else {
            try? FileManager.default.removeItem(at: directory)
            throw CocoaError(.fileWriteUnknown)
        }
        return script
    }

    /// 删掉登录脚本和它的私有目录（只删名字对得上的目录）
    public static func removeLoginScript(_ script: URL) {
        let directory = script.deletingLastPathComponent()
        guard directory.lastPathComponent.hasPrefix(loginDirectoryPrefix) else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    static let loginDirectoryPrefix = "QuotaPet-login-"
}
