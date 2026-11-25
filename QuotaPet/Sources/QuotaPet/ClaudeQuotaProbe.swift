import Foundation
import Darwin
import QuotaPetCore

/// 只运行官方 Claude Code CLI 的交互式 /usage：安全模式（不加载 CLAUDE.md、插件、钩子、MCP），不给任何工具，
/// 不发模型请求、不读凭据、不保存终端输出。只在认得的画面上按键；认不得就放弃，判为未知。
struct ClaudeQuotaProbe: Sendable {
    static let rows: UInt16 = 60
    static let columns: UInt16 = 160

    func read() async -> ClaudeUsageReading {
        let worker = Task.detached(priority: .utility) { await Self.perform() }
        return await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
    }

    /// 没找到命令行时卡片里的说明：缺什么、怎么办
    static var notFoundMessage: String {
        tr("没找到官方 Claude Code 命令行。装好 Claude Code（或 Claude 桌面端）后，在终端运行一次 claude 并登录，这里会自动显示额度。",
           "Couldn't find the official Claude Code command line. Install Claude Code (or the Claude desktop app), run claude once in Terminal and sign in, and your usage will show up here.")
    }

    static func binary() -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        if let installed = ClaudeCLILocator.installedCandidates(home: home).first(where: { fm.isExecutableFile(atPath: $0.path) }) {
            return installed
        }
        let root = ClaudeCLILocator.bundledRoot(home: home)
        let versions = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        for version in ClaudeCLILocator.newestFirst(versions) {
            let versionDir = root.appendingPathComponent(version, isDirectory: true)
            for hash in ((try? fm.contentsOfDirectory(atPath: versionDir.path)) ?? []).sorted() {
                let dir = versionDir.appendingPathComponent(hash, isDirectory: true)
                let executable = dir.appendingPathComponent("claude.app/Contents/MacOS/claude")
                if fm.fileExists(atPath: dir.appendingPathComponent(".verified").path), fm.isExecutableFile(atPath: executable.path) {
                    return executable
                }
            }
        }
        return nil
    }

    private static func perform() async -> ClaudeUsageReading {
        let fm = FileManager.default
        guard let binary = binary() else {
            return .init(status: .unavailable, message: notFoundMessage)
        }
        // 固定的空目录：只有它会被自动信任，也不会碰到任何项目文件
        let directory = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/QuotaPet/ClaudeQuotaCheck", isDirectory: true)
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let attributes = try fm.attributesOfItem(atPath: directory.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  directory.resolvingSymlinksInPath().path == directory.path,
                  try fm.contentsOfDirectory(atPath: directory.path).isEmpty else {
                return .init(status: .unknown, message: tr("额度查询目录必须为空", "The quota check folder must be empty"))
            }
        } catch {
            return .init(status: .unknown, message: tr("无法创建专用空查询目录", "Couldn’t create the dedicated check folder"))
        }
        let started = Date()
        // 这次查询自己的会话 ID：清理时只删它，不碰同一文件夹里别的会话
        let sessionID = UUID()
        defer { ClaudeSessionCleanup.remove(sessionID: sessionID, workingDirectory: directory, home: fm.homeDirectoryForCurrentUser) }

        var master: Int32 = -1, slave: Int32 = -1
        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else {
            return .init(status: .unknown, message: tr("无法启动官方交互终端", "Couldn’t start the official interactive terminal"))
        }
        let terminal = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        defer { try? terminal.close(); close(master) }
        _ = fcntl(master, F_SETFL, O_NONBLOCK)
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--safe-mode", "--strict-mcp-config", "--tools", "",
                             "--session-id", ClaudeSessionCleanup.idString(sessionID)]
        process.currentDirectoryURL = directory
        process.standardInput = terminal; process.standardOutput = terminal; process.standardError = terminal
        // 只给普通的系统环境变量；不碰 CLI 的登录存储
        let inherited = ProcessInfo.processInfo.environment
        var environment: [String: String] = [:]
        for key in ["HOME", "PATH", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "SHELL"] { environment[key] = inherited[key] }
        environment["TERM"] = "xterm-256color"
        process.environment = environment
        let finished = ProcessExit(process)  // 先挂上结束回调再启动
        do { try process.run() } catch {
            return .init(status: .unknown, message: tr("官方 CLI 启动失败", "The official CLI failed to start"))
        }
        defer {
            if process.isRunning {
                send("\u{1B}", to: master)
                usleep(200_000)
                send("/exit\r", to: master)
                finished.wait(timeout: 1.5)
            }
            if process.isRunning { process.terminate() }
            // 每一步都限时：不用 waitUntilExit，它偶尔漏掉结束通知、永远不返回
            if !finished.wait(timeout: 2) {
                kill(process.processIdentifier, SIGKILL)
                finished.wait(timeout: 2)
            }
        }

        var screen = VirtualTerminal(rows: Int(rows), columns: Int(columns))
        var received = 0
        var lastByte = Date()
        var answered: Set<String> = []
        var downPresses = 0
        var sentAt: Date?
        while Date().timeIntervalSince(started) < 45 {
            if Task.isCancelled { return .init(status: .unknown, message: tr("查询已取消", "Query cancelled")) }
            var chunk = [UInt8](repeating: 0, count: 32768)
            let exited = !process.isRunning  // 先看是否已退出、再读：退出前写出的内容这一次一定读得到
            let count = Darwin.read(master, &chunk, chunk.count)
            if exited, count <= 0 {
                // CLI 自己退出了（比如旧版本不认 --session-id）：不用等到超时。先认一次最后的画面：
                // 最后出现的是登录提示就是要登录（屏幕上残留的旧额度文字不算数）
                if ClaudeCLIScreen.finalScreen(screen) == .login {
                    return .init(status: .signInRequired, checkedAt: Date(),
                                 message: tr("Claude Code 命令行还没登录：在终端运行一次 claude 并登录，之后会自动读取额度。", "The Claude Code command line isn't signed in: run claude once in Terminal and sign in, then usage is read automatically."))
                }
                if ClaudeCLIScreen.rejectsSessionID(screen) {
                    return .init(status: .unknown, message: tr("官方 Claude Code CLI 版本过旧，不支持 --session-id，请更新后再查",
                                                               "The official Claude Code CLI is too old for --session-id; update it and try again"))
                }
                return .init(status: .unknown, message: tr("官方 CLI 提前退出了", "The official CLI exited early"))
            }
            if count > 0 {
                screen.feed(Array(chunk.prefix(count)))
                received += count
                lastByte = Date()
                guard received < 4_000_000 else {
                    return .init(status: .unknown, message: tr("官方终端输出超出安全上限", "Official terminal output exceeded the safety limit"))
                }
            }
            // 画面安静下来再判断，免得在半帧上按键
            guard Date().timeIntervalSince(lastByte) > 0.8 else {
                try? await Task.sleep(nanoseconds: 100_000_000)
                continue
            }
            // 屏幕上还残留着额度文字、最后却是登录提示：按登录处理，不拿残留的数字当读数
            switch ClaudeCLIScreen.finalScreen(screen) {
            case .login:
                return .init(status: .signInRequired, checkedAt: Date(),
                             message: tr("Claude Code 命令行还没登录：在终端运行一次 claude 并登录，之后会自动读取额度。", "The Claude Code command line isn't signed in: run claude once in Terminal and sign in, then usage is read automatically."))
            case .theme, .securityNotes:
                // 第一次启动的默认选项（主题「自动」、安全须知），各只确认一次
                let key = "\(ClaudeCLIScreen.classify(screen))"
                guard !answered.contains(key) else {
                    return .init(status: .confirmationRequired, message: tr("官方 CLI 需要交互确认", "The official CLI needs confirmation"))
                }
                answered.insert(key)
                send("\r", to: master); lastByte = Date()
            case .trust(let yesSelected):
                // 只信任这个专用空目录；默认选项是「否」，先移到「是」
                guard !answered.contains("trust") else {
                    return .init(status: .confirmationRequired, message: tr("官方 CLI 需要交互确认", "The official CLI needs confirmation"))
                }
                if yesSelected {
                    answered.insert("trust")
                    send("\r", to: master)
                } else {
                    guard downPresses < 2 else {
                        return .init(status: .confirmationRequired, message: tr("官方 CLI 需要交互确认", "The official CLI needs confirmation"))
                    }
                    downPresses += 1
                    send("\u{1B}[B", to: master)
                }
                lastByte = Date()
            case .prompt:
                if let sentAt {
                    // 发了 /usage 却又回到输入框：面板没出来
                    if Date().timeIntervalSince(sentAt) > 12 {
                        return .init(status: .unknown, message: tr("官方 /usage 面板没有出现", "The official /usage panel didn’t appear"))
                    }
                } else {
                    send("/usage", to: master)
                    usleep(500_000)
                    send("\r", to: master)
                    sentAt = Date(); lastByte = Date()
                }
            case .usageLoading:
                break  // 面板还在刷新：等最终的数字
            case .usageReady:
                guard sentAt != nil else { break }
                let reading = ClaudeUsageParser.parse(screen, now: Date())
                return reading
            case .unknown:
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return .init(status: .unknown, message: tr("官方额度查询超时或面板格式未识别", "The official quota query timed out or the panel wasn’t recognised"))
    }

    private static func send(_ text: String, to master: Int32) {
        _ = text.withCString { Darwin.write(master, $0, strlen($0)) }
    }

}
