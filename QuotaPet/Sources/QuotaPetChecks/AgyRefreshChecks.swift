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
    check(!policy.begin(now: now.addingTimeInterval(719)), "12 分钟内不重复查询")
    check(policy.delayUntilDue(now: now.addingTimeInterval(600)) == 120, "醒来时在剩余间隔后刷新，不能额外拖延")
    policy.setSleeping(true)
    check(!policy.begin(now: now.addingTimeInterval(721)), "休眠期间暂停查询")
    policy.setSleeping(false)
    check(policy.begin(now: now.addingTimeInterval(721)), "醒来过期后立即查询")
    policy.select(false)
    policy.select(true)
    check(!policy.begin(now: now.addingTimeInterval(722)), "切换离开再返回也不能绕过并发保护")
    policy.finish()
    check(policy.begin(now: now.addingTimeInterval(723)), "重新选择 agy 首读不沿用旧的查询间隔")
    policy.finish()
    policy.setSleeping(true)
    policy.setSleeping(false)
    check(!policy.begin(now: now.addingTimeInterval(724)), "短暂休眠醒来保留未过期读数")
    policy.select(false)
    check(!policy.begin(now: now.addingTimeInterval(2_000)), "离开 agy 停止定时查询")

    // 读失败后 1、2、4、8 分钟重试，最长回到 12 分钟；读到一次就恢复 12 分钟
    var retry = AgyRefreshPolicy()
    retry.select(true)
    check(retry.begin(now: now), "首读")
    let abandonedAt = now.addingTimeInterval(AgyRefreshPolicy.queryTimeout)
    retry.finish(usable: false, now: abandonedAt)
    check(retry.dueInterval == 60 && !retry.begin(now: abandonedAt.addingTimeInterval(59)), "失败后不到 1 分钟不重试")
    check(retry.delayUntilDue(now: abandonedAt) == 60, "看门狗 120 秒放弃后从放弃时刻起算，真正等 1 分钟再重试")
    check(!retry.beginOnNetworkRecovery(now: abandonedAt.addingTimeInterval(5)), "15 秒防抖期内断网恢复不立刻连打")
    check(retry.begin(now: abandonedAt.addingTimeInterval(60)), "失败后 1 分钟重试，不等 12 分钟")
    retry.finish(usable: false, now: abandonedAt.addingTimeInterval(65))
    check(retry.dueInterval == 120, "连续失败间隔翻倍到 2 分钟")
    check(retry.beginOnNetworkRecovery(now: abandonedAt.addingTimeInterval(85)), "失败后断网恢复且过防抖期时立刻重试")
    retry.finish(usable: false, now: abandonedAt.addingTimeInterval(90))
    check(retry.dueInterval == 240, "第三次失败间隔翻倍到 4 分钟")
    for i in 1...10 {
        let t = now.addingTimeInterval(Double(i) * 10_000)
        _ = retry.begin(now: t)
        retry.finish(usable: false, now: t.addingTimeInterval(10))
    }
    check(retry.dueInterval == AgyRefreshPolicy.refreshInterval, "一直失败最长 12 分钟一次")
    let failuresBefore = retry.failures
    _ = retry.begin(now: now.addingTimeInterval(200_000))
    retry.finish()
    check(retry.failures == failuresBefore && retry.failures > 0, "作废的读取不算成败")
    _ = retry.begin(now: now.addingTimeInterval(300_000))
    retry.finish(usable: true, now: now.addingTimeInterval(300_005))
    check(retry.failures == 0 && retry.dueInterval == AgyRefreshPolicy.refreshInterval, "读到一次就清零并恢复 12 分钟")
    check(!retry.beginOnNetworkRecovery(now: now.addingTimeInterval(300_030)), "没有失败时不因网络事件触发")
    retry.finish(usable: false, now: now.addingTimeInterval(300_040))
    retry.select(false); retry.select(true)
    check(retry.failures == 0, "重新选中从头算")

    // 偶发失败不顶掉有效期内的旧读数（严格 15 分钟有效）；明确的状态照常替换
    let old = now.addingTimeInterval(-300)
    check(AgyRefreshPolicy.keepsPrevious(previousUsable: true, previousCheckedAt: old, newUsable: false, newIsUnknown: true, now: now),
          "超时/未识别时保留 5 分钟前的可用读数")
    check(AgyRefreshPolicy.keepsPrevious(previousUsable: true, previousCheckedAt: now.addingTimeInterval(-899), newUsable: false, newIsUnknown: true, now: now),
          "旧读数不到 15 分钟仍保留")
    check(!AgyRefreshPolicy.keepsPrevious(previousUsable: true, previousCheckedAt: now.addingTimeInterval(-901), newUsable: false, newIsUnknown: true, now: now),
          "旧读数过了 15 分钟就不保留")
    check(!AgyRefreshPolicy.keepsPrevious(previousUsable: true, previousCheckedAt: old, newUsable: false, newIsUnknown: false, now: now),
          "要登录、要确认等明确状态替换旧读数")
    check(!AgyRefreshPolicy.keepsPrevious(previousUsable: false, previousCheckedAt: old, newUsable: false, newIsUnknown: true, now: now),
          "旧的本来就不可用时不保留")
    check(!AgyRefreshPolicy.keepsPrevious(previousUsable: true, previousCheckedAt: old, newUsable: true, newIsUnknown: false, now: now),
          "新读数可用时用新的")
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
    // 复用在途查询且在收尾阶段点刷新：requestedAt 按查询开始算，不因 checkedAt 早于点击时刻误报失败
    let queryStarted = now.addingTimeInterval(-4)
    check(RefreshNotice.cliFinished(entry: .claude, usable: true, checkedAt: now.addingTimeInterval(-1),
                                    requestedAt: min(now, queryStarted), message: "", now: now).kind == .done,
          "在途查询收尾阶段点刷新：已拿到新读数仍报已刷新")
    check(RefreshNotice.cliFinished(entry: .claude, usable: true, checkedAt: asked.addingTimeInterval(-60), requestedAt: asked, message: "", now: now).kind == .failed,
          "读数还是点刷新之前的：不算刷新成功")
    let signIn = RefreshNotice.cliFinished(entry: .antigravity, usable: false, checkedAt: now, requestedAt: asked, message: "请先登录", now: now)
    check(signIn.kind == .failed && signIn.text.contains("请先登录"), "读失败：提示带上 CLI 给的原因")
    check(RefreshNotice.tooSoon(entry: .claude, wait: 19.2, now: now).text.contains("20"), "刚读过：等待秒数向上取整")
    check(RefreshNotice.codexReloaded(officialAt: nil, now: now).kind == .failed, "Codex 日志里没有读数：没读到")
    check(RefreshNotice.codexReloaded(officialAt: now.addingTimeInterval(-120), now: now).kind == .done, "Codex 有读数：已刷新")
}

/// 等子进程结束：限时、不卡死（代替 waitUntilExit）
func processExitChecks() {
    func launch(_ seconds: String) -> (Process, ProcessExit) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = [seconds]
        let finished = ProcessExit(process)
        try! process.run()
        return (process, finished)
    }
    let (quick, quickExit) = launch("0")
    check(quickExit.wait(timeout: 5) && quickExit.hasExited && quick.terminationStatus == 0, "很快结束的进程：等得到结束")
    check(quickExit.wait(timeout: 0), "重复等也立刻返回已结束")

    let (slow, slowExit) = launch("30")
    let started = Date()
    check(!slowExit.wait(timeout: 0.3) && !slowExit.hasExited, "还在跑的进程：到时间就返回，不一直等")
    check(Date().timeIntervalSince(started) < 3, "超时返回得及时")
    slow.terminate()
    check(slowExit.wait(timeout: 5), "结束之后等得到")

    // 从并发线程池里同时等很多个很快退出的进程：每个都要在限时内等到（原来 waitUntilExit 在这种线程上偶尔永远不返回）
    let group = DispatchGroup()
    let lock = NSLock()
    var missed = 0
    for _ in 0..<40 {
        group.enter()
        Task.detached {
            let (_, finished) = launch("0")
            if !finished.wait(timeout: 10) { lock.withLock { missed += 1 } }
            group.leave()
        }
    }
    check(group.wait(timeout: .now() + 60) == .success && missed == 0, "并发等 40 个子进程都在限时内等到结束")

    // 非阻塞 waitAsync：快退出、超时后再 terminate、以及并发等待
    let asyncDone = DispatchSemaphore(value: 0)
    let asyncLock = NSLock()
    var asyncResults: [Bool] = []
    Task.detached {
        let (_, aqExit) = launch("0")
        let r1 = await aqExit.waitAsync(timeout: 5)
        let r2 = await aqExit.waitAsync(timeout: 0)

        let (aslow, aslowExit) = launch("30")
        let r3 = !(await aslowExit.waitAsync(timeout: 0.2)) && !aslowExit.hasExited
        aslow.terminate()
        let r4 = await aslowExit.waitAsync(timeout: 5)

        var r5 = true
        await withTaskGroup(of: Bool.self) { tg in
            for _ in 0..<20 {
                tg.addTask {
                    let (_, f) = launch("0")
                    return await f.waitAsync(timeout: 10)
                }
            }
            for await ok in tg { if !ok { r5 = false } }
        }
        asyncLock.withLock { asyncResults = [r1, r2, r3, r4, r5] }
        asyncDone.signal()
    }
    check(asyncDone.wait(timeout: .now() + 30) == .success && asyncResults == [true, true, true, true, true],
          "waitAsync 异步等待不阻塞协作线程池且按时返回")
}

/// PTY 子进程（posix_spawn + POSIX_SPAWN_SETSID）：独立会话与控制终端，避免后台进程组触发 SIGTTOU
func ptyProcessChecks() {
    let sh = URL(fileURLWithPath: "/bin/sh")
    let tmp = URL(fileURLWithPath: "/tmp")

    // 1. 工作目录、PTY 窗口尺寸与隔离环境变量
    let done = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var results: [Bool] = []
    Task.detached {
        var basicOK = false
        var ttySessionOK = false
        var terminateOK = false
        var forceKillOK = false
        var concurrentOK = true

        if let p1 = try? PTYProcess(
            executableURL: sh,
            arguments: ["-c", "pwd; stty size; printenv TEST_KEY; printenv QUOTAPET_SECRET_TEST || echo NO_SECRET"],
            workingDirectory: tmp,
            environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "TEST_KEY": "ok"],
            rows: 70,
            columns: 220
        ) {
            defer { p1.closeMaster() }
            var out = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            for _ in 0..<50 {
                let n = p1.read(into: &buf)
                if n > 0 { out.append(contentsOf: buf.prefix(n)) }
                if p1.hasExited && n <= 0 { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            _ = await p1.drainWhileWaiting(timeout: 2)
            let text = String(decoding: out, as: UTF8.self)
            basicOK = p1.hasExited
                && text.contains("/tmp")
                && text.contains("70 220")
                && text.contains("ok")
                && text.contains("NO_SECRET")
            if !basicOK { print("PTY p1 debug: exited=\(p1.hasExited) text=\(text.debugDescription)") }
        }

        // 2. 独立会话与 /dev/tty 写入（即使父进程带控制终端也不触发 SIGTTOU）
        if let p2 = try? PTYProcess(
            executableURL: sh,
            arguments: ["-c", "echo PS=$(/bin/ps -o pid=,pgid=,stat= -p $$); echo HELLO_TTY >/dev/tty"],
            workingDirectory: tmp,
            environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color"],
            rows: 24,
            columns: 80
        ) {
            defer { p2.closeMaster() }
            var out = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            for _ in 0..<50 {
                let n = p2.read(into: &buf)
                if n > 0 { out.append(contentsOf: buf.prefix(n)) }
                if p2.hasExited && n <= 0 { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            let exited = await p2.drainWhileWaiting(timeout: 5)
            while p2.read(into: &buf) > 0 {}
            let text = String(decoding: out, as: UTF8.self)
            let pidStr = "\(p2.pid)"
            ttySessionOK = exited
                && text.contains("HELLO_TTY")
                && text.contains("\(pidStr) \(pidStr)")
            if !ttySessionOK { print("PTY p2 debug: exited=\(exited) pid=\(pidStr) text=\(text.debugDescription)") }
        }

        // 3. 超时 + terminate（含子孙进程一起终止）
        if let p3 = try? PTYProcess(
            executableURL: sh,
            arguments: ["-c", "sleep 30 & wait"],
            workingDirectory: tmp,
            environment: ["PATH": "/usr/bin:/bin"],
            rows: 24,
            columns: 80
        ) {
            defer { p3.closeMaster() }
            let early = await p3.waitAsync(timeout: 0.2)
            p3.terminate()
            let stopped = await p3.drainWhileWaiting(timeout: 5)
            terminateOK = !early && stopped && p3.hasExited
            if !terminateOK { print("PTY p3 debug: early=\(early) stopped=\(stopped) exited=\(p3.hasExited)") }
        }

        // 4. 忽略 SIGTERM 时由 forceKill 强杀
        if let p4 = try? PTYProcess(
            executableURL: sh,
            arguments: ["-c", "trap '' TERM; echo READY; while true; do sleep 1; done"],
            workingDirectory: tmp,
            environment: ["PATH": "/usr/bin:/bin"],
            rows: 24,
            columns: 80
        ) {
            defer { p4.closeMaster() }
            var out = ""
            var buf = [UInt8](repeating: 0, count: 4096)
            for _ in 0..<40 where !out.contains("READY") {
                let n = p4.read(into: &buf)
                if n > 0 { out += String(decoding: buf.prefix(n), as: UTF8.self) }
                if !out.contains("READY") { try? await Task.sleep(nanoseconds: 50_000_000) }
            }
            p4.terminate()
            let ignoredTerm = !(await p4.drainWhileWaiting(timeout: 0.3))
            p4.forceKill()
            let killed = await p4.waitAsync(timeout: 5)
            forceKillOK = out.contains("READY") && ignoredTerm && killed && p4.hasExited
            if !forceKillOK { print("PTY p4 debug: out=\(out.debugDescription) ignoredTerm=\(ignoredTerm) killed=\(killed) exited=\(p4.hasExited)") }
        }

        // 5. 并发快速退出不会漏通知或泄漏主端
        await withTaskGroup(of: (Int, String?).self) { tg in
            for idx in 0..<20 {
                tg.addTask {
                    let p: PTYProcess
                    do {
                        p = try PTYProcess(
                            executableURL: sh,
                            arguments: ["-c", "echo ok"],
                            workingDirectory: tmp,
                            environment: ["PATH": "/usr/bin:/bin"],
                            rows: 24,
                            columns: 80
                        )
                    } catch {
                        return (idx, "spawn:\(error)")
                    }
                    defer { p.closeMaster() }
                    let ok = await p.drainWhileWaiting(timeout: 10)
                    return ok ? (idx, nil) : (idx, "timeout:exited=\(p.hasExited)")
                }
            }
            for await (idx, err) in tg {
                if let err {
                    print("PTY p5[\(idx)] debug: \(err)")
                    concurrentOK = false
                }
            }
        }

        lock.withLock { results = [basicOK, ttySessionOK, terminateOK, forceKillOK, concurrentOK] }
        done.signal()
    }
    let finished = done.wait(timeout: .now() + 30) == .success
    check(finished && results.count == 5 && results[0], "PTYProcess 正确设置工作目录、窗口尺寸和隔离环境")
    check(finished && results.count == 5 && results[1], "PTYProcess 具备独立会话与控制终端且不触发 SIGTTOU")
    check(finished && results.count == 5 && results[2], "PTYProcess 超时后可通过 terminate 终止进程组")
    check(finished && results.count == 5 && results[3], "PTYProcess 在忽略 SIGTERM 时可通过 forceKill 强杀")
    check(finished && results.count == 5 && results[4], "PTYProcess 并发快速退出不漏通知")
}
