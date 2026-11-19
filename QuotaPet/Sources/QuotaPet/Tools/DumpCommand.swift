import Foundation
import ServiceManagement
import QuotaPetCore

/// QuotaPet --dump：在终端打印当前的额度推算，方便调试、和 usage_lab.py 对账；最后附上 Codex 的读数
enum DumpCommand {
    /// QuotaPet --probe-cli：用 Claude 命令行查一次官方读数（会联网、占一个最小请求），写进 cli-readings.jsonl 并打印结果。
    /// 和 App 里「用 Claude 命令行补官方读数」跑的是同一段代码，调试用
    static func probe() {
        L10n.language = .zhHans
        let org = (try? ClaudeDesktopHistory.parse(Data(contentsOf: ClaudeDesktopHistory.defaultURL)))?.last?.org
        let archive = CLIReadingArchive()
        let started = Date()
        let prober = ClaudeCLIProber(executor: ProcessCommandExecutor())
        let status = prober.run(binary: ClaudeCLI.locate(), archive: archive, expectedOrg: org, cancellation: CLIProbeCancellation())
            ?? .failed(at: Date())
        print("\(status.text(now: Date()))（用时 \(Int(Date().timeIntervalSince(started))) 秒）")
        if let last = archive.readings().last, case .ok = status {
            print("5 小时 \(last.session.map { Fmt.percent($0) } ?? "-")，\(last.sessionResetsAt.map { Fmt.clock($0, now: Date()) } ?? "-") 重置")
            print("每周 \(last.weekly.map { Fmt.percent($0) } ?? "-")，\(last.weeklyResetsAt.map { Fmt.clock($0, now: Date()) } ?? "-") 重置")
        }
    }

    static func run() {
        L10n.language = .zhHans  // 对账工具，和 usage_lab.py 一样只输出中文
        let provider = ClaudeProvider()
        let now = Date()
        let started = Date()
        let snap: UsageSnapshot
        do {
            snap = try provider.snapshot(now: now)
        } catch {
            print("出错了：\(error.localizedDescription)")
            return
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)

        print("QuotaPet · Claude 额度（只读本机文件：不联网、不读凭据）")
        print("现在 \(Fmt.clock(now, now: now))，用时 \(ms) ms，读了 \(provider.scanner.trackedFiles) 个日志文件、\(provider.lastRequests.count) 个请求")
        print("")

        print("最近的官方读数（Claude 桌面端）：")
        for s in provider.lastSamples.suffix(6) {
            let fh = s.session.map { Fmt.percent($0) } ?? "-"
            let sd = s.weekly.map { Fmt.percent($0) } ?? "-"
            print("  \(Fmt.clock(s.time, now: now))  5h \(fh.padding(toLength: 5, withPad: " ", startingAt: 0))周 \(sd)")
        }
        print("")

        let cli = provider.cliArchive?.readings(now: now) ?? []
        if !cli.isEmpty {
            print("最近的命令行读数（设置里打开「用 Claude 命令行补官方读数」才有）：")
            for r in cli.suffix(4) {
                let fh = r.session.map { Fmt.percent($0) } ?? "-"
                let sd = r.weekly.map { Fmt.percent($0) } ?? "-"
                let resets = [r.sessionResetsAt.map { "5h 重置 \(Fmt.clock($0, now: now))" },
                              r.weeklyResetsAt.map { "周重置 \(Fmt.clock($0, now: now))" }].compactMap { $0 }.joined(separator: "，")
                print("  \(Fmt.clock(r.time, now: now))  5h \(fh.padding(toLength: 5, withPad: " ", startingAt: 0))周 \(sd)  \(resets)")
            }
            print("")
        }

        if !provider.scanner.limitEvents.isEmpty {
            print("最近的限流消息（Claude Code 日志）：")
            for l in provider.scanner.limitEvents.suffix(3) {
                print("  \(Fmt.clock(l.time, now: now))  \(l.window) 用完，\(Fmt.clock(l.resetsAt, now: now)) 恢复")
            }
            print("")
        }

        for w in snap.windows {
            var line = "\(w.title)：\(Fmt.percent(w.percent))"
            if let o = w.official, let t = w.officialAt {
                line += "（官方 \(Fmt.percent(o))，\(Fmt.ago(t, now: now))"
                line += w.estimatedExtra >= 0.05 ? String(format: " + 本机估算 %.1f%%）", w.estimatedExtra) : "）"
            }
            print(line)
            if let start = w.startedAt, let end = w.resetsAt {
                print("  窗口 \(Fmt.clock(start, now: now)) → \(Fmt.clock(end, now: now))，\(Fmt.fromNow(end.timeIntervalSince(now)))重置")
            } else {
                print("  窗口还没开始（下次使用时开始计时）")
            }
            if w.otherPercent >= 0.5 {
                print(String(format: "  其中网页、手机等其他端约 %.1f%%", w.otherPercent))
            }
            if let burn = w.burnPerHour, burn > 0 {
                let span = w.burnLookback >= 86400 ? "24 小时" : "\(Int(w.burnLookback / 60)) 分钟"
                let other = (w.otherBurnPerHour ?? 0) >= 0.05 ? String(format: "（其中其他端 %.1f%%）", w.otherBurnPerHour ?? 0) : ""
                print(String(format: "  最近 %@ 消耗速度 %.1f%%/小时", span, burn) + other)
            }
            if let t = w.projectedExhaustion(now: now) {
                print("  ⚠️ 照这个速度 \(Fmt.clock(t, now: now)) 会用完")
            }
        }
        print("")

        if let today = snap.today {
            let families = today.byFamily.map { "\($0.family) \($0.requests) 次 \(Fmt.usd($0.usd))" }.joined(separator: "，")
            print("今天本机 Claude Code：\(today.requests) 次请求，\(Fmt.tokens(today.tokens)) tokens，API 等价 \(Fmt.usd(today.usd))")
            if !families.isEmpty { print("  \(families)") }
        }

        if let e = snap.estimation {
            print(String(format: "换算率：5 小时每 1%% ≈ $%.3f，每周每 1%% ≈ $%.2f（缓存读按半价算）", e.sessionUSDPerPercent, e.weeklyUSDPerPercent))
            let learned = e.learnedIntervals > 0 ? "从 \(e.learnedIntervals) 段有用量的记录里学到" : "记录不够，用起始值"
            print("  \(learned)；一共记录了 \(e.recordedIntervals) 段 → \(IntervalArchive.defaultURL.path)")
        }

        // 和 `python3 usage_lab.py summary --hours 24` 对账
        let dayAgo = now.addingTimeInterval(-86400)
        var last24: [ModelFamily: (Int, Double)] = [:]
        for r in provider.lastRequests where r.time > dayAgo {
            let v = last24[r.family] ?? (0, 0)
            last24[r.family] = (v.0 + 1, v.1 + r.usd)
        }
        let summary = ModelFamily.allCases.compactMap { f in last24[f].map { "\(f.rawValue) \($0.0) 次 \(Fmt.usd($0.1))" } }
        print("最近 24 小时（对账用）：\(summary.joined(separator: "，"))")

        // 只有从 .app 里运行时才看得到开机自启的状态
        if Bundle.main.bundleURL.pathExtension == "app" {
            let status: String
            switch SMAppService.mainApp.status {
            case .enabled: status = "已开启"
            case .requiresApproval: status = "等你在「系统设置 → 通用 → 登录项」里批准"
            case .notRegistered: status = "未开启"
            case .notFound: status = "找不到 App"
            @unknown default: status = "未知"
            }
            print("开机自动启动：\(status)（\(Bundle.main.bundlePath)）")
        }

        if !snap.notes.isEmpty {
            print("")
            snap.notes.forEach { print("· \($0)") }
        }
        dumpCodex(now: now)
    }

    /// Codex 的读数就是官方百分比，这里只列最近几次读数和推出来的窗口
    private static func dumpCodex(now: Date) {
        let provider = CodexProvider()
        guard let snap = try? provider.snapshot(now: now) else { return }
        print("")
        print("QuotaPet · Codex 额度（只读 ~/.codex 下的对话日志：不联网、不读凭据）")
        guard snap.hasData else {
            snap.notes.forEach { print("· \($0)") }
            return
        }
        print("读了 \(provider.scanner.trackedFiles) 个日志文件，保留期内 \(provider.lastReadings.count) 次读数（Codex 总额度）")
        for r in provider.lastReadings.suffix(4) {
            let windows = r.windows.map { "\(UsageWindow.title(minutes: $0.minutes)) \(Fmt.percent($0.usedPercent))" }.joined(separator: "，")
            print("  \(Fmt.clock(r.time, now: now))  \(windows)")
        }
        for w in snap.windows {
            var line = "\(w.title)：\(Fmt.percent(w.percent))"
            if let reset = w.resetsAt {
                line += "，\(Fmt.fromNow(reset.timeIntervalSince(now)))重置（\(Fmt.clock(reset, now: now))）"
            } else {
                line += "，上次读数之后已经重置，下次使用时开始计时"
            }
            print(line)
            if let burn = w.burnPerHour, burn > 0 {
                let span = w.burnLookback >= 86400 ? "24 小时" : "\(Int(w.burnLookback / 60)) 分钟"
                print(String(format: "  最近 %@ 消耗速度 %.1f%%/小时", span, burn))
            }
            if let t = w.projectedExhaustion(now: now) {
                print("  ⚠️ 照这个速度 \(Fmt.clock(t, now: now)) 会用完")
            }
        }
        snap.notes.forEach { print("· \($0)") }
    }
}
