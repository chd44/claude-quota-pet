import Foundation
import QuotaPetCore

func checkAgyQuotaParser() {
    // Synthetic values in the observed official layout; no real account fixture.
    let panel = """
    Models & Quota
    GEMINI MODELS
    Weekly Limit Remaining
    [████░] 62.50%
    Refreshes in 72h 15m
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
    let now = Date(timeIntervalSince1970: 1000)
    let reading = AgyQuotaParser.parse(panel, now: now)
    check(reading.status == .available && reading.remainingPercent == 24.25, "agy 取所有明确窗口中最低的剩余额度")
    check(reading.groupTitle == "Gemini Argon" && reading.windowTitle == "每周", "agy Argon 独立窗口不沿用 Claude 标签")
    check(reading.resetsAt == now.addingTimeInterval(72 * 3600 + 15 * 60), "agy 仅依据官方 refresh 文本计算重置时刻")
    check(reading.checkedAt == now, "agy 读数保留查询时刻")
    check(AgyQuotaParser.parse(panel.replacingOccurrences(of: "24.25%", with: "0%")).remainingPercent == 0, "agy 官方确实显示零时才返回零")
    check(AgyQuotaParser.parse(panel.replacingOccurrences(of: "24.25%", with: "101%")).status == .unknown, "agy 超范围百分比使整屏未知")
    check(AgyQuotaParser.parse(panel.replacingOccurrences(of: "Within each group, models share a weekly limit and a 5-hour limit.", with: "")).status == .unknown, "agy 未结束的面板不能提前返回基础组而漏掉Argon")
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
    Gemini 4 Argon Weekly Limit
    [██░░] 44.00%
    Within each group, models share a weekly limit and a 5-hour limit.
    """
    let now = Date(timeIntervalSince1970: 10_000)
    let reading = AgyQuotaParser.parse(panel, now: now)
    check(reading.windows.map { $0.group + "|" + $0.window } ==
          ["Gemini|每周", "Gemini|五小时", "Claude / GPT|每周", "Claude / GPT|五小时", "Gemini Argon|每周"],
          "agy 读数按官方顺序保留全部窗口")
    check(reading.windows.map(\.remainingPercent) == [62.5, 81, 91, 30, 44], "agy 每个窗口保留各自的剩余百分比")
    check(reading.windows[1].resetsAt == now.addingTimeInterval(7200) && reading.windows[2].resetsAt == nil,
          "agy 重置时间只跟在它下面的窗口，不串到别的窗口")
    check(reading.remainingPercent == 30 && reading.groupName == "Claude / GPT · 五小时", "最紧张字段仍取最低剩余")

    let fresh = AgyQuotaPresentation(reading: reading, now: now.addingTimeInterval(60))
    check(fresh.windows.count == 5, "新鲜读数时面板画出全部 5 个窗口")
    check(fresh.windows.map(\.usedPercent) == [37.5, 19, 9, 70, 56], "面板按已用 = 100 − 官方剩余显示")
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
    func reading(_ geminiWeekly: Double, _ geminiFive: Double, _ claudeFive: Double, argon: Double? = nil, at: Date) -> AgyQuotaReading {
        var windows = [
            AgyQuotaReading.Window(group: "Gemini", window: "每周", remainingPercent: 100 - geminiWeekly),
            AgyQuotaReading.Window(group: "Gemini", window: "五小时", remainingPercent: 100 - geminiFive),
            AgyQuotaReading.Window(group: "Claude / GPT", window: "五小时", remainingPercent: 100 - claudeFive),
        ]
        if let argon { windows.append(.init(group: "Gemini Argon", window: "每周", remainingPercent: 100 - argon)) }
        let tight = windows.min { $0.remainingPercent < $1.remainingPercent }!
        return AgyQuotaReading(status: .available, remainingPercent: tight.remainingPercent, groupName: tight.group + " · " + tight.window,
                               checkedAt: at, groupTitle: tight.group, windowTitle: tight.window, windows: windows)
    }
    let r = reading(48, 3, 0, argon: 66, at: now)
    let p = AgyQuotaPresentation(reading: r, now: now)
    check(p.usedPercent == 66, "最紧张字段仍是所有窗口里最紧张的（Argon 66%）")
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
