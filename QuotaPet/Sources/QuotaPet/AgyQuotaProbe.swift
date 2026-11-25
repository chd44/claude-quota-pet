import Foundation
import Darwin
import QuotaPetCore

/// Runs only the official interactive /usage command. Never sends a model prompt,
/// reads credentials, or persists terminal output. Unknown layouts fail closed.
struct AgyQuotaProbe: Sendable {
    func read() async -> AgyQuotaReading {
        let worker = Task.detached(priority: .utility) { await Self.perform() }
        return await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
    }

    private static func perform() async -> AgyQuotaReading {
        let fm = FileManager.default
        let binary = fm.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/agy")
        guard fm.isExecutableFile(atPath: binary.path) else {
            return .init(status: .unavailable, message: "未找到官方 agy CLI")
        }
        // A fixed empty workspace avoids creating a new trusted project each refresh.
        let directory = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/QuotaPet/QuotaCheck", isDirectory: true)
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let attributes = try fm.attributesOfItem(atPath: directory.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  directory.resolvingSymlinksInPath().path == directory.path,
                  try fm.contentsOfDirectory(atPath: directory.path).isEmpty else {
                return .init(status: .unknown, message: "额度查询目录必须为空")
            }
        } catch { return .init(status: .unknown, message: "无法创建专用空查询目录") }
        var master: Int32 = -1, slave: Int32 = -1
        var size = winsize(ws_row: 70, ws_col: 220, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else {
            return .init(status: .unknown, message: "无法启动官方交互终端")
        }
        let terminal = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        defer { try? terminal.close(); close(master) }
        _ = fcntl(master, F_SETFL, O_NONBLOCK)
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--log-file", "/dev/null"]
        process.currentDirectoryURL = directory
        process.standardInput = terminal; process.standardOutput = terminal; process.standardError = terminal
        // Preserve only ordinary OS environment; never inspect CLI authentication stores.
        let inherited = ProcessInfo.processInfo.environment
        var environment: [String: String] = [:]
        for key in ["HOME", "PATH", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "SHELL"] { environment[key] = inherited[key] }
        environment["TERM"] = "xterm-256color"
        process.environment = environment
        let finished = ProcessExit(process)  // 先挂上结束回调再启动
        do { try process.run() } catch { return .init(status: .unknown, message: "官方 CLI 启动失败") }
        defer {
            if process.isRunning { process.terminate() }
            // 每一步都限时：不用 waitUntilExit，它偶尔漏掉结束通知、永远不返回
            if !finished.wait(timeout: 2) {
                kill(process.processIdentifier, SIGKILL)
                finished.wait(timeout: 2)
            }
        }
        var output = Data(), sent = false, trusted = false
        // 发 /usage 那一刻屏幕上已有的登录/确认提示行数（启动横幅等）：之后只认新冒出来的
        var noticeBaseline = 0
        // 面板会局部重画：按伪终端同样的行列数还原「现在屏幕上显示的」，只解析这一屏，旧帧不会混进来
        var terminalScreen = VirtualTerminal(rows: Int(size.ws_row), columns: Int(size.ws_col))
        let start = Date()
        var readyAt = start.addingTimeInterval(2)
        var lastByte = Date()
        while Date().timeIntervalSince(start) < 25 {
            if Task.isCancelled { return .init(status: .unknown, message: "查询已取消") }
            var chunk = [UInt8](repeating: 0, count: 32768)
            let count = Darwin.read(master, &chunk, chunk.count)
            if count > 0 {
                output.append(contentsOf: chunk.prefix(count)); lastByte = Date()
                terminalScreen.feed(Array(chunk.prefix(count)))
                guard output.count < 1_000_000 else { return .init(status: .unknown, message: "官方终端输出超出安全上限") }
            }
            let screen = String(decoding: output, as: UTF8.self)
            if !sent {
                if screen.contains("Do you trust the contents of this project?") {
                    guard !trusted else { return .init(status: .confirmationRequired, message: "官方 CLI 需要交互确认") }
                    // Only this freshly checked, app-owned empty directory is approved.
                    _ = "\r".withCString { Darwin.write(master, $0, 1) }
                    trusted = true; output.removeAll(); readyAt = Date().addingTimeInterval(4)
                }
                let plain = screen.replacingOccurrences(of: "\u{1B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
                let hasPrompt = plain.range(of: "(?m)^[ \t]*[›❯>][ \t]*$", options: .regularExpression) != nil
                if Date() >= readyAt && hasPrompt && plain.lowercased().contains("gemini") && !plain.contains("Do you trust") {
                    noticeBaseline = AgyQuotaParser.noticeLines(terminalScreen)
                    let command = "/usage\r"
                    _ = command.withCString { Darwin.write(master, $0, command.utf8.count) }
                    output.removeAll(); sent = true; lastByte = Date()
                }
            } else if Date().timeIntervalSince(lastByte) > 1.0 {
                let reading = AgyQuotaParser.parse(terminal: terminalScreen)
                if AgyQuotaParser.settles(reading, noticeLines: AgyQuotaParser.noticeLines(terminalScreen), baseline: noticeBaseline) {
                    return reading
                }
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return .init(status: .unknown, message: "官方额度查询超时或面板格式未识别")
    }
}
