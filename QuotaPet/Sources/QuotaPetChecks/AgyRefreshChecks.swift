import Foundation
@testable import QuotaPetCore

func agyRefreshChecks() {
    let now = Date(timeIntervalSince1970: 1_000)
    var policy = AgyRefreshPolicy()
    check(!policy.begin(now: now), "未选择 agy 不查询")
    policy.select(true)
    check(policy.begin(now: now), "选择 agy 首次立即查询")
    check(!policy.begin(now: now.addingTimeInterval(900)), "查询未结束不允许并发")
    policy.finish()
    check(!policy.begin(now: now.addingTimeInterval(899)), "15 分钟内不重复查询")
    check(policy.delayUntilDue(now: now.addingTimeInterval(600)) == 300, "醒来时在剩余间隔后刷新，不能额外拖延15分钟")
    policy.setSleeping(true)
    check(!policy.begin(now: now.addingTimeInterval(901)), "休眠期间暂停查询")
    policy.setSleeping(false)
    check(policy.begin(now: now.addingTimeInterval(901)), "醒来过期后立即查询")
    policy.select(false)
    policy.select(true)
    check(!policy.begin(now: now.addingTimeInterval(902)), "切换离开再返回也不能绕过并发保护")
    policy.finish()
    check(policy.begin(now: now.addingTimeInterval(903)), "重新选择 agy 首读不沿用旧的查询间隔")
    policy.finish()
    policy.setSleeping(true)
    policy.setSleeping(false)
    check(!policy.begin(now: now.addingTimeInterval(904)), "短暂休眠醒来保留未过期读数")
    policy.select(false)
    check(!policy.begin(now: now.addingTimeInterval(2_000)), "离开 agy 停止定时查询")
}

func agyPresentationChecks() {
    let now = Date(timeIntervalSince1970: 5_000)
    for (remaining, expected) in [(100.0, PetMood.energetic), (51, .energetic), (50, .normal), (25, .tired), (10, .exhausted), (0, .sleeping)] {
        let reading = AgyQuotaReading(status: .available, remainingPercent: remaining, groupName: "Gemini Pro", checkedAt: now)
        let shown = AgyQuotaPresentation(reading: reading, now: now)
        check(shown.mood == expected, "官方剩余 \(remaining)% 进入对应已用档位")
        for choice in OfficialPetChoice.antigravityChoices {
            check(choice.menuFile(mood: shown.mood).hasSuffix(expected == .normal ? "menu.png" : "menu-\(expected.rawValue).png"),
                  "真实额度驱动每款 agy 的菜单表情")
        }
    }
    check(OfficialPetChoice(rawValue: "agy-aurora")!.panelFile(mood: .tired) == "agy/pilot-panel-tired.png",
          "飞行员面板表情资源保留同款")
    check(OfficialPetChoice(rawValue: "agy-stargazer")!.panelFile(mood: .sleeping) == "agy/gardener-panel-sleeping.png",
          "花匠耗尽表情仍使用自己的面板")
    check(OfficialPetChoice(rawValue: "agy")!.panelFile(mood: .normal) == "agy/panel.png",
          "正常和未知读数沿用棱镜原图")
    check(OfficialPetChoice(rawValue: "witch")!.panelFile(mood: .sleeping) == OfficialPetChoice(rawValue: "witch")!.panelFile,
          "agy 额度不会改变 Claude 的资源")
    let unavailable: [AgyQuotaReading?] = [nil,
        .init(status: .signInRequired, remainingPercent: 0, groupName: "Gemini Pro", checkedAt: now),
        .init(status: .confirmationRequired, remainingPercent: 0, groupName: "Gemini Pro", checkedAt: now),
        .init(status: .unknown, remainingPercent: 0, groupName: "Gemini Pro", checkedAt: now),
        .init(status: .unavailable, remainingPercent: 0, groupName: "Gemini Pro", checkedAt: now),
        .init(status: .available, remainingPercent: 0, groupName: "Gemini Pro", checkedAt: now.addingTimeInterval(-900)),
        .init(status: .available, remainingPercent: 0, groupName: "Gemini Pro", checkedAt: now.addingTimeInterval(1)),
        .init(status: .available, remainingPercent: .nan, groupName: "Gemini Pro", checkedAt: now),
        .init(status: .available, remainingPercent: -1, groupName: "Gemini Pro", checkedAt: now),
        .init(status: .available, remainingPercent: 101, groupName: "Gemini Pro", checkedAt: now),
        .init(status: .available, remainingPercent: 0, checkedAt: now)]
    for reading in unavailable {
        let shown = AgyQuotaPresentation(reading: reading, now: now)
        check(shown.usedPercent == nil && shown.mood == .normal, "未知、过期或不完整读数只能显示中性原图")
    }
}

func agyResetChecks() {
    let now = Date(timeIntervalSince1970: 10_000)
    let deadline = now.addingTimeInterval(60)
    let empty = AgyQuotaReading(status: .available, remainingPercent: 0, groupName: "Gemini · 五小时", checkedAt: now,
                                groupTitle: "Gemini", windowTitle: "五小时", resetsAt: deadline)
    let before = AgyQuotaPresentation(reading: empty, now: deadline.addingTimeInterval(-0.001))
    check(before.mood == .sleeping, "重置前最后一刻仍沿用官方耗尽读数")
    check(before.validUntil == deadline, "官方重置早于15分钟时以重置作为截止")
    let current = AgyQuotaPresentation(reading: empty, now: now)
    check(current.nextUpdateDelay(defaultDelay: 900, now: now) == 60, "官方重置应安排一次界面更新")
    for moment in [deadline, deadline.addingTimeInterval(1), now.addingTimeInterval(901)] {
        let expired = AgyQuotaPresentation(reading: empty, now: moment)
        check(expired.usedPercent == nil && expired.mood == .normal, "重置时及以后必须撤销睡眠状态且不能推测恢复额度")
        check(expired.nextUpdateDelay(defaultDelay: 840, now: moment) == 840, "过期重置不能反复安排1秒唤醒")
    }
    let previousLanguage = L10n.language
    L10n.language = .en
    check(AgyQuotaPresentation.scopeLabel(empty) == "Gemini · 5-hour window", "英文界面翻译窗口词，不混入中文")
    L10n.language = .zhHans
    check(AgyQuotaPresentation.scopeLabel(empty) == "Gemini · 五小时窗口", "中文界面明确显示耗尽的是哪个窗口")
    L10n.language = previousLanguage
    let lateReset = AgyQuotaReading(status: .available, remainingPercent: 0, groupName: "Gemini", checkedAt: now,
                                    resetsAt: now.addingTimeInterval(3_600))
    check(AgyQuotaPresentation(reading: lateReset, now: now).validUntil == now.addingTimeInterval(900), "重置较晚也不能延长15分钟有效期")

    // 手动刷新的等待秒数和刷新结果提示
    var gate = AgyRefreshPolicy()
    gate.select(true)
    check(gate.manualWait(now: now) == nil, "从没读过：手动刷新不用等")
    check(gate.beginManual(now: now), "第一次手动刷新立即开始")
    gate.finish()
    check(gate.manualWait(now: now.addingTimeInterval(10)) == 20, "10 秒后再点：还要等 20 秒")
    check(gate.manualWait(now: now.addingTimeInterval(30)) == nil, "满 30 秒：不用等")
    check(gate.manualWait(now: now.addingTimeInterval(-5)) == nil, "时钟往回拨：不显示等待")
    let asked = now.addingTimeInterval(-3)
    check(RefreshNotice.cliFinished(entry: .claude, usable: true, checkedAt: now, requestedAt: asked, message: "", now: now).kind == .done,
          "点刷新之后读到可用读数：已刷新")
    check(RefreshNotice.cliFinished(entry: .claude, usable: true, checkedAt: asked.addingTimeInterval(-60), requestedAt: asked, message: "", now: now).kind == .failed,
          "读数还是点刷新之前的：不算刷新成功")
    let signIn = RefreshNotice.cliFinished(entry: .antigravity, usable: false, checkedAt: now, requestedAt: asked, message: "请先登录", now: now)
    check(signIn.kind == .failed && signIn.text.contains("请先登录"), "读失败：提示带上 CLI 给的原因")
    check(RefreshNotice.tooSoon(entry: .claude, wait: 19.2, now: now).text.contains("20"), "刚读过：等待秒数向上取整")
    check(RefreshNotice.codexReloaded(officialAt: nil, now: now).kind == .failed, "Codex 日志里没有读数：没读到")
    check(RefreshNotice.codexReloaded(officialAt: now.addingTimeInterval(-120), now: now).kind == .done, "Codex 有读数：已刷新")
}
