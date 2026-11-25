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
        // Preserve only ordinary OS environment; never inspect CLI authentication stores.
        let inherited = ProcessInfo.processInfo.environment
        var environment: [String: String] = [:]
        for key in ["HOME", "PATH", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "SHELL"] { environment[key] = inherited[key] }
        environment["TERM"] = "xterm-256color"
        let rows: UInt16 = 70, columns: UInt16 = 220
        let process: PTYProcess
        do {
            process = try PTYProcess(
                executableURL: binary,
                arguments: ["--log-file", "/dev/null"],
                workingDirectory: directory,
                environment: environment,
                rows: rows,
                columns: columns
            )
        } catch PTYProcessError.ptyCreationFailed {
            return .init(status: .unknown, message: "无法启动官方交互终端")
        } catch {
            return .init(status: .unknown, message: "官方 CLI 启动失败")
        }
        defer { process.closeMaster() }
        let result = await runLoop(process: process, rows: Int(rows), columns: Int(columns))
        await shutdown(process: process)
        return result
    }

    private static func runLoop(process: PTYProcess, rows: Int, columns: Int) async -> AgyQuotaReading {
        var nowUptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
        var output = Data(), sent = false, trusted = false
        // 发 /usage 那一刻屏幕上已有的登录/确认提示内容集合：之后只认新冒出来的提示内容
        var noticeBaseline: Set<String> = []
        // 面板会局部重画：按伪终端同样的行列数还原「现在屏幕上显示的」，只解析这一屏，旧帧不会混进来
        var terminalScreen = VirtualTerminal(rows: rows, columns: columns)
        let start = nowUptime
        var readyAt = start + 2
        var lastByte = start
        var lastParse = start
        while nowUptime - start < 45 {
            if Task.isCancelled { return .init(status: .unknown, message: "查询已取消") }
            let exited = !process.isRunning
            var chunk = [UInt8](repeating: 0, count: 32768)
            let count = process.read(into: &chunk)
            if count > 0 {
                output.append(contentsOf: chunk.prefix(count)); lastByte = nowUptime
                terminalScreen.feed(Array(chunk.prefix(count)))
                guard output.count < 1_000_000 else { return .init(status: .unknown, message: "官方终端输出超出安全上限") }
            }
            if exited, count <= 0 {
                let reading = AgyQuotaParser.parse(terminal: terminalScreen)
                if reading.status == .available { return reading }
                if AgyQuotaParser.startupSignInRequired(terminalScreen) {
                    return .init(status: .signInRequired, checkedAt: Date(), message: "请先在官方 agy CLI 登录")
                }
                if sent, AgyQuotaParser.settles(reading, notices: AgyQuotaParser.noticeSet(terminalScreen), baseline: noticeBaseline) {
                    return reading
                }
                if reading.status == .confirmationRequired { return reading }
                return .init(status: .unknown, message: "官方 CLI 提前退出了")
            }
            let screen = String(decoding: output, as: UTF8.self)
            if !sent {
                if screen.contains("Do you trust the contents of this project?") {
                    guard !trusted else { return .init(status: .confirmationRequired, message: "官方 CLI 需要交互确认") }
                    // Only this freshly checked, app-owned empty directory is approved.
                    process.write("\r")
                    trusted = true
                    output.removeAll()
                    terminalScreen = VirtualTerminal(rows: rows, columns: columns)
                    readyAt = nowUptime + 4
                    lastByte = nowUptime
                }
                if nowUptime >= readyAt, nowUptime - lastByte > 1.2, AgyQuotaParser.startupSignInRequired(terminalScreen) {
                    return .init(status: .signInRequired, checkedAt: Date(), message: "请先在官方 agy CLI 登录")
                }
                let plain = screen.replacingOccurrences(of: "\u{1B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
                let hasPrompt = plain.range(of: "(?m)^[ \t]*[›❯>][ \t]*$", options: .regularExpression) != nil
                if nowUptime >= readyAt, nowUptime - lastByte > 0.5, hasPrompt,
                   plain.lowercased().contains("gemini"), !plain.contains("Do you trust") {
                    noticeBaseline = AgyQuotaParser.noticeSet(terminalScreen)
                    process.write("/usage")
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    if Task.isCancelled { return .init(status: .unknown, message: "查询已取消") }
                    process.write("\r")
                    output.removeAll(); sent = true; lastByte = nowUptime; lastParse = nowUptime
                }
            } else if nowUptime - lastByte > 1.0 {
                let reading = AgyQuotaParser.parse(terminal: terminalScreen)
                lastParse = nowUptime
                if AgyQuotaParser.settles(reading, notices: AgyQuotaParser.noticeSet(terminalScreen), baseline: noticeBaseline) {
                    return reading
                }
            } else if nowUptime - lastParse > 1.0 {
                lastParse = nowUptime
                let reading = AgyQuotaParser.parse(terminal: terminalScreen)
                if reading.status == .available { return reading }
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let finalReading = AgyQuotaParser.parse(terminal: terminalScreen)
        if finalReading.status == .available
            || (sent && AgyQuotaParser.settles(finalReading, notices: AgyQuotaParser.noticeSet(terminalScreen), baseline: noticeBaseline)) {
            return finalReading
        }
        return .init(status: .unknown, message: "官方额度查询超时或面板格式未识别")
    }

    private static func shutdown(process: PTYProcess) async {
        if process.isRunning { process.terminate() }
        if !(await process.drainWhileWaiting(timeout: 2)) {
            if process.isRunning { process.forceKill() }
            _ = await process.waitAsync(timeout: 2)
        }
    }
}
