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

/// 自动跟随正在用的那家
func checkActiveServiceFollow() {
    let now = Date(timeIntervalSince1970: 60_000)
    let minute: TimeInterval = 60
    check(ActiveService.pick(lastActive: [:], now: now) == nil, "没有一家在用：不动")
    check(ActiveService.pick(lastActive: [.codex: now.addingTimeInterval(-11 * minute)], now: now) == nil, "10 分钟前的动静不算正在用")
    check(ActiveService.pick(lastActive: [.claude: now.addingTimeInterval(-2 * minute)], now: now) == .claude, "只有一家在用：跟它")
    check(ActiveService.pick(lastActive: [.claude: now.addingTimeInterval(-1 * minute), .antigravity: now.addingTimeInterval(-3 * minute)], now: now) == .claude,
          "几家同时在用：跟最近有动静的")
    check(ActiveService.pick(lastActive: [.claude: now.addingTimeInterval(-20), .codex: now.addingTimeInterval(-5 * minute)], now: now) == .claude
          && ActiveService.pick(lastActive: [.claude: now.addingTimeInterval(-20), .codex: now], now: now) == .codex,
          "Claude 用得更紧也不抢：刚切去用 Codex 就跟 Codex（documented/low-quota-most-recent）")
    check(ActiveService.target(enabled: true, paused: false, manualAt: nil, lastActive: [.claude: now, .codex: now], current: .claude, now: now) == nil,
          "同一时刻都有动静：留在当前这家")
    check(ActiveService.active([.claude: now.addingTimeInterval(-5 * minute), .codex: now.addingTimeInterval(-1 * minute)], now: now) == [.codex, .claude],
          "正在用的几家按最近有动静排序")
    check(!ActiveService.mayFollow(enabled: true, panelOpen: true, manualAt: nil, now: now), "面板开着时不自动切换")
    check(!ActiveService.mayFollow(enabled: true, panelOpen: false, manualAt: now.addingTimeInterval(-5 * minute), now: now),
          "手动选了之后 10 分钟内不自动切换")
    check(ActiveService.mayFollow(enabled: true, panelOpen: false, manualAt: now.addingTimeInterval(-11 * minute), now: now),
          "手动选择满 10 分钟后恢复自动跟随")
    check(!ActiveService.mayFollow(enabled: false, panelOpen: false, manualAt: nil, now: now), "关掉开关就不自动切换")
    check(ActiveService.mayFollow(enabled: true, panelOpen: false, manualElapsed: 601)
          && !ActiveService.mayFollow(enabled: true, panelOpen: false, manualElapsed: 599),
          "手动选择的保护按实际经过的时间算：系统时间回拨一小时、实际过了 601 秒照样解除（order/manual-hold-after-wall-rollback）")
    check(!ActiveService.mayFollow(enabled: true, panelOpen: false, manualElapsed: 5),
          "系统时间往前跳一小时、实际只过了 5 秒：保护还在")

    // 同一时刻都有动静：结果不随字典插入顺序变；当前这家在并列里就留着
    for current in OfficialQuotaEntry.allCases {
        let all = Dictionary(uniqueKeysWithValues: OfficialQuotaEntry.allCases.map { ($0, now) })
        check(ActiveService.target(enabled: true, paused: false, manualAt: nil, lastActive: all, current: current, now: now) == nil,
              "三家同一时刻都有动静：留在当前这家（\(current)）")
    }
    var tiedPicks = Set<OfficialQuotaEntry>()
    for flip in [false, true] {
        var tied: [OfficialQuotaEntry: Date] = [:]
        for entry in (flip ? [OfficialQuotaEntry.codex, .claude] : [.claude, .codex]) { tied[entry] = now }
        if let pick = ActiveService.target(enabled: true, paused: false, manualAt: nil, lastActive: tied, current: .antigravity, now: now) {
            tiedPicks.insert(pick)
        }
    }
    check(tiedPicks == [.claude], "当前这家不在并列里：按固定顺序选，每次一样：\(tiedPicks)")

    checkActivityLedger()
    checkRound3Follow()
    checkRound4Follow()
    checkAgyTranscript()
    checkReviewFixes()
}

/// 第四轮：新会话按出生时间算、长任务不过期、自己查询的时间窗、Codex 子代理和旧格式、history 进重扫、删除和基线的交错（数据都是编的）
func checkRound4Follow() {
    let now = Date(timeIntervalSince1970: 900_000)
    let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
    let conv = "/Users/someone/.gemini/antigravity/conversations/", history = "/Users/someone/.claude/history.jsonl"
    var disk: [String: FileStamp] = [:]
    func ledger(_ source: ActivitySource) -> ActivityLedger {
        ActivityLedger(source: source, window: ActiveService.window, stamp: { disk[$0] },
                       list: { dir in disk.keys.filter { isPath($0, inside: dir) }.sorted() })
    }
    // 旧会话晚被看见：主动开始是出生时间，不是最后那笔后台输出
    disk[conv + "old"] = FileStamp(inode: 1, size: 9, modified: now - 5, created: now - 300)
    let late = ledger(.agy(home: home)).applyFinding(ledger(.agy(home: home)).collect([URL(fileURLWithPath: conv)], now: now), now: now)
    check(late?.time == now - 5 && late?.start == now - 300, "晚被看见的旧会话：活动是最后写入的时间，主动开始是出生的时间")
    // 主动开始不按年龄过期：那家还在用就跟它
    check(ActiveService.pick(lastActive: [.codex: now - 2, .claude: now - 1], lastStart: [.codex: now - 3600, .claude: now - 7200], now: now) == .codex,
          "Codex 一小时前开始、现在还在写：Claude 的后台写入抢不走")
    // 自己查询的时间窗
    let s0 = now - 10, e0 = now - 5
    check(StartVerdict.judge(now - 7, querying: false, started: s0, ended: e0) == .own
          && StartVerdict.judge(now - 4, querying: false, started: s0, ended: e0) == .user
          && StartVerdict.judge(now - 1, querying: true, started: now - 2, ended: e0) == .undecided
          && StartVerdict.judge(now - 1, querying: false, started: nil, ended: now - 2) == .user,
          "查询进程运行期间的写入算自己的；结束后才写的算用户的；还在查询时先挂起")
    // Codex：子代理会话的开始不算；旧格式每个会话只有第一条用量算开始
    let meta = Data(#"{"type":"session_meta","timestamp":"2026-11-21T02:00:00Z","payload":{"source":{"subagent":{"depth":1}}}}"#.utf8)
    let cli = Data(#"{"type":"session_meta","timestamp":"2026-11-21T02:00:00Z","payload":{"source":"cli"}}"#.utf8)
    check(CodexRateReading.isSubagentSessionMeta(line: meta) && !CodexRateReading.isSubagentSessionMeta(line: cli), "认出子代理会话的 session_meta")
    let spaced = Data(#"{"type": "event_msg", "timestamp": "2026-11-21T02:00:01Z", "payload": {"type": "task_started"}}"#.utf8)
    let nested = Data(#"{"type":"response_item","timestamp":"2026-11-21T02:00:02Z","payload":{"type":"message","metadata":{"type":"turn_context"}}}"#.utf8)
    check(CodexRateReading.turnStart(line: spaced) != nil && CodexRateReading.turnStart(line: nested) == nil,
          "按顶层字段认开始记录：带空格的合法 JSON 认，嵌套的同名类型不认")
    // history.jsonl 进整体核对（重扫、晚接上、大批通知都能补回）
    let claude = ActivitySource.claude(home: home, ownFolder: "own")
    check(claude.scanTargets.map(\.path).contains(history), "Claude 的整体核对包括 history.jsonl")
    disk = [history: FileStamp(inode: 3, size: 10, modified: now - 1)]
    check(ledger(claude).reconcile(now: now) == now - 1, "只有重扫、没有直接事件时也能补回刚提交的提示词")
    // 删除先于首次入账：旧核对结果不能让它复活
    disk = [conv + "gone": FileStamp(inode: 4, size: 1, modified: now - 1, created: now - 1)]
    let race = ledger(.agy(home: home)), scan = race.collect([URL(fileURLWithPath: conv)], now: now)
    disk[conv + "gone"] = nil
    _ = race.observeFinding([FileEvent(path: conv + "gone", flags: [.itemRemoved])], now: now)
    check(race.applyFinding(scan, now: now) == nil, "删除通知先到、旧核对后交：不复活")
}

/// 第三轮：主动开始 vs 接着写、后台核对的旧结果、只改属性的旧文件、Codex 新一轮开始记录（数据都是编的）
func checkRound3Follow() {
    let now = Date(timeIntervalSince1970: 800_000), minute: TimeInterval = 60
    // 有主动开始时，接着写的再晚也抢不走；都没有主动开始时跟最近的动静
    let active: [OfficialQuotaEntry: Date] = [.claude: now - 10, .codex: now - 60, .antigravity: now - 5]
    check(ActiveService.pick(lastActive: active, lastStart: [.codex: now - 60, .claude: now - 300], now: now) == .codex,
          "切到 Codex 主动开始后，Claude 的后台回复、agy 的旧会话写入再晚也抢不走")
    check(ActiveService.pick(lastActive: active, lastStart: [.codex: now - 60, .claude: now - 10], now: now) == .claude,
          "回到 Claude 主动开始：跟 Claude")
    check(ActiveService.pick(lastActive: active, lastStart: [.codex: now - 11 * minute], now: now) == .codex,
          "Codex 长任务超过 10 分钟仍在写：还是它（主动开始不按年龄过期）")
    check(ActiveService.pick(lastActive: [.claude: now - 10, .codex: now - 11 * minute, .antigravity: now - 5],
                             lastStart: [.codex: now - 20 * minute], now: now) == .antigravity,
          "主动开始的那家已经停下 10 分钟：跟最近有动静的（不会一直锁在 Codex）")
    check(ActiveService.target(enabled: true, paused: false, manualElapsed: nil, lastActive: [.claude: now, .codex: now],
                               lastStart: [.claude: now, .codex: now], current: .codex, now: now) == nil,
          "同一时刻主动开始：留在当前这家")
    check(ActiveService.target(enabled: true, paused: false, manualElapsed: 30, lastActive: active, lastStart: [.claude: now - 10],
                               current: .codex, now: now) == nil, "手动选择的 10 分钟保护照旧")

    // 只改属性的事件
    check(FileEventFlags([.itemInodeMetaMod, .itemIsFile]).isMetadataOnly && !FileEventFlags([.itemInodeMetaMod, .itemModified]).isMetadataOnly
          && !FileEventFlags([]).isMetadataOnly && !FileEventFlags([.mustScanSubDirs, .itemInodeMetaMod]).isMetadataOnly,
          "只说属性变了的事件才算「只改属性」；带写入、或标志不明的不算")
    let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
    let conv = "/Users/someone/.gemini/antigravity/conversations/"
    var disk: [String: FileStamp] = [conv + "old": FileStamp(inode: 1, size: 3, modified: now - 3600, generation: Data([1]))]
    let ledger = ActivityLedger(source: .agy(home: home), window: ActiveService.window, stamp: { disk[$0] },
                                list: { dir in disk.keys.filter { isPath($0, inside: dir) }.sorted() })
    disk[conv + "old"]!.modified = now
    check(ledger.observeFinding([FileEvent(path: conv + "old", flags: [.itemInodeMetaMod, .itemIsFile])], now: now) == nil,
          "启动时很旧、账本还没见过的文件只改了修改时间：记成基线，不算活动")
    disk[conv + "old"] = FileStamp(inode: 1, size: 4, modified: now, generation: Data([2]))
    check(ledger.observeFinding([FileEvent(path: conv + "old", flags: [.itemModified])], now: now)?.time == now, "随后真正追加：算")
    // 后台核对的旧结果不能盖掉实时处理过的新版本
    disk[conv + "v"] = FileStamp(inode: 5, size: 1, modified: now - 10)
    let old = ledger.collect(ledger.source.scanTargets, now: now)
    disk[conv + "v"] = FileStamp(inode: 5, size: 2, modified: now - 1)
    check(ledger.observe(files: [conv + "v"], now: now) == now - 1, "实时处理新版：算一次")
    check(ledger.apply(old, now: now) == nil, "之后才提交的后台旧版：跳过，不再算")
    check(ledger.observe(files: [conv + "v"], now: now) == nil, "重放新版：不再算")
    // 新建会话 = 主动开始；在已有会话里接着写不是
    disk[conv + "fresh"] = FileStamp(inode: 9, size: 1, modified: now - 1, created: now - 1)
    check(ledger.observeFinding([FileEvent(path: conv + "fresh", flags: [.itemCreated])], now: now)?.start == now - 1, "agy 新建会话：主动开始")
    disk[conv + "fresh"] = FileStamp(inode: 9, size: 2, modified: now, created: now - 1)
    let more = ledger.observeFinding([FileEvent(path: conv + "fresh", flags: [.itemModified])], now: now)
    check(more?.time == now && more?.start == nil, "agy 已有会话接着写：算活动，不算主动开始")
    // 未来时间：差 0.25 秒也不算
    disk[conv + "ahead"] = FileStamp(inode: 11, size: 1, modified: now + 0.25)
    check(ledger.observe(files: [conv + "ahead"], now: now) == nil, "修改时间在未来 0.25 秒：不算")

    // Codex 新一轮开始记录：只按字节找类型和时间
    let turn = Data(#"{"timestamp":"2026-11-21T02:00:00.000Z","type":"turn_context","payload":{"cwd":"/tmp","model":"x"}}"#.utf8)
    let task = Data(#"{"payload":{"type":"task_started"},"timestamp":"2026-11-21T02:00:01Z","type":"event_msg"}"#.utf8)
    let quoted = Data(#"{"timestamp":"2026-11-21T02:00:02Z","type":"response_item","payload":{"type":"message","content":"\"type\":\"turn_context\""}}"#.utf8)
    check(CodexRateReading.turnStart(line: turn) != nil, "Codex 的 turn_context 记录算新一轮开始")
    check(CodexRateReading.turnStart(line: task) != nil, "Codex 的 task_started 事件算新一轮开始")
    check(CodexRateReading.turnStart(line: quoted) == nil, "正文里转义过的同样字样不算")
}

/// 会话文件的真实写入：只认会话路径，并且元数据（编号、大小、内容修改时间）变了；活动时间是内容修改时间（路径、元数据都是编的）
func checkActivityLedger() {
    let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
    let now = Date(timeIntervalSince1970: 500_000), minute: TimeInterval = 60
    var disk: [String: FileStamp] = [:]
    func stamp(_ inode: UInt64, _ size: UInt64, _ ago: TimeInterval) -> FileStamp {
        FileStamp(inode: inode, size: size, modified: now - ago)
    }
    func ledger(_ source: ActivitySource) -> ActivityLedger {
        ActivityLedger(source: source, window: ActiveService.window, stamp: { disk[$0] },
                       list: { dir in disk.keys.filter { isPath($0, inside: dir) }.sorted() })
    }
    let conv = "/Users/someone/.gemini/antigravity/conversations/", cli = "/Users/someone/.gemini/antigravity-cli/conversations/"
    func event(_ path: String, _ flags: FileEventFlags = [.itemModified]) -> [FileEvent] { [FileEvent(path: path, flags: flags)] }

    let agy = ActivitySource.agy(home: home)
    check(agy.roots.map(\.path) == ["/Users/someone/.gemini/antigravity-cli", "/Users/someone/.gemini/antigravity"],
          "agy 监听两个数据目录本身，conversations 后来才建也收得到")
    check(agy.isSessionFile(conv + "a.pb") && agy.isSessionFile(cli + "sub/b.pb") && !agy.isSessionFile(conv.dropLast() + "")
          && !agy.isSessionFile("/Users/someone/.gemini/antigravity/conversations-old/a.pb")
          && !agy.isSessionFile("/Users/someone/.gemini/antigravity/cache/marketplaces/index.json")
          && !agy.isSessionFile("/Users/someone/.gemini/antigravity/builtin/plugins/x.json")
          && !agy.isSessionFile("/Users/someoneelse/.gemini/antigravity/conversations/a.pb"),
          "agy 只认两个 conversations 目录里的文件：目录本身、名字相近的目录、缓存、插件、别人的目录都不算")
    check(ActivitySource.agy(home: URL(fileURLWithPath: "/var/u")).isSessionFile("/private/var/u/.gemini/antigravity/conversations/a.pb")
          && ActivitySource.agy(home: URL(fileURLWithPath: "/private/var/u")).isSessionFile("/var/u/.gemini/antigravity-cli/conversations/a.pb"),
          "FSEvents 给的 /private/var 真实路径和 /var 写法当成同一个")

    // 启动前就有的文件：接上时记成基线；window 以内改过的补记（按它的修改时间），更早的不算
    disk = [conv + "old.pb": stamp(1, 100, 3 * 3600), conv + "recent.pb": stamp(2, 50, 4 * minute)]
    let l = ledger(agy)
    let caughtUp = l.reconcile(now: now)
    check(caughtUp == now - 4 * minute, "接上监听时补记接上之前的写入，用写入时间：\(String(describing: caughtUp))")
    check(l.reconcile(now: now) == nil, "再比一遍没变化：不重复补记")
    // 维护操作：元数据（编号、大小、内容修改时间）不变，或者文件已经不在 → 不算
    check(l.observe(event(conv + "old.pb", [.itemInodeMetaMod, .itemModified, .itemCreated]), now: now) == nil,
          "改权限（macOS 合并出的标志里带着修改、新建）不算（OSflags/chmod-classification）")
    check(l.observe(event(conv + "old.pb", [.itemXattrMod]), now: now) == nil, "只改扩展属性不算（agy/xattr-only）")
    check(l.observe(event(conv + "nested", [.itemCreated, .itemIsDir]), now: now) == nil, "建子目录不算（agy/subdirectory）")
    check(l.observe(event(conv + "old.pb", []), now: now) == nil, "空标志、元数据没变不算（agy/no-evidence）")
    check(l.observe(event("/Users/someone/.gemini/antigravity/cache/index", [.itemCreated, .itemModified]), now: now) == nil,
          "缓存目录写入不算（activity/background-cache）")
    disk[conv + "old.pb"] = nil
    check(l.observe(event(conv + "old.pb", [.itemRenamed]), now: now) == nil, "把旧文件移出去（改名的源路径）不算（agy/rename-source）")
    check(l.observe(event(conv + "recent.pb", [.itemRemoved]), now: now) == nil, "删除不算")
    // 真实写入：新文件、追加、等长改写、原子替换；同一个内容版本重复通知不续期
    disk[conv + "new.pb"] = stamp(3, 10, 0)
    check(l.observe(event(conv + "new.pb", [.itemCreated]), now: now) == now, "新会话算，时间是写入时间")
    check(l.observe(event(conv + "new.pb", [.itemCreated]), now: now) == nil, "同一批通知再来一遍：内容没变，不续期")
    disk[conv + "new.pb"] = stamp(3, 25, 0) ; disk[conv + "new.pb"]!.modified = now + 1
    check(l.observe(event(conv + "new.pb"), now: now + 2) == now + 1, "追加内容算")
    disk[conv + "new.pb"] = stamp(3, 25, -5)
    check(l.observe(event(conv + "new.pb"), now: now + 6) == now + 5, "等长改写（大小不变、修改时间变了）算")
    disk[conv + "new.pb"] = stamp(9, 25, -5)
    check(l.observe(event(conv + "new.pb", [.itemRenamed]), now: now + 6) == now + 5, "临时文件原子替换到最终路径（编号变了）算")
    disk[conv + "moved-in.pb"] = stamp(4, 10, 2 * 3600)
    check(l.observe(event(conv + "moved-in.pb", [.itemRenamed]), now: now) == nil, "挪进来一个很久以前写的文件：不算现在在用")
    disk[cli + "t.pb"] = stamp(5, 1, 30)
    check(l.observe([FileEvent(path: "/Users/someone/.gemini/antigravity-cli", flags: [.mustScanSubDirs])], now: now) == now - 30,
          "事件合并或丢了：把会话目录的元数据再比一遍，有变化才算")
    check(l.observe([FileEvent(path: "/Users/someone/.gemini/antigravity-cli", flags: [.kernelDropped])], now: now) == nil,
          "再丢一次、元数据没变：不算")
    disk[conv + "a.pb"] = stamp(6, 1, 0); disk[conv + "b.pb"] = stamp(7, 1, 20)
    check(l.observe(event(conv + "b.pb") + event(conv + "a.pb"), now: now) == now, "一批里有几次写入：取最近那次的时间")

    // Claude：只认 .jsonl；QuotaPet 自己的专用目录按完整文件夹名排除，名字里碰巧含同样字样的项目照算
    let claude = ActivitySource.claude(home: home, ownFolders: ["-Users-someone-Library-Application-Support-QuotaPet-ClaudeQuotaCheck",
                                                                 "-private-Users-someone-Library-Application-Support-QuotaPet-ClaudeQuotaCheck"])
    let projects = "/Users/someone/.claude/projects/"
    check(claude.isSessionFile(projects + "-Users-someone-app/s.jsonl") && !claude.isSessionFile(projects + "-Users-someone-app/s.json")
          && !claude.isSessionFile(projects + "-Users-someone-Library-Application-Support-QuotaPet-ClaudeQuotaCheck/s.jsonl")
          && claude.isSessionFile(projects + "demo-QuotaPet-ClaudeQuotaCheck-notes/s.jsonl")
          && !claude.isSessionFile(projects + "-private-Users-someone-Library-Application-Support-QuotaPet-ClaudeQuotaCheck/s.jsonl")
          && claude.isSessionFile(projects + "demo-QuotaPet-ClaudeQuotaCheck/s.jsonl")
          && claude.isSessionFile(projects + "ordinary-project-Library-Application-Support-QuotaPet-ClaudeQuotaCheck/s.jsonl")
          && !claude.isSessionFile("/Users/someone/.claude/other/s.jsonl"),
          "Claude 只排除自己的专用目录（filter/unrelated-project-with-same-substring）")
    // 系统文件、隐藏文件不算会话；没有扩展名的会话照算
    check(!agy.isSessionFile(conv + ".DS_Store") && !agy.isSessionFile(conv + "sub/.tmp-write") && !agy.isSessionFile(conv + ".hidden/a")
          && agy.isSessionFile(conv + "turn") && agy.isSessionFile(conv + "thread/turn"),
          "agy 会话目录里 .DS_Store、隐藏的临时文件不算；没有扩展名的会话照算（agy/finder-sidecar）")
    // 内容代号：只改修改时间（touch）代号不变 → 不算；等长改写代号变 → 算
    let g1 = Data([1]), g2 = Data([2])
    disk = [conv + "g": FileStamp(inode: 20, size: 5, modified: now - 100, generation: g1)]
    let gl = ledger(agy)
    _ = gl.reconcile(now: now)
    disk[conv + "g"] = FileStamp(inode: 20, size: 5, modified: now, generation: g1)
    check(gl.observe(event(conv + "g"), now: now) == nil, "只改修改时间（touch，内容代号没变）不算（agy/touch-only）")
    disk[conv + "g"] = FileStamp(inode: 20, size: 5, modified: now + 1, generation: g2)
    check(gl.observe(event(conv + "g"), now: now + 2) == now + 1, "等长改写（内容代号变了）算")
    // 改名：编号、内容不变 → 不算；新旧路径的通知谁先到都一样
    disk = [conv + "old-session": stamp(30, 9, 90)]
    let rl = ledger(agy)
    check(rl.reconcile(now: now) == now - 90, "改名对照：接上时补记一次")
    disk[conv + "renamed-session"] = disk.removeValue(forKey: conv + "old-session")
    check(rl.observe(event(conv + "old-session", [.itemRenamed]) + event(conv + "renamed-session", [.itemRenamed]), now: now) == nil,
          "同一个文件只改名字不算（旧路径的通知先到）（rename/no-second-activity）")
    disk[conv + "again"] = disk.removeValue(forKey: conv + "renamed-session")
    check(rl.observe(event(conv + "again", [.itemRenamed]) + event(conv + "renamed-session", [.itemRenamed]), now: now) == nil,
          "同一个文件只改名字不算（新路径的通知先到）")
    disk[conv + "again"] = stamp(30, 12, 0)
    check(rl.observe(event(conv + "again"), now: now) == now, "改名之后再追加照算")
    // 未来时间：不算，也不盖掉同一批里的有效写入；时间追上以后没有新写入也不会冒出来
    disk = [conv + "real": stamp(40, 1, 1), conv + "ahead": stamp(41, 1, -90)]
    let fl = ledger(agy)
    check(fl.observe(event(conv + "real") + event(conv + "ahead"), now: now) == now - 1,
          "同一批里有修改时间在未来的文件：只算有效的那次（order/future-plus-valid-batch）")
    check(fl.observe(event(conv + "ahead"), now: now + 91) == nil, "未来时间的文件没再写：时间追上后也不算")
    check(fl.reconcile(now: now + 91) == nil, "整体核对也不会让它冒出来")

    // 来源时间：Claude 在第 0 秒写、第 2 秒才收到通知，记下的是第 0 秒（policy/delayed-callback-vs-source-time）
    disk = [projects + "-Users-someone-app/s.jsonl": stamp(10, 5, 0)]
    let c = ledger(claude)
    check(c.observe(event(projects + "-Users-someone-app/s.jsonl"), now: now + 2) == now, "Claude 的活动时间是写入时间，不是收到通知的时间")
}

/// agy 步骤记录：只认用户自己发的消息（来源 USER_EXPLICIT、类型 USER_INPUT），只看 content 之前的部分（数据都是编的）
func checkAgyTranscript() {
    let user = Data(#"{"step_index":2,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-11-21T06:26:22Z","content":"hi"}"#.utf8)
    let model = Data(#"{"step_index":3,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-21T06:26:23Z","content":"ok"}"#.utf8)
    let quoted = Data(#"{"step_index":4,"source":"MODEL","type":"PLANNER_RESPONSE","created_at":"2026-11-21T06:26:24Z","content":"\"source\":\"USER_EXPLICIT\",\"type\":\"USER_INPUT\""}"#.utf8)
    let after = Data(#"{"step_index":5,"source":"SYSTEM","type":"SYSTEM_MESSAGE","created_at":"2026-11-21T06:26:25Z","content":"x","note":{"source":"USER_EXPLICIT","type":"USER_INPUT"}}"#.utf8)
    let spaced = Data(#"{"step_index": 6, "source": "USER_EXPLICIT", "type": "USER_INPUT", "created_at": "2026-11-21T06:26:26Z", "content": "again"}"#.utf8)
    check(AgyTranscript.userInputTime(line: user) == ISO8601DateFormatter().date(from: "2026-11-21T06:26:22Z"), "用户自己发的消息：取 created_at")
    check(AgyTranscript.userInputTime(line: model) == nil, "模型回复不算")
    check(AgyTranscript.userInputTime(line: quoted) == nil, "正文里转义过的同样字样不算")
    check(AgyTranscript.userInputTime(line: after) == nil, "content 之后才出现的字段不看")
    check(AgyTranscript.userInputTime(line: spaced) != nil, "带空格的合法 JSON 也认")
    let roots = [URL(fileURLWithPath: "/Users/someone/.gemini/antigravity")]
    check(AgyTranscript.isTranscript("/Users/someone/.gemini/antigravity/brain/abc/.system_generated/logs/transcript.jsonl", roots: roots)
          && !AgyTranscript.isTranscript("/Users/someone/.gemini/antigravity/brain/abc/.system_generated/logs/transcript_full.jsonl", roots: roots)
          && !AgyTranscript.isTranscript("/Users/someone/.gemini/antigravity/brain/abc/x/.system_generated/logs/transcript.jsonl", roots: roots)
          && !AgyTranscript.isTranscript("/Users/someoneelse/.gemini/antigravity/brain/abc/.system_generated/logs/transcript.jsonl", roots: roots),
          "只认 brain/<会话>/.system_generated/logs/transcript.jsonl")

    // 增量读：第一次见到读末尾一段；之后只读新追加的行，同一行只算一次
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("quotapet-agy-transcript-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("transcript.jsonl")
    let base = ISO8601DateFormatter().date(from: "2026-11-21T06:26:00Z")!
    func line(_ source: String, _ type: String, _ at: Date) -> String {
        let f = ISO8601DateFormatter()
        return #"{"step_index":0,"source":"\#(source)","type":"\#(type)","status":"DONE","created_at":"\#(f.string(from: at))","content":"x"}"# + "\n"
    }
    func append(_ text: String) {
        if let h = try? FileHandle(forWritingTo: file) { h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close() }
        else { try! text.write(to: file, atomically: false, encoding: .utf8) }
    }
    append(line("USER_EXPLICIT", "USER_INPUT", base - 3600) + line("MODEL", "PLANNER_RESPONSE", base - 3599))
    let reader = AgyTranscriptReader()
    check(reader.read(file.path, now: base, window: 600) == nil, "第一次见到：一小时前的用户消息不算现在在用")
    append(line("MODEL", "PLANNER_RESPONSE", base + 1))
    check(reader.read(file.path, now: base + 2, window: 600) == nil, "后台回复（模型的行）追加：不算主动开始")
    append(line("USER_EXPLICIT", "USER_INPUT", base + 10) + line("MODEL", "PLANNER_RESPONSE", base + 11))
    check(reader.read(file.path, now: base + 12, window: 600) == base + 10, "用户回到原会话再发一条：算，时间是消息自己的时间")
    check(reader.read(file.path, now: base + 13, window: 600) == nil, "没有新行：不再算")
    append(line("USER_EXPLICIT", "USER_INPUT", base + 100))
    check(reader.read(file.path, now: base + 50, window: 600) == nil, "时间在未来的不算")
    let fresh = AgyTranscriptReader()
    check(fresh.read(file.path, now: base + 120, window: 600) == base + 100, "晚接上（第一次见到）：末尾一段里 window 以内的用户消息补回来")
}

/// PR #12 评审意见的两处：步骤记录第一次读到半行、整个 Claude 项目目录移进来（真实临时文件）
func checkReviewFixes() {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("quotapet-review-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: dir) }
    try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
    // 1. 用户消息那一行第一次读时只写了一半：写完以后要能读到
    let file = dir.appendingPathComponent("transcript.jsonl")
    let now = Date(timeIntervalSince1970: (Date().timeIntervalSince1970).rounded(.down))
    let stamp = ISO8601DateFormatter().string(from: now - 5)
    let line = #"{"step_index":3,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"\#(stamp)","content":"hello"}"# + "\n"
    let head = String(line.prefix(40)), tail = String(line.dropFirst(40))
    try! (#"{"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","created_at":"\#(stamp)","content":"ok"}"# + "\n" + head)
        .write(to: file, atomically: false, encoding: .utf8)
    let reader = AgyTranscriptReader()
    check(reader.read(file.path, now: now, window: 600) == nil, "第一次读到半行用户消息：先不算")
    let h = try! FileHandle(forWritingTo: file); h.seekToEndOfFile(); h.write(Data(tail.utf8)); try! h.close()
    check(reader.read(file.path, now: now, window: 600) == now - 5, "那一行写完以后读到整行，算这次用户消息（PR #12 评审 P2）")

    // 2. 整个 Claude 项目目录移进 ~/.claude/projects：核对里面最近的会话
    let home = dir.appendingPathComponent("home")
    let projects = home.appendingPathComponent(".claude/projects")
    try! fm.createDirectory(at: projects, withIntermediateDirectories: true)
    let staged = dir.appendingPathComponent("staged-project")
    try! fm.createDirectory(at: staged, withIntermediateDirectories: true)
    try! Data("{}\n".utf8).write(to: staged.appendingPathComponent("s.jsonl"))
    let ledger = ActivityLedger(source: .claude(home: home, ownFolder: "own"), window: 600)
    _ = ledger.reconcile(now: Date())
    let moved = projects.appendingPathComponent("-Users-someone-moved")
    try! fm.moveItem(at: staged, to: moved)
    check(ledger.observe([FileEvent(path: moved.path, flags: [.itemRenamed, .itemIsDir])], now: Date()) != nil,
          "整个项目目录移进 projects：核对里面最近的会话（PR #12 评审 P2）")
    let own = dir.appendingPathComponent("own-staged")
    try! fm.createDirectory(at: own, withIntermediateDirectories: true)
    try! Data("{}\n".utf8).write(to: own.appendingPathComponent("s.jsonl"))
    try! fm.moveItem(at: own, to: projects.appendingPathComponent("own"))
    check(ledger.observe([FileEvent(path: projects.appendingPathComponent("own").path, flags: [.itemRenamed, .itemIsDir])], now: Date()) == nil,
          "QuotaPet 自己查额度的专用目录移进来：不算")
}
