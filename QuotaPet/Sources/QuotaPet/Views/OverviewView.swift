import SwiftUI
import QuotaPetCore

/// 面板首页。只接收普通的值，方便 --render-previews 直接渲染成图片。
struct OverviewView<Pet: View>: View {
    /// 正在看的那家
    var snapshot: UsageSnapshot?
    var errorMessage: String?
    /// 心情和她现在说的那句（PetStatus），调用方一次算好传进来
    var mood: PetMood
    var line: String
    var pet: Pet
    /// 同时有几家时，头部下面显示切换条（只有一家时为空）
    var tabs: [UsageSnapshot] = []
    /// 宠物和菜单栏跟着的那家，切换条上画个小爪印
    var focus: ProviderID?
    var onSelect: (ProviderID) -> Void = { _ in }
    var onRefresh: () -> Void = {}
    var onSettings: () -> Void = {}
    var onQuit: () -> Void = {}
    /// Claude 桌面端开着没有：官方读数停了的时候，只有它没开才提醒（开着也停的话用户解决不了，不打扰）
    var claudeRunning = true
    /// 打开了「用命令行补官方读数」：桌面端停了读数时，说明里不再只让用户去开桌面端
    var cliProbe = false
    /// 命令行补查现在的状态：没登录、找不到时，说明里不能还说「会补查」
    var cliProbeStatus: ClaudeCLIProbeStatus?
    /// 这句话是哪种情况、第几句。变了（换了情况、面板又打开了一次）就通过 onSay 告诉外面：「这么晚还在忙」一晚只说一次要靠它记
    struct Said: Equatable {
        var situation: PetTalk.Situation
        var pick: Int
    }
    var said: Said?
    var onSay: (PetTalk.Situation) -> Void = { _ in }
    /// 点了一下宠物：外面让她做个反应，返回她回的那句（没反应时是 nil）
    var onPoke: () -> String? = { nil }
    /// 渲染预览图时固定「现在」
    var fixedNow: Date?

    /// 点刷新后给个反馈：图标转一圈，底部说明刷新了什么
    @State private var refreshSpin = 0.0
    @State private var refreshedAt: Date?
    /// 她被戳之后回的那句（过几秒就回到平时的话），和戳了几下（每戳一下重新计时）
    @State private var pokedLine: String?
    @State private var pokes = 0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: fixedNow ?? context.date)
        }
    }

    private func content(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if tabs.count > 1, let selected = snapshot?.provider {
                ProviderTabs(snapshots: tabs, selected: selected, focus: focus, onSelect: onSelect)
            }
            if let snapshot, snapshot.hasData {
                VStack(spacing: 8) {
                    ForEach(snapshot.windows) { WindowCard(window: $0, now: now) }
                }
                if let today = snapshot.today, today.requests > 0 {
                    TodayCard(today: today)
                }
                NotesView(notes: snapshot.notes)
            } else if let snapshot {
                NotesView(notes: snapshot.notes.isEmpty ? [tr("还没有任何额度数据。", "No usage data yet.")] : snapshot.notes)
            } else if let errorMessage {
                NotesView(notes: [tr("读取出错：\(errorMessage)", "Couldn't read the data: \(errorMessage)")])
            } else {
                Text(tr("正在读取…", "Loading…")).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Divider()
            footer(now: now)
        }
        .padding(14)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                guard let reply = onPoke() else { return }
                pokedLine = reply
                pokes += 1
            } label: {
                pet
                    .frame(width: 96, height: 96)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Level.mood(mood).opacity(0.13)))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(PokeStyle())
            .focusable(false)  // 开了键盘导航时，别让面板一打开焦点框就落在宠物上
            .help(tr("戳戳她", "Give her a poke"))
            .accessibilityLabel(tr("戳一下宠物", "Poke the pet"))
            .task(id: pokes) {
                guard pokes > 0 else { return }
                try? await Task.sleep(nanoseconds: UInt64(PetChat.pokeLineDuration * 1_000_000_000))
                if !Task.isCancelled { pokedLine = nil }  // 又戳了一下时这个任务会被取消：别把新的那句清掉
            }
            .onChange(of: snapshot?.provider) { pokedLine = nil }  // 切到另一家：换了一只宠物
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(snapshot?.provider.displayName ?? "Claude")
                        .font(.system(size: 15, weight: .semibold))
                    Text(mood.title)
                        .font(.system(size: 10, weight: .semibold))
                        .fixedSize()  // 标签不折行、不截断
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Level.mood(mood).opacity(0.16)))
                        .foregroundStyle(Level.mood(mood))
                }
                Text(pokedLine ?? line)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)  // 英文比较长，折行而不是截断
                    .onChange(of: said, initial: true) { _, said in
                        if let said { onSay(said.situation) }
                    }
            }
            .padding(.leading, 4)
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                IconButton(systemName: "arrow.clockwise",
                           help: tr("重新读取本机数据（官方读数要等 Claude 桌面端下一次记录）",
                                    "Reload local data (official readings wait for the Claude desktop app's next record)"),
                           rotation: refreshSpin) {
                    onRefresh()
                    withAnimation(.easeInOut(duration: 0.6)) { refreshSpin += 360 }
                    refreshedAt = Date()
                }
                IconButton(systemName: "gearshape", help: tr("设置", "Settings"), action: onSettings)
            }
            .task(id: refreshedAt) {
                guard refreshedAt != nil else { return }
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if !Task.isCancelled { refreshedAt = nil }  // 4 秒内又点了一下时这个任务会被取消：别把新的那次提前清掉
            }
        }
    }

    private func footer(now: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if refreshedAt != nil {
                Label(refreshedText(now: now), systemImage: "checkmark.circle.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color(nsColor: .systemGreen))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(sourceLine(now: now))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button(tr("退出", "Quit"), action: onQuit)
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func sourceLine(now: Date) -> String {
        guard let snapshot, snapshot.hasData else {
            return tr("只读本机文件，不联网、不读登录凭据", "Reads local files only: no network, no login credentials")
        }
        if snapshot.provider == .codex {
            return tr("Codex 每轮对话结束时在本机日志里记一次官方读数", "Codex logs an official reading after every turn")
        }
        guard snapshot.officialAt != nil else {
            return snapshot.windows.contains(where: \.limitReported)
                ? tr("暂无桌面端的官方读数：「用完了」是 Claude Code 报告的，其余是本机估算",
                     "No official reading from the desktop app: “used up” came from Claude Code, the rest is a local estimate")
                : tr("暂无官方读数，数值全部是本机估算", "No official reading yet, so all numbers are local estimates")
        }
        guard let next = nextOfficialText(now: now) else {
            return StalledOfficialHint.of(cliProbe: cliProbe, status: cliProbeStatus, claudeRunning: claudeRunning).text
        }
        return tr("聊天、网页、手机的用量要等官方读数（每 15 分钟一次），\(next)",
                  "Chat, web and mobile usage shows up with the official reading (every 15 min); \(next)")
    }

    private func refreshedText(now: Date) -> String {
        snapshot?.provider == .codex
            ? tr("已刷新：本机日志里的读数都读到了", "Refreshed: every reading in the local logs is loaded")
            : nextOfficialText(now: now).map { tr("已刷新：本机部分是最新的，\($0)", "Refreshed: local data is up to date; \($0)") }
                ?? tr("已刷新：本机部分是最新的", "Refreshed: local data is up to date")
    }

    /// 桌面端很准时地每 15 分钟记一次，下一次 = 上一次 + 15 分钟。停了（ClaudeProvider.staleAfter）时是 nil：说不准下一次什么时候
    private func nextOfficialText(now: Date) -> String? {
        guard let last = snapshot?.officialAt else { return tr("官方读数暂时没有", "no official reading yet") }
        let next = last.addingTimeInterval(WindowInference.sampleSpacing)
        if next > now { return tr("下次约 \(Fmt.clock(next, now: now))", "next around \(Fmt.clock(next, now: now))") }
        if now.timeIntervalSince(last) < ClaudeProvider.staleAfter { return tr("下一次随时会到", "the next one is due any moment") }
        return nil
    }
}

/// 戳宠物时按下去缩一下、松开弹回来
struct PokeStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.5), value: configuration.isPressed)
    }
}

/// 同时有几家时，头部下面的切换条：每段带着那家最紧张窗口的百分比，宠物跟着的那家有个小爪印
struct ProviderTabs: View {
    var snapshots: [UsageSnapshot]
    var selected: ProviderID
    var focus: ProviderID?
    var onSelect: (ProviderID) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(snapshots, id: \.provider) { snapshot in
                let on = snapshot.provider == selected
                Button { onSelect(snapshot.provider) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: MenuBarIcon.glyph(for: snapshot.provider))
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(snapshot.provider == .claude ? Color(red: 0.85, green: 0.47, blue: 0.34) : .primary)
                        Text(snapshot.provider.displayName).font(.system(size: 12, weight: on ? .semibold : .regular))
                        if snapshot.hasData, let top = snapshot.tightest {
                            Text(Fmt.percent(top.clampedPercent))
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(Level.text(top.percent))
                        } else {
                            Text("–").foregroundStyle(.tertiary)
                        }
                        if snapshot.provider == focus {
                            Image(systemName: "pawprint.fill").font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(on ? (colorScheme == .dark ? Color.white.opacity(0.14) : .white) : .clear)
                        .shadow(color: .black.opacity(on ? 0.12 : 0), radius: 1, y: 0.5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(on ? .primary : .secondary)
                .help(tr("看 \(snapshot.provider.displayName) 的额度", "Show \(snapshot.provider.displayName) usage"))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.07)))
    }
}

/// 一个额度窗口：大数字 + 进度条 + 重置时间
struct WindowCard: View {
    var window: UsageWindow
    var now: Date

    var body: some View {
        let pace = window.pace(now: now)
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(window.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if window.estimatedExtra >= 0.5 {
                    Text("≈").font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary)
                }
                Text(Fmt.percent(window.clampedPercent))
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Level.text(window.percent))
                    .contentTransition(.numericText())
            }
            UsageBar(percent: window.clampedPercent, official: window.official, tint: Level.bar(window.percent),
                     pace: pace?.expected)
                .padding(.bottom, 1)
            legend
            if window.otherPercent >= 1 {
                Text(tr("其中约 \(Int(window.otherPercent.rounded()))% 是 Claude Code 以外（聊天、网页、手机）用的",
                        "About \(Int(window.otherPercent.rounded()))% came from outside Claude Code (chat, web, mobile)"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Text(resetText)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            if let pace {
                PaceLine(pace: pace)
            }
            if let exhaustion = window.projectedExhaustion(now: now), let burn = window.burnPerHour {
                let rate = rateValue(burn), clock = Fmt.clock(exhaustion, now: now)
                Label(tr("照这个速度（\(unit) \(rate)%\(otherBurnText)），\(clock) 左右用完",
                         "At this rate (\(rate)%\(unit)\(otherBurnText)), it runs out around \(clock)"),
                      systemImage: "flame.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .fixedSize(horizontal: false, vertical: true)
            } else if let burn = window.burnPerHour, window.perUnit(burn) >= 1, window.percent < 100 {
                Text(tr("\(lookbackText)：\(unit)约 \(rateValue(burn))%\(otherBurnText)",
                        "\(lookbackText): about \(rateValue(burn))%\(unit)\(otherBurnText)"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    /// 速度的单位：一天以上的窗口按天说（每天 20%），5 小时窗口按小时说（每小时 42%）
    private var unit: String {
        window.burnUnit >= 86400 ? tr("每天", "/day") : tr("每小时", "/hr")
    }

    private func rateValue(_ perHour: Double) -> Int { Int(window.perUnit(perHour).rounded()) }

    /// 消耗速度里有其他端的部分时，补一句「，其中其他端约 6%」
    private var otherBurnText: String {
        guard let other = window.otherBurnPerHour, window.perUnit(other) >= 1 else { return "" }
        return tr("，其中聊天、网页等约 \(rateValue(other))%", ", ~\(rateValue(other))% from chat, web, etc.")
    }

    private var lookbackText: String {
        window.burnLookback >= 86400
            ? tr("最近 24 小时", "Last 24 hours")
            : tr("最近 \(Int(window.burnLookback / 60)) 分钟", "Last \(Int(window.burnLookback / 60)) min")
    }

    /// 进度条的图例：实色 = 官方读数，浅色 = 之后的本机估算。一行放不下（英文比较长）就上下排
    @ViewBuilder private var legend: some View {
        if window.official != nil || window.estimatedExtra >= 0.5 {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { legendItems }
                VStack(alignment: .leading, spacing: 3) { legendItems }
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var legendItems: some View {
        let tint = Level.bar(window.percent)
        let extra = window.estimatedExtra
        if let official = window.official, let at = window.officialAt {
            let ago = Fmt.ago(at, now: now)
            LegendItem(color: tint, text: window.limitReported
                       ? tr("Claude Code 报告用完了（\(ago)）", "Claude Code: used up (\(ago))")
                       : tr("官方 \(Int(official))%（\(ago)）", "Official \(Int(official))% (\(ago))"))
        }
        if extra >= 0.5 {
            let amount = "\(window.official == nil ? "" : "+")\(Int(extra.rounded()))%"
            LegendItem(color: tint.opacity(0.4), text: tr("本机估算 \(amount)", "Local estimate \(amount)"))
        }
    }

    private var resetText: String {
        if let reset = window.resetsAt {
            let when = Fmt.fromNow(reset.timeIntervalSince(now)), clock = Fmt.clock(reset, now: now)
            return window.percent >= 100
                ? tr("\(when)恢复 · \(clock)", "Back \(when) · \(clock)")
                : tr("\(when)重置 · \(clock)", "Resets \(when) · \(clock)")
        }
        return window.percent < 0.5
            ? tr("还没开始计时（下次使用时开始）", "Not started yet (starts the next time you use it)")
            : tr("重置时间未知", "Reset time unknown")
    }
}

/// 图例里的一个小色块 + 文字
struct LegendItem: View {
    var color: Color
    var text: String

    var body: some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(color).frame(width: 9, height: 7)
            Text(text).lineLimit(1)
        }
    }
}

/// 每周额度等长窗口：比平均节奏多用了还是少用了，之后每天能用多少。
/// 前面的小竖线和进度条上的刻度一样，一看就知道刻度是什么意思；多用 10 个点以上标橙
struct PaceLine: View {
    var pace: UsageWindow.Pace

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            PaceTick()
        }
        .font(.system(size: 11))
        .foregroundStyle(pace.ahead >= 10 ? Color(nsColor: .systemOrange) : .secondary)
    }

    private var text: String {
        let points = Int(abs(pace.ahead).rounded())
        let relation = pace.ahead >= 3
            ? tr("比平均节奏多用 \(points) 个点", "\(plural(points, "point")) over an even pace")
            : pace.ahead <= -3
            ? tr("比平均节奏少用 \(points) 个点", "\(plural(points, "point")) under an even pace")
            : tr("和平均节奏差不多", "On an even pace")
        guard let perDay = pace.perDay else { return relation }
        return relation + (perDay < 1
            ? tr(" · 之后每天可用不到 1%", " · under 1%/day until reset")
            : tr(" · 之后每天可用约 \(Int(perDay.rounded()))%", " · ~\(Int(perDay.rounded()))%/day until reset"))
    }
}

/// 平均节奏的刻度：按平均节奏现在应该用到哪
struct PaceTick: View {
    var body: some View {
        Capsule().fill(Color.primary.opacity(0.55)).frame(width: 2, height: 10)
    }
}

/// 进度条：实色是官方读数，浅色是之后的本机估算；pace 是平均节奏的刻度（长窗口才有）
struct UsageBar: View {
    var percent: Double
    var official: Double?
    var tint: Color
    var pace: Double?

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let estimated = percent / 100
            let confirmed = min(official ?? 0, percent) / 100  // 没有官方读数时整条都是估算
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                if estimated > 0 {
                    Capsule().fill(tint.opacity(0.4)).frame(width: max(estimated * width, 7))
                }
                if confirmed > 0 {
                    Capsule().fill(tint).frame(width: max(confirmed * width, 7))
                }
            }
            // 用 overlay 画刻度：比进度条高一点，但不撑高进度条
            .overlay(alignment: .leading) {
                if let pace {
                    PaceTick().offset(x: min(max(pace / 100 * width - 1, 0), width - 2))
                }
            }
        }
        .frame(height: 7)
        .accessibilityHidden(true)
    }
}

struct TodayCard: View {
    var today: ActivitySummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(tr("今天 · 本机 Claude Code", "Today · Claude Code on this Mac"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("≈ \(Fmt.usd(today.usd))")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            Text(tr("\(today.requests) 次请求 · \(Fmt.tokens(today.tokens)) tokens · 按 API 价格折算",
                    "\(plural(today.requests, "request")) · \(plural(today.tokens, "token", shown: Fmt.tokens(today.tokens))) · at API prices"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if !today.byFamily.isEmpty {
                Text(today.byFamily.map { "\($0.family) \(Fmt.usd($0.usd))" }.joined(separator: "  ·  "))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}

struct NotesView: View {
    var notes: [String]

    var body: some View {
        if !notes.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(notes, id: \.self) { note in
                    Label {
                        Text(note).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "info.circle")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
            }
        }
    }
}
