import Foundation
import QuotaPetCore

/// 官方 Claude Code CLI /usage：终端还原、画面识别、面板解析、过期规则。全部是合成的终端输出。
func checkClaudeCLIUsage() {
    // MARK: 终端模拟器
    var vt = VirtualTerminal(rows: 6, columns: 40)
    vt.feed("Current session\r\n\u{1B}[3G50% used")
    // 局部重画：只改变化的字符（光标前移跳过没变的部分）
    vt.feed("\u{1B}[2;3H7")
    check(vt.lines[1] == "  70% used", "终端局部重画覆盖旧字符")
    vt.feed("\u{1B}[1;9H\u{1B}[K")
    check(vt.lines[0] == "Current", "清到行尾")
    vt.feed("\u{1B}7\u{1B}[5;1Hbottom\u{1B}8X")
    check(vt.lines[4] == "bottom" && vt.lines[0] == "Current X", "保存 / 恢复光标位置")
    vt.feed("\u{1B}]0;title\u{07}\u{1B}[1mbold\u{1B}[0m\u{1B}[?25l")
    check(!vt.normalizedText.contains("title") && vt.lines[0].hasSuffix("bold"), "颜色、窗口标题和私有模式不当作文字")
    var split = VirtualTerminal(rows: 2, columns: 20)
    let bytes = Array("\u{1B}[1;3Hé█".utf8)
    split.feed(Array(bytes.prefix(3)))
    split.feed(Array(bytes.dropFirst(3).prefix(4)))
    split.feed(Array(bytes.dropFirst(7)))
    check(split.lines[0] == "  é█", "控制序列和 UTF-8 字符被切成几段送来也能还原")
    var scroll = VirtualTerminal(rows: 2, columns: 10)
    scroll.feed("a\r\nb\r\nc")
    check(scroll.lines == ["b", "c"], "写到最后一行再换行时整屏上滚")
    var clear = VirtualTerminal(rows: 3, columns: 10)
    clear.feed("x\r\ny\r\nz\u{1B}[2J")
    check(clear.normalizedText.isEmpty, "清屏")

    // MARK: 面板画面
    let now = Date(timeIntervalSince1970: 1_795_000_000)  // 2026-11-18 某时（UTC）
    func panel(_ body: String) -> VirtualTerminal {
        var t = VirtualTerminal(rows: 40, columns: 100)
        t.feed(body.replacingOccurrences(of: "\n", with: "\r\n"))
        return t
    }
    let usage = """
       Settings  Status   Config   Usage   Stats
       Current session
       ████████▌                                     18% used
       Resets 4:20am (Australia/Sydney)

       Current week (all models)
       ████████████████████                          41% used
       Resets Nov 22 at 10am (Australia/Sydney)

       Current week (Sonnet only)
       █                                             3% used

       What's contributing to your usage?
       80%  Start fresh when you switch tasks · run /clear
       Esc to cancel
    """
    let screen = panel(usage)
    check(ClaudeCLIScreen.classify(screen) == .usageReady, "认出 /usage 面板")
    check(ClaudeCLIScreen.classify(panel(usage + "\n   ✶ Refreshing…")) == .usageLoading, "面板还在刷新时等最终数字")
    let reading = ClaudeUsageParser.parse(screen, now: now)
    check(reading.status == .available && reading.windows.count == 3, "读出 5 小时、每周和单独模型三个窗口")
    check(reading.windows.map(\.usedPercent) == [18, 41, 3], "百分比就是面板上的已用")
    check(reading.windows[2].kind == .weekModel("Sonnet only") && reading.windows[2].resetsAt == nil,
          "没有 Resets 行的窗口不编重置时间")
    check(!reading.windows.contains { $0.usedPercent == 80 }, "「What's contributing」里的百分比不当额度")
    var sydney = Calendar(identifier: .gregorian)
    sydney.timeZone = TimeZone(identifier: "Australia/Sydney")!
    if let reset = reading.windows[0].resetsAt {
        let parts = sydney.dateComponents([.hour, .minute], from: reset)
        check(parts.hour == 4 && parts.minute == 20 && reset > now && reset <= now.addingTimeInterval(86400),
              "只有钟点的重置时间按面板时区取下一次")
    } else { check(false, "5 小时窗口有重置时间") }
    if let reset = reading.windows[1].resetsAt {
        let parts = sydney.dateComponents([.month, .day, .hour], from: reset)
        check(parts.month == 11 && parts.day == 22 && parts.hour == 10, "带日期的重置时间按面板时区换算")
    } else { check(false, "每周窗口有重置时间") }

    // 重置时间的各种写法和边界
    let dec30 = Date(timeIntervalSince1970: 1_798_588_800)  // 2026-12-30 UTC
    let jan = ClaudeUsageParser.parse(lines: ["Current week (all models)", "41% used", "Resets Jan 2 at 9:59am (Australia/Sydney)"], now: dec30)
    check(jan.windows.first?.resetsAt.map { sydney.component(.year, from: $0) } == 2027, "年底看到 1 月的重置时间算到明年")
    let comma = ClaudeUsageParser.parse(lines: ["Current week", "5% used", "Resets Nov 22, 10am (Australia/Sydney)"], now: now)
    check(comma.windows.first?.resetsAt != nil, "「Nov 22, 10am」写法也认得")
    let badZone = ClaudeUsageParser.parse(lines: ["Current session", "5% used", "Resets 4am (Nowhere/Zone)"], now: now)
    check(badZone.status == .available && badZone.windows.first?.resetsAt == nil, "认不出的时区不编重置时间，但百分比照用")
    let far = ClaudeUsageParser.parse(lines: ["Current week", "5% used", "Resets Mar 3 at 10am (Australia/Sydney)"], now: now)
    check(far.windows.first?.resetsAt == nil, "离现在超过一周多的重置时间不可信")
    check(ClaudeUsageParser.parse(lines: ["Current session", "120% used"], now: now).status == .unknown, "超出 0–100 的百分比不收")
    check(ClaudeUsageParser.parse(lines: ["Some new layout", "18% used"], now: now).status == .unknown, "版式变了就是未知，不猜")
    check(ClaudeUsageParser.parse(lines: ["Current session", "Resets 4am (Australia/Sydney)"], now: now).status == .unknown,
          "没有「% used」就没有读数")

    // 别的画面：只在认得的画面上按键
    check(ClaudeCLIScreen.classify(panel("Choose the text style that looks best with your terminal\n❯ Auto")) == .theme, "认出主题选择")
    check(ClaudeCLIScreen.classify(panel("Security notes:\nPress Enter to continue…")) == .securityNotes, "认出安全须知")
    check(ClaudeCLIScreen.classify(panel("Quick safety check\n❯ No, exit\n  Yes, I trust this folder")) == .trust(yesSelected: false),
          "信任框默认停在「否」")
    check(ClaudeCLIScreen.classify(panel("Quick safety check\n  No, exit\n❯ Yes, I trust this folder")) == .trust(yesSelected: true),
          "光标移到「是」之后才确认")
    check(ClaudeCLIScreen.classify(panel("Select login method:\n❯ Claude account")) == .login, "认出登录页，不替用户登录")
    check(ClaudeCLIScreen.classify(panel("────────\n❯ \n────────\n? for shortcuts")) == .prompt, "认出输入框")
    check(ClaudeCLIScreen.classify(panel("something else entirely")) == .unknown, "认不得的画面不按键")

    // MARK: 过期和重置
    let fresh = reading.snapshot(now: now.addingTimeInterval(60))
    check(fresh.hasData && fresh.windows.map(\.id) == ["five_hour", "seven_day", "seven_day_sonnet_only"], "读数变成三个窗口")
    check(fresh.windows.allSatisfy { $0.official == $0.percent && $0.estimatedExtra == 0 }, "Claude 百分比全是官方读数")
    check(fresh.windows[0].resetsAt == reading.windows[0].resetsAt && fresh.windows[0].scheduleKnown, "重置时间来自官方面板")
    let expired = reading.snapshot(now: now.addingTimeInterval(ClaudeUsageReading.freshFor + 1))
    check(!expired.hasData && expired.windows.isEmpty, "超过 15 分钟的读数是未知")
    check(MenuBarText.make(expired, mode: .session, now: now.addingTimeInterval(ClaudeUsageReading.freshFor + 1)).text.isEmpty,
          "过期时菜单栏不显示数字")
    let shortSession = ClaudeUsageReading(status: .available, windows: [.init(kind: .session, usedPercent: 60, resetsAt: now.addingTimeInterval(120))],
                                          checkedAt: now)
    let afterReset = shortSession.snapshot(now: now.addingTimeInterval(180))
    check(afterReset.windows.first.map { $0.percent == 0 && $0.official == nil } == true, "过了重置时间的窗口不沿用旧读数")
    check(shortSession.nextChange(after: now.addingTimeInterval(1)) == now.addingTimeInterval(120), "到重置时刻也唤醒刷新界面")
    let soon = now.addingTimeInterval(2 * 3600)
    let earlier = ClaudeUsageReading(status: .available, windows: [.init(kind: .session, usedPercent: 10, resetsAt: soon)],
                                     checkedAt: now.addingTimeInterval(-1800))
    let latest = ClaudeUsageReading(status: .available, windows: [.init(kind: .session, usedPercent: 18, resetsAt: soon)], checkedAt: now)
    let withHistory = latest.snapshot(now: now, history: [earlier])
    check((withHistory.windows.first?.burnPerHour ?? 0) > 0, "同一窗口的历次 CLI 读数用来算速度")
    for status in [ClaudeUsageReading.Status.signInRequired, .confirmationRequired, .unavailable, .unknown] {
        let s = ClaudeUsageReading(status: status, checkedAt: now, message: "x").snapshot(now: now)
        check(!s.hasData && s.notes == ["x"], "没有读数（\(status.rawValue)）时未知并说明原因")
    }
    check(PetStatus.of(ClaudeUsageReading(status: .unknown, checkedAt: now).snapshot(now: now), now: now, lateNight: false).mood != .exhausted,
          "未知时不显示紧张的表情")

    // MARK: 找 CLI
    check(ClaudeCLILocator.newestFirst(["2.1.99", "2.1.326", "2.0.5", "beta", "2.1.326.1"]) == ["2.1.326.1", "2.1.326", "2.1.99", "2.0.5"],
          "版本号按数字从新到旧，非版本目录不要")
    check(ClaudeCLILocator.installedCandidates(home: URL(fileURLWithPath: "/Users/someone")).allSatisfy { !$0.path.contains("..") },
          "只在固定位置找 CLI")
    check(ClaudeCLILocator.sessionFolderName(for: URL(fileURLWithPath: "/Users/someone/Library/Application Support/QuotaPet/ClaudeQuotaCheck"))
          == "-Users-someone-Library-Application-Support-QuotaPet-ClaudeQuotaCheck", "专用检查目录的会话文件夹名和 CLI 一致")
}

/// 手动刷新、Codex 过期、读数缓存
func checkRefreshAndExpiry() {
    let now = Date(timeIntervalSince1970: 50_000)
    var policy = AgyRefreshPolicy()
    policy.select(true)
    check(policy.begin(now: now), "启动后立刻读一次")
    check(!policy.beginManual(now: now.addingTimeInterval(5)), "正在读时手动刷新不并发")
    policy.finish()
    check(!policy.beginManual(now: now.addingTimeInterval(10)), "离上次不到 30 秒不重复启动 CLI")
    check(policy.beginManual(now: now.addingTimeInterval(31)), "隔 30 秒以上可以手动刷新，不用等 15 分钟")
    policy.finish()
    check(!policy.begin(now: now.addingTimeInterval(60)), "手动刷新后定时读取重新计时")
    policy.setSleeping(true)
    check(!policy.beginManual(now: now.addingTimeInterval(200)), "睡眠时不读")

    var activity = AgyRefreshPolicy()
    activity.select(true)
    check(activity.begin(now: now), "启动读一次")
    activity.finish()
    check(!activity.beginActivity(now: now.addingTimeInterval(120)), "干活时离上次读不到 3 分钟不再读")
    check(activity.beginActivity(now: now.addingTimeInterval(181)), "干完活离上次读超过 3 分钟就自动读")
    check(!activity.beginActivity(now: now.addingTimeInterval(182)), "自动读时不并发")

    // Codex：超过 1 小时的读数是未知
    let window = UsageWindow(id: "seven_day", title: UsageWindow.title(minutes: 10080), duration: 7 * 86400, percent: 94,
                             official: 94, officialAt: now, resetsAt: now.addingTimeInterval(86400))
    let codex = UsageSnapshot(provider: .codex, windows: [window], generatedAt: now, officialAt: now, notes: [])
    check(CodexProvider.expiringStale(codex, now: now.addingTimeInterval(59 * 60)).hasData, "Codex 1 小时内的读数照用")
    let expired = CodexProvider.expiringStale(codex, now: now.addingTimeInterval(3600))
    check(!expired.hasData && expired.windows.isEmpty && expired.notes.count == 1, "Codex 读数超过 1 小时是未知并说明")
    check(MenuBarText.make(expired, mode: .tightest, now: now.addingTimeInterval(3600)).text.isEmpty, "Codex 过期时菜单栏不显示数字")
    check(!CodexProvider.isStale(codex, now: now.addingTimeInterval(59 * 60)) && CodexProvider.isStale(codex, now: now.addingTimeInterval(3600)),
          "Codex 读数超过 1 小时算旧读数（面板变灰显示，不清空）")
    let claude = UsageSnapshot(provider: .claude, windows: [window], generatedAt: now, officialAt: now, notes: [])
    check(CodexProvider.expiringStale(claude, now: now.addingTimeInterval(7200)).hasData, "Codex 的过期规则不动别家")

    // 缓存：读数能原样存取
    let reading = ClaudeUsageReading(status: .available, windows: [.init(kind: .session, usedPercent: 38, resetsAt: now),
                                                                  .init(kind: .weekModel("Sonnet only"), usedPercent: 3, resetsAt: nil)],
                                     checkedAt: now)
    let decoded = (try? JSONEncoder().encode(reading)).flatMap { try? JSONDecoder().decode(ClaudeUsageReading.self, from: $0) }
    check(decoded == reading, "Claude 读数缓存能原样还原")
    let agy = AgyQuotaParser.parse("""
    Models & Quota
    GEMINI MODELS
    Weekly Limit Remaining
    [█] 62.50%
    Five Hour Limit Remaining
    [█] 81.00%
    CLAUDE AND GPT MODELS
    Weekly Limit Remaining
    [█] 91.00%
    Five Hour Limit Remaining
    [█] 30.00%
    Within each group, models share a weekly limit and a 5-hour limit.
    """, now: now)
    let agyBack = (try? JSONEncoder().encode(agy)).flatMap { try? JSONDecoder().decode(AgyQuotaReading.self, from: $0) }
    check(agyBack?.windows == agy.windows && agyBack?.remainingPercent == 30, "agy 读数缓存能原样还原")
}
