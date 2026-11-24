import Foundation
import QuotaPetCore

func checkAgyQuotaParser() {
    // Synthetic values in the observed official layout (agy 1.5.15: Argon 并入 Gemini 组); no real account fixture.
    let panel = """
    └ Models & Quota
      Account: user@example.com
    GEMINI MODELS
      Models within this group: Gemini 4 Neon, Gemini 4 Carbon, Gemini 4 Argon, Orchestrator (Argon), Gemini 3.8 Flash
      Weekly Limit Remaining
    [████░] 62.50%
    Quota available
      Five Hour Limit Remaining
    [████] 81.00%
    Quota available
    CLAUDE AND GPT MODELS
      Models within this group: Claude Opus 5.5, Claude Sonnet 5.5, GPT-OSS 120B
      Weekly Limit Remaining
    [██░░] 24.25%
    Refreshes in 72h 15m
      Five Hour Limit Remaining
    [████] 100.00%
    Quota available
      │Within each group, models share a weekly limit and a 5-hour limit. Quota is
      │consumed proportionally to the cost of the tokens.
    """
    let now = Date(timeIntervalSince1970: 1000)
    let reading = AgyQuotaParser.parse(panel, now: now)
    check(reading.status == .available && reading.remainingPercent == 24.25, "agy 取所有明确窗口中最低的剩余额度")
    check(reading.groupTitle == "Claude / GPT" && reading.windowTitle == "每周", "agy 最紧张窗口带上所在组和窗口")
    check(reading.windows.map { $0.group + "|" + $0.window } == ["Gemini|每周", "Gemini|五小时", "Claude / GPT|每周", "Claude / GPT|五小时"],
          "agy 新版面板只有两组四个窗口：组内模型名单里提到 Argon 不另开一组")
    check(reading.windows[0].resetsAt == nil, "agy「Quota available」不是重置时间")
    check(reading.resetsAt == now.addingTimeInterval(72 * 3600 + 15 * 60), "agy 仅依据官方 refresh 文本计算重置时刻")
    check(reading.checkedAt == now, "agy 读数保留查询时刻")
    check(AgyQuotaParser.parse(panel.replacingOccurrences(of: "24.25%", with: "0%")).remainingPercent == 0, "agy 官方确实显示零时才返回零")
    check(AgyQuotaParser.parse(panel.replacingOccurrences(of: "24.25%", with: "101%")).status == .unknown, "agy 超范围百分比使整屏未知")
    check(AgyQuotaParser.parse(panel.replacingOccurrences(of: "Within each group, models share a weekly limit and a 5-hour limit.", with: "")).status == .unknown, "agy 未画完说明段的面板不提前返回")
    // 还没更新的旧版 CLI：Argon 单独一栏每周额度，仍按官方面板读出来
    let legacyPanel = """
    Models & Quota
    GEMINI MODELS
    Weekly Limit Remaining
    [████░] 62.50%
    Five Hour Limit Remaining
    [████] 81.00%
    CLAUDE AND GPT MODELS
    Weekly Limit Remaining
    [████] 91.00%
    Five Hour Limit Remaining
    [████] 100.00%
    Gemini 4 Argon Weekly Limit
    [██░░] 24.25%
    Refreshes in 72h 15m
    Within each group, models share a weekly limit and a 5-hour limit.
    """
    let legacy = AgyQuotaParser.parse(legacyPanel, now: now)
    check(legacy.windows.count == 5 && legacy.groupTitle == "Gemini Argon" && legacy.windowTitle == "每周" && legacy.remainingPercent == 24.25,
          "旧版 agy 单列的 Argon 每周窗口不沿用 Claude 标签")
    check(AgyQuotaParser.parse("Models & Quota\nGEMINI MODELS\nWeekly Limit Remaining\n[bar] 20%").status == .unknown, "agy 截断面板不冒充所有模型的最低值")
    check(AgyQuotaParser.parse(panel.replacingOccurrences(of: "Weekly Limit Remaining", with: "Weekly Limit Used")).status == .unknown, "agy 不混淆已用与剩余")
    check(AgyQuotaParser.parse("You are currently not signed in.").status == .signInRequired, "agy 登录面板不解析额度")
    check(AgyQuotaParser.parse("Do you trust the contents of this project?").status == .confirmationRequired, "agy 交互确认面板不解析额度")
    check(AgyQuotaParser.parse("\u{1B}[2J\u{1B}[H" + panel).remainingPercent == 24.25, "agy 接受终端清屏 ANSI 而不泄漏控制符")
    check(AgyQuotaParser.parse(panel.replacingOccurrences(of: "GEMINI MODELS", with: "UNKNOWN MODELS")).status == .unknown, "agy 新模型组格式须重新核实")
}

/// 面板要把官方 /usage 的每个窗口都画出来，各自判断是否到了重置时间。
func checkAgyPanelWindows() {
    let panel = """
    Models & Quota
    GEMINI MODELS
    Weekly Limit Remaining
    [████░] 62.50%
    Refreshes in 72h 15m
    Five Hour Limit Remaining
    [████] 81.00%
    Refreshes in 2h
    CLAUDE AND GPT MODELS
    Weekly Limit Remaining
    [████] 91.00%
    Five Hour Limit Remaining
    [████] 30.00%
    Refreshes in 10m
    Within each group, models share a weekly limit and a 5-hour limit.
    """
    let now = Date(timeIntervalSince1970: 10_000)
    let reading = AgyQuotaParser.parse(panel, now: now)
    check(reading.windows.map { $0.group + "|" + $0.window } ==
          ["Gemini|每周", "Gemini|五小时", "Claude / GPT|每周", "Claude / GPT|五小时"],
          "agy 读数按官方顺序保留全部窗口")
    check(reading.windows.map(\.remainingPercent) == [62.5, 81, 91, 30], "agy 每个窗口保留各自的剩余百分比")
    check(reading.windows[1].resetsAt == now.addingTimeInterval(7200) && reading.windows[2].resetsAt == nil,
          "agy 重置时间只跟在它下面的窗口，不串到别的窗口")
    check(reading.remainingPercent == 30 && reading.groupName == "Claude / GPT · 五小时", "最紧张字段仍取最低剩余")

    let fresh = AgyQuotaPresentation(reading: reading, now: now.addingTimeInterval(60))
    check(fresh.windows.count == 4, "新鲜读数时面板画出全部 4 个窗口")
    check(fresh.windows.map(\.usedPercent) == [37.5, 19, 9, 70], "面板按已用 = 100 − 官方剩余显示")
    check(fresh.windows.filter(\.isTightest).map(\.id) == ["Claude / GPT · 五小时"], "只标一个最紧张窗口")
    check(fresh.windows.allSatisfy { $0.title.contains($0.group) }, "窗口标题带上模型组")

    // 11 分钟后最紧张的五小时窗口已重置：整体回到未知（菜单栏无数字），其余窗口仍可读
    let afterTightReset = AgyQuotaPresentation(reading: reading, now: now.addingTimeInterval(11 * 60))
    check(afterTightReset.usedPercent == nil && afterTightReset.mood == .normal, "最紧张窗口过了重置点：整体未知、中性形象")
    let tight = afterTightReset.windows.first { $0.id == "Claude / GPT · 五小时" }
    check(tight?.usedPercent == nil && tight?.remainingPercent == nil, "过了重置点的那张卡片单独回到未知")
    check(afterTightReset.windows.first { $0.id == "Gemini · 每周" }?.usedPercent == 37.5, "没到重置点的窗口不受影响")
    check(MenuBarPercent.text(usedPercent: afterTightReset.usedPercent, mode: .tightest) == nil, "未知时菜单栏不显示数字")

    let expired = AgyQuotaPresentation(reading: reading, now: now.addingTimeInterval(AgyRefreshPolicy.interval + 1))
    check(expired.windows.isEmpty && expired.usedPercent == nil, "读数过期后所有窗口都不再显示百分比")
    check(AgyQuotaPresentation(reading: nil).windows.isEmpty, "没有读数时没有窗口")
    check(AgyQuotaPresentation(reading: AgyQuotaParser.parse("You are currently not signed in.", now: now), now: now).windows.isEmpty,
          "未登录时没有窗口")
    check(fresh.nextUpdateDelay(defaultDelay: 900, now: now.addingTimeInterval(60)) == 9 * 60,
          "最早一个窗口的重置时刻也会唤醒刷新界面")

    // 只有最紧张字段的旧式读数也能画出一张卡片
    let legacy = AgyQuotaReading(status: .available, remainingPercent: 40, groupName: "Gemini · 每周", checkedAt: now,
                                 groupTitle: "Gemini", windowTitle: "每周")
    let legacyPresentation = AgyQuotaPresentation(reading: legacy, now: now)
    check(legacyPresentation.windows.count == 1 && legacyPresentation.windows[0].usedPercent == 60
          && legacyPresentation.windows[0].isTightest, "没有窗口列表时用最紧张字段补一张卡片")

    check(MenuBarPercent.text(usedPercent: 82.4, mode: .tightest) == Fmt.percent(82.4), "菜单栏显示已用百分比")
    check(MenuBarPercent.text(usedPercent: 82.4, mode: .petOnly) == nil, "仅宠物模式不显示数字")
    check(MenuBarPercent.text(usedPercent: 120, mode: .session) == Fmt.percent(100), "菜单栏数字不超过 100%")

    check(OfficialPetChoice.antigravity.entry == .antigravity, "agy 形象属于 agy 页")
    check(PetStyle.claudeChoices.allSatisfy { OfficialPetChoice(rawValue: $0.rawValue)!.entry == .claude }, "Claude 形象属于 Claude 页")
    check(PetStyle.codexChoices.allSatisfy { OfficialPetChoice(rawValue: $0.rawValue)!.entry == .codex }, "Codex 形象属于 Codex 页")
    for entry in OfficialQuotaEntry.allCases {
        var selection = OfficialPetSelection(choice: .antigravity, claudeStyle: .witch, codexStyle: .hanfu)
        selection.select(entry: entry)
        check(selection.choice.entry == entry, "切换页签后宠物跟着这家，并沿用这家记住的形象")
    }
}

/// agy 以 Gemini 组为准；补充状态图的文件名和缺图退回；按读数变化的表情
func checkAgyPrimaryAndStates() {
    let now = Date(timeIntervalSince1970: 20_000)
    func reading(_ geminiWeekly: Double, _ geminiFive: Double, _ claudeFive: Double, claudeWeekly: Double? = nil, at: Date) -> AgyQuotaReading {
        var windows = [
            AgyQuotaReading.Window(group: "Gemini", window: "每周", remainingPercent: 100 - geminiWeekly),
            AgyQuotaReading.Window(group: "Gemini", window: "五小时", remainingPercent: 100 - geminiFive),
            AgyQuotaReading.Window(group: "Claude / GPT", window: "五小时", remainingPercent: 100 - claudeFive),
        ]
        if let claudeWeekly { windows.append(.init(group: "Claude / GPT", window: "每周", remainingPercent: 100 - claudeWeekly)) }
        let tight = windows.min { $0.remainingPercent < $1.remainingPercent }!
        return AgyQuotaReading(status: .available, remainingPercent: tight.remainingPercent, groupName: tight.group + " · " + tight.window,
                               checkedAt: at, groupTitle: tight.group, windowTitle: tight.window, windows: windows)
    }
    let r = reading(48, 3, 0, claudeWeekly: 66, at: now)
    let p = AgyQuotaPresentation(reading: r, now: now)
    check(p.usedPercent == 66, "最紧张字段仍是所有窗口里最紧张的（Claude / GPT 每周 66%）")
    check(p.primaryWindow?.id == "Gemini · 每周" && p.primaryUsedPercent == 48, "agy 以 Gemini 组为准：取这组里用得最多的窗口")
    check(p.primaryMood == .energetic, "宠物表情按 Gemini 的 48%")
    check(MenuBarPercent.text(usedPercent: p.primaryUsedPercent, mode: .tightest) == Fmt.percent(48), "菜单栏显示 Gemini 的数字")
    let noGemini = AgyQuotaReading(status: .available, remainingPercent: 30, groupName: "Claude / GPT · 每周", checkedAt: now,
                                   groupTitle: "Claude / GPT", windowTitle: "每周",
                                   windows: [.init(group: "Claude / GPT", window: "每周", remainingPercent: 30)])
    check(AgyQuotaPresentation(reading: noGemini, now: now).primaryUsedPercent == 70, "没有 Gemini 组时退回最紧张的窗口")

    // 状态图文件名
    let prism = OfficialPetChoice.antigravity, pilot = OfficialPetChoice(rawValue: "agy-aurora")!
    check(prism.panelFile(mood: .confused) == "agy/panel-confused.png" && pilot.menuFile(mood: .loading) == "agy/pilot-menu-loading.png",
          "补充状态图按「前缀 + menu/panel + 状态」命名")
    check(prism.pokeFile(annoyed: false, panel: true) == "agy/panel-poke.png" && pilot.pokeFile(annoyed: true, panel: false) == "agy/pilot-menu-pout.png",
          "agy 被戳和闹别扭各有一张图")
    check(OfficialPetChoice(rawValue: "witch")!.pokeFile(annoyed: false, panel: true) == nil, "Claude / Codex 的反应用动画表，不走 agy 的图")
    check(OfficialPetChoice.resolved("agy/pilot-panel-nervous.png") { $0 == "agy/pilot-panel.png" } == "agy/pilot-panel.png",
          "还没补的状态图退回这款的基础图")
    check(OfficialPetChoice.resolved("agy/panel-tired.png") { _ in true } == "agy/panel-tired.png", "已有的图直接用")
    check(OfficialPetChoice.optionalAntigravityStates.count == 7, "七个可补充的状态")
    // 平均节奏：每周窗口按官方重置时间推出起点；5 小时窗口、没有重置时间时不画
    let paced = AgyQuotaReading(status: .available, remainingPercent: 52, groupName: "Gemini · 每周", checkedAt: now,
                                groupTitle: "Gemini", windowTitle: "每周", windows: [
        .init(group: "Gemini", window: "每周", remainingPercent: 52, resetsAt: now.addingTimeInterval(3.5 * 86400)),
        .init(group: "Gemini", window: "五小时", remainingPercent: 90, resetsAt: now.addingTimeInterval(3600)),
        .init(group: "Claude / GPT", window: "每周", remainingPercent: 95),
    ])
    let pacedWindows = AgyQuotaPresentation(reading: paced, now: now).windows
    if let pace = pacedWindows.first(where: { $0.id == "Gemini · 每周" })?.pace(now: now) {
        check(abs(pace.expected - 50) < 0.01 && abs(pace.ahead + 2) < 0.01, "agy 每周窗口过了一半时，平均节奏刻度在 50%")
    } else { check(false, "agy 每周窗口有平均节奏") }
    check(pacedWindows.first { $0.id == "Gemini · 五小时" }?.pace(now: now) == nil, "agy 5 小时窗口不画平均节奏")
    check(pacedWindows.first { $0.id == "Claude / GPT · 每周" }?.pace(now: now) == nil, "官方没给重置时间的窗口不画平均节奏")
    check(OfficialPetChoice.brokenArtDigests.count == 12 && OfficialPetChoice.brokenArtDigests.allSatisfy { $0.count == 64 },
          "0.4.3 的 12 张坏图按指纹登记，当作缺图")

    // 表情：读取状态和变化
    check(AgyQuotaPresentation.trendMood(reading: nil, history: [], querying: true, now: now) == .loading, "第一次读取中：醒过来中")
    let failed = AgyQuotaReading(status: .signInRequired, checkedAt: now)
    check(AgyQuotaPresentation.trendMood(reading: failed, history: [], querying: false, now: now) == .confused, "读不到：有点懵")
    let before = reading(85, 10, 0, at: now.addingTimeInterval(-1800))
    let afterReset = reading(5, 2, 0, at: now)
    check(AgyQuotaPresentation.trendMood(reading: afterReset, history: [before], querying: false, now: now) == .revived, "Gemini 刚回落 40 点以上：刚恢复")
    let earlier = reading(30, 5, 0, at: now.addingTimeInterval(-2400))
    let rising = reading(50, 20, 0, at: now)
    check(AgyQuotaPresentation.trendMood(reading: rising, history: [earlier], querying: false, now: now) == .nervous, "半小时多涨了 15 点以上：有点慌")
    let flat = [reading(20, 3, 0, at: now.addingTimeInterval(-6000)), reading(20, 3, 0, at: now.addingTimeInterval(-3000))]
    check(AgyQuotaPresentation.trendMood(reading: reading(20, 3, 0, at: now), history: flat, querying: false, now: now) == .resting,
          "一个半小时没变化：歇着呢")
    check(AgyQuotaPresentation.trendMood(reading: reading(95, 3, 0, at: now), history: [earlier], querying: false, now: now) == .exhausted,
          "快用完时照档位，不被变化覆盖")
}

/// 评审意见：agy 面板重画后只认现在这一屏；Claude Code 干完活的自动读取被限频时不丢
func checkRedrawAndActivityRefresh() {
    func panel(_ geminiWeekly: String, _ claudeFive: String) -> String {
        """
        Models & Quota
        GEMINI MODELS
        Weekly Limit Remaining
        [████░] \(geminiWeekly)
        Five Hour Limit Remaining
        [████] 81.00%
        CLAUDE AND GPT MODELS
        Weekly Limit Remaining
        [████] 91.00%
        Five Hour Limit Remaining
        [██░░] \(claudeFive)
        Within each group, models share a weekly limit and a 5-hour limit.
        """.replacingOccurrences(of: "\n", with: "\r\n")
    }
    let now = Date(timeIntervalSince1970: 30_000)
    var screen = VirtualTerminal(rows: 70, columns: 220)
    screen.feed(panel("62.50%", "24.25%"))
    screen.feed("\u{1B}[2J\u{1B}[H" + panel("40.00%", "70.00%"))
    let reading = AgyQuotaParser.parse(terminal: screen, now: now)
    check(reading.status == .available && reading.windows.count == 4, "agy 面板清屏重画后只读现在这一屏（4 个窗口，不是 8 个）")
    check(reading.windows.first?.remainingPercent == 40 && reading.remainingPercent == 40, "agy 取重画后的新数字，不保留旧帧的最低值")
    check(Set(reading.windows.map { $0.group + $0.window }).count == reading.windows.count, "agy 窗口不重复（面板里的 id 唯一）")
    var banner = VirtualTerminal(rows: 70, columns: 220)
    banner.feed("Welcome to the Antigravity CLI. You are currently not signed in.\r\n> /usage\r\n" + panel("51.83%", "34.19%"))
    check(AgyQuotaParser.parse(terminal: banner, now: now).status == .available,
          "agy 启动横幅写着「not signed in」但下面有额度面板时，以面板为准")
    check(AgyQuotaParser.parse("Welcome to the Antigravity CLI. You are currently not signed in.", now: now).status == .signInRequired,
          "没有额度面板、只有未登录提示时才判为需要登录")
    var partial = VirtualTerminal(rows: 70, columns: 220)
    partial.feed(panel("62.50%", "24.25%"))
    partial.feed("\u{1B}[4;9H40.00%")  // 只局部重画一个数字
    check(AgyQuotaParser.parse(terminal: partial, now: now).windows.first?.remainingPercent == 40, "agy 局部重画的数字按新值读")

    let t = Date(timeIntervalSince1970: 40_000)
    let quiet = AgyRefreshPolicy.activityQuiet
    check(ActivityRefresh.step(now: t.addingTimeInterval(10), lastActivity: t, latestReadingAt: t.addingTimeInterval(-60), querying: false) == .wait,
          "刚在干活、上次读数不到 3 分钟前：先等")
    check(ActivityRefresh.step(now: t.addingTimeInterval(quiet), lastActivity: t, latestReadingAt: t.addingTimeInterval(-60), querying: false) == .refresh,
          "活动停下就去读（即使上次读数才 1 分钟前，被限频时下次检查再试）")
    check(ActivityRefresh.step(now: t.addingTimeInterval(quiet + 15), lastActivity: t, latestReadingAt: t.addingTimeInterval(-60), querying: false) == .refresh,
          "被限频拒绝后不结束，继续尝试")
    check(ActivityRefresh.step(now: t.addingTimeInterval(quiet), lastActivity: t, latestReadingAt: t.addingTimeInterval(-60), querying: true) == .wait,
          "正在读时等它读完")
    check(ActivityRefresh.step(now: t.addingTimeInterval(quiet + 30), lastActivity: t, latestReadingAt: t.addingTimeInterval(quiet + 20), querying: false) == .done,
          "活动之后读到了新读数：这一轮结束")
    check(ActivityRefresh.step(now: t.addingTimeInterval(20), lastActivity: t, latestReadingAt: t.addingTimeInterval(-200), querying: false) == .refresh,
          "一直在干活、离上次读数超过 3 分钟：也读一次")
}
