import SwiftUI
import QuotaPetCore

/// 正常模式的额度面板：沿用旧总览的布局（宠物头部、服务切换条、进度条卡片、页脚）。
/// 数据只来自官方读数：agy 和 Claude 读各自官方 CLI 的 /usage，Codex 读日志里服务器给的 rate_limits。
/// 只接收普通的值，方便 --render-official-previews 直接渲染成图片。
struct OfficialOverviewView: View {
    /// 正在看、宠物也跟着的那家
    var entry: OfficialQuotaEntry
    var choice: OfficialPetChoice
    /// 宠物立绘：按款式和这家自己的心情取图
    var artwork: (OfficialPetChoice, PetMood) -> NSImage
    var reading: AgyQuotaReading?
    /// agy 最近几次读数（只在内存里），宠物表情看变化用
    var agyHistory: [AgyQuotaReading] = []
    var querying = false
    /// 没有可靠读数时的原因（AgyQuotaMonitor.summary）
    var agyStatus = ""
    /// Claude 没读到额度时的原因（ClaudeUsageReading.problem），面板标题用它
    var claudeStatus = ""
    /// Claude / Codex 的官方读数快照（ClaudeOfficialProvider / CodexProvider）
    var usage: [UsageSnapshot] = []
    /// 正在用的几家：切换条上的小圆点带光晕
    var activeEntries: Set<OfficialQuotaEntry> = []
    /// Claude / Codex 桌面端开着没有
    var desktopRunning = false
    var canOpenAntigravity = false
    var onSelect: (OfficialQuotaEntry) -> Void = { _ in }
    var onOpenOfficial: (OfficialQuotaEntry) -> Void = { _ in }
    var onOpenAntigravity: () -> Void = {}
    /// 这家正在读取（含后台自动读取；宠物第一次读取时用「醒过来中」）
    var refreshing = false
    /// 用户点了刷新、这次还没读完：只有这时刷新按钮一直转
    var manualRefreshing = false
    var onRefresh: () -> Void = {}
    /// 刚点完刷新的结果（成功、没读到、要等一会儿），在页脚停几秒
    var refreshNotice: RefreshNotice?
    var onMenu: () -> Void = {}
    var onQuit: () -> Void = {}
    /// agy 被戳时反应里某一帧的图（这款的「-状态」图）；还没补这张图时是 nil，照常显示心情图
    var pokeArtwork: (OfficialPetChoice, String) -> NSImage? = { _, _ in nil }
    /// agy 被戳的反应（OfficialPetChoice.agyReaction）和正在显示的那一帧
    @State private var agyReaction: [OfficialPetChoice.Reaction] = []
    @State private var agyFrame: OfficialPetChoice.Reaction?
    /// 戳了一下宠物：外面按连戳次数挑一句回话（没反应时是 nil）
    var onPoke: (PetMood) -> (line: String, annoyed: Bool)? = { _ in nil }
    /// 新版本：有的话页脚上方出现更新条
    var update: UpdateStatus = .none
    var onUpdate: () -> Void = {}
    /// 渲染预览图时固定「现在」
    var fixedNow: Date?
    /// 面板里用：页脚贴在窗口底边、上面可滚动，并把页面的自然高度报给外面（外面据此平滑伸缩窗口）。预览图不用
    var pinFooter = false
    var onHeight: (CGFloat) -> Void = { _ in }

    /// 被戳后回的那句、反应表情（Claude / Codex 播动画表里的反应帧；agy 按同样的节奏换一下状态图）
    @State private var pokedLine: String?
    @State private var reaction: [PetFrame] = []
    @State private var reactionFrame: PetFrame?
    @State private var pokes = 0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: fixedNow ?? context.date)
        }
    }

    /// Codex 的读数超过 1 小时：照样画出上次的数字，但整体变灰、标明时间
    private func codexStale(_ now: Date) -> Bool { entry == .codex && CodexProvider.isStale(snapshot, now: now) }

    private var snapshot: UsageSnapshot? {
        switch entry {
        case .claude: return usage.first { $0.provider == .claude }
        case .codex: return usage.first { $0.provider == .codex }
        case .antigravity: return nil
        }
    }

    @ViewBuilder private func content(now: Date) -> some View {
        let top = upper(now: now)
            .padding([.horizontal, .top], 14)
            .padding(.bottom, 14)
        let bottom = VStack(spacing: 12) {
            if update.offer != nil { UpdateBar(status: update, action: onUpdate) }
            Divider()
            footer(now: now)
        }
        .padding([.horizontal, .bottom], 14)
        if pinFooter {
            // 窗口伸缩时页脚跟着底边走，上面的卡片区像抽屉一样展开 / 收起
            VStack(spacing: 0) {
                ScrollView {
                    top.background(GeometryReader { Color.clear.preference(key: PanelHeightKey.self, value: $0.size.height) })
                }
                .scrollBounceBehavior(.basedOnSize)
                bottom.background(GeometryReader { Color.clear.preference(key: PanelHeightKey.self, value: $0.size.height) })
            }
            .onPreferenceChange(PanelHeightKey.self) { onHeight($0) }
        } else {
            VStack(spacing: 0) { top; bottom }
        }
    }

    private func upper(now: Date) -> some View {
        let agy = AgyQuotaPresentation(reading: entry == .antigravity ? reading : nil, now: now)
        return VStack(alignment: .leading, spacing: 14) {
            header(agy: agy, now: now)
            OfficialTabs(selected: entry,
                         percents: [
                            .claude: Self.tightest(usage.first { $0.provider == .claude }),
                            .codex: Self.tightest(usage.first { $0.provider == .codex }),
                            .antigravity: AgyQuotaPresentation(reading: reading, now: now).primaryUsedPercent,
                         ],
                         dimmed: CodexProvider.isStale(usage.first { $0.provider == .codex }, now: now) ? [.codex] : [],
                         active: activeEntries,
                         onSelect: onSelect)
            // 切换页签：旧卡片立刻撤下（不和新卡片叠在一起），新卡片淡入；窗口高度由外面跟着平滑伸缩
            VStack(alignment: .leading, spacing: 14) {
            switch entry {
            case .antigravity:
                if agy.windows.isEmpty {
                    AgyUnknownCard(status: agyStatus, querying: querying)
                    agyLinks  // 没读数时才把官方入口摆出来；有读数时在页脚
                } else {
                    VStack(spacing: 10) {
                        ForEach(AgyGroup.of(agy.windows)) { AgyGroupCard(group: $0, now: now) }
                    }
                }
            case .claude, .codex:
                if let snapshot, snapshot.hasData {
                    // 旧总览的进度条卡片，只留大数字、进度条和重置时间；要提醒时才多一行。旧读数整体变灰
                    let stale = codexStale(now)
                    VStack(spacing: 10) {
                        ForEach(snapshot.windows) { QuotaCard(window: $0, now: now) }
                    }
                    .saturation(stale ? 0 : 1)
                    .opacity(stale ? 0.55 : 1)
                    if !stale { NotesView(notes: snapshot.notes) }
                } else {
                    OfficialEntryCard(entry: entry, reason: snapshot?.notes.first) { onOpenOfficial(entry) }
                }
            }
            }
            .id(entry)
            .transition(.asymmetric(insertion: AnyTransition.opacity.animation(.easeOut(duration: 0.24)), removal: .identity))
        }
    }

    /// 切换条上每家显示的数字：有官方读数时最紧张窗口的百分比
    static func tightest(_ snapshot: UsageSnapshot?) -> Double? {
        guard let snapshot, snapshot.hasData, let top = snapshot.tightest else { return nil }
        return top.clampedPercent
    }

    /// 这家现在的心情：只看这家自己的官方读数，没有读数时是中性
    static func mood(entry: OfficialQuotaEntry, snapshot: UsageSnapshot?, agy: AgyQuotaPresentation, now: Date) -> PetMood? {
        switch entry {
        case .antigravity:
            return agy.primaryUsedPercent == nil ? nil : agy.primaryMood
        case .claude, .codex:
            guard let snapshot, snapshot.hasData, !CodexProvider.isStale(snapshot, now: now) else { return nil }
            return PetStatus.of(snapshot, now: now, lateNight: false).mood
        }
    }

    /// 宠物立绘用的表情：额度未知时也分「读取中」「读不到」，agy 还看最近几次读数的变化
    static func artMood(entry: OfficialQuotaEntry, snapshot: UsageSnapshot?, agyReading: AgyQuotaReading?, agyHistory: [AgyQuotaReading],
                        refreshing: Bool, now: Date) -> PetMood {
        switch entry {
        case .antigravity:
            return AgyQuotaPresentation.trendMood(reading: agyReading, history: agyHistory, querying: refreshing, now: now)
        case .claude, .codex:
            if let snapshot, snapshot.hasData, !CodexProvider.isStale(snapshot, now: now) {
                return PetStatus.of(snapshot, now: now, lateNight: false).mood
            }
            return refreshing ? .loading : .normal
        }
    }

    // MARK: - 头部

    private func header(agy: AgyQuotaPresentation, now: Date) -> some View {
        let known = Self.mood(entry: entry, snapshot: snapshot, agy: agy, now: now)
        let mood = Self.artMood(entry: entry, snapshot: snapshot, agyReading: reading, agyHistory: agyHistory,
                                refreshing: entry == .antigravity ? querying : refreshing, now: now)
        let tint = known == nil ? Color(nsColor: .systemGray) : Level.mood(mood)
        // agy 反应帧真有图时才换（缺图、登记过的坏图就留在心情图上，不做淡入淡出）
        let agyShown = choice.isAntigravity ? agyFrame.flatMap { frame in pokeArtwork(choice, frame.state).map { (frame.state, $0) } } : nil
        let agyKey = agyShown?.0 ?? mood.rawValue
        return HStack(alignment: .top, spacing: 12) {
            Button {
                guard let reply = onPoke(mood) else { return }
                pokedLine = reply.line
                // 只放当前这款的反应：Claude / Codex 用动画表，agy 用状态图，绝不沿用上一只宠物的表情
                reaction = choice.style.map { PetSprites.reaction(for: mood, style: $0, annoyed: reply.annoyed) } ?? []
                agyReaction = choice.isAntigravity ? OfficialPetChoice.agyReaction(for: mood, annoyed: reply.annoyed) : []
                reactionFrame = nil
                agyFrame = nil
                pokes += 1
            } label: {
                // 反应表情只画当前这款形象的（切换宠物的瞬间不会露出上一只的表情）。
                // agy 每张图的姿势差得多，换图时淡入淡出一下；Claude / Codex 的帧只换脸，照旧直接切
                ZStack {
                    Image(nsImage: reactionFrame.flatMap { $0.portrait.style == choice.style ? PetRenderer.image($0.portrait) : nil }
                          ?? agyShown?.1
                          ?? artwork(choice, mood))
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .id(choice.isAntigravity ? "\(choice.rawValue)-\(agyKey)" : choice.rawValue)
                        .transition(.opacity)
                }
                .animation(choice.isAntigravity ? .easeInOut(duration: 0.18) : nil, value: agyKey)
                    .frame(width: 96, height: 96)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(tint.opacity(0.13)))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(PokeStyle())
            .focusable(false)  // 开了键盘导航时，别让面板一打开焦点框就落在宠物上
            .help(tr("戳戳她 · \(choice.label)", "Give her a poke · \(choice.label)"))
            .accessibilityLabel(tr("戳一下宠物", "Poke the pet"))
            .task(id: "\(pokes)-\(choice.rawValue)") {  // 换了宠物就取消正在播的反应
                // 播完反应表情回到平时；那句话留到 pokeLineDuration。又戳一下时这个任务会被取消，别把新的那句清掉
                guard pokes > 0, !reaction.isEmpty || !agyReaction.isEmpty || pokedLine != nil else { return }
                var elapsed: TimeInterval = 0
                for frame in reaction {
                    reactionFrame = frame
                    try? await Task.sleep(nanoseconds: UInt64(frame.duration * 1_000_000_000))
                    if Task.isCancelled { return }
                    elapsed += frame.duration
                }
                for frame in agyReaction {
                    agyFrame = frame
                    try? await Task.sleep(nanoseconds: UInt64(frame.duration * 1_000_000_000))
                    if Task.isCancelled { return }
                    elapsed += frame.duration
                }
                reactionFrame = nil
                agyFrame = nil
                let rest = PetChat.pokeLineDuration - elapsed
                if rest > 0 { try? await Task.sleep(nanoseconds: UInt64(rest * 1_000_000_000)) }
                if !Task.isCancelled { pokedLine = nil }
            }
            .onChange(of: choice.rawValue) { pokedLine = nil; reactionFrame = nil; reaction = []; agyFrame = nil; agyReaction = [] }  // 换了一只宠物
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(entry.tabName)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    StatusBadge(text: badge(known: known != nil, mood: mood), tint: tint)
                    Spacer(minLength: 0)
                    HStack(spacing: 0) {
                        // 三家同一个刷新按钮：点了至少转一圈，点的这次没读完就一直转，读完转完这一圈停下；
                        // 后台自动读取不转，免得切过去看到一直在转
                        RefreshButton(busy: manualRefreshing, help: refreshHelp, action: onRefresh)
                            .id(entry)  // 换页签时各家从自己的状态开始，不接着上一家没转完的那圈
                        IconButton(systemName: "gearshape", help: tr("宠物形象、启动方式和更多", "Pet, startup and more"),
                                   action: onMenu)
                    }
                }
                // 两行：一句结论，一句她说的话（戳她时换成回话）
                let lines = headline(agy: agy, mood: mood, now: now)
                Text(lines.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(lines.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
                if let note = pokedLine ?? lines.detail {
                    Text(note)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.leading, 2)
        }
    }

    private var refreshHelp: String {
        entry == .codex
            ? tr("重新读取本机日志里的官方读数（Codex 每轮对话后才会记新读数）",
                 "Reload the official readings in the local logs (Codex records a new one after each turn)")
            : tr("马上用官方 CLI 重新读取（两次之间至少 30 秒）", "Read again now with the official CLI (at least 30 s apart)")
    }

    private func badge(known: Bool, mood: PetMood) -> String {
        if known { return mood.title }
        if entry == .codex, snapshot?.hasData == true { return tr("读数较旧", "Old reading") }
        if entry != .antigravity { return tr("额度未知", "Unknown") }
        return querying ? tr("读取中", "Reading") : tr("额度未知", "Unknown")
    }

    private struct Headline {
        var title: String
        var color: Color = .primary
        var detail: String?
        var note: String?
    }

    private func headline(agy: AgyQuotaPresentation, mood: PetMood, now: Date) -> Headline {
        switch entry {
        case .claude, .codex:
            guard let snapshot, snapshot.hasData else {
                if entry == .claude, !claudeStatus.isEmpty { return Headline(title: claudeStatus, color: .secondary) }
                return Headline(title: tr("暂无可用的官方读数", "No usable official reading"), color: .secondary,
                                detail: entry == .codex ? desktopText : nil)
            }
            if codexStale(now), let readAt = snapshot.officialAt {
                return Headline(title: tr("读数是\(Fmt.ago(readAt, now: now))的", "Reading from \(Fmt.ago(readAt, now: now))"), color: .secondary,
                                detail: tr("本机 Codex 下次记下总额度时更新", "Updates when Codex on this Mac next records the overall quota"))
            }
            // 和旧面板一样：先说最有用的一条（用完了、照这个速度何时见底、比平均节奏快…），再是她的一句话
            let status = PetStatus.of(snapshot, now: now, lateNight: false)
            // 要提醒（用完了、照这速度会见底、读数停了）时说提醒；平时只说最紧张的那个窗口，不把卡片再念一遍
            if let top = PanelHeadline.of(snapshot, now: now), [.blocked, .forecast, .stale].contains(top.kind) {
                let color = top.kind == .blocked ? Color(nsColor: .systemRed) : Color(nsColor: .systemOrange)
                return Headline(title: top.text, color: color, detail: status.line(0))
            }
            guard let tight = snapshot.tightest else { return Headline(title: status.line(0), color: .secondary) }
            return Headline(title: tr("\(tight.displayTitle)已用 \(Fmt.percent(tight.clampedPercent))",
                                      "\(tight.displayTitle): \(Fmt.percent(tight.clampedPercent)) used"),
                            color: tight.percent >= 90 ? Color(nsColor: .systemRed) : tight.percent >= 75 ? Color(nsColor: .systemOrange) : .primary,
                            detail: status.line(0))
        case .antigravity:
            if agy.primaryUsedPercent == nil, !agy.windows.isEmpty {
                // 为准的 Gemini 窗口已经重置，下面其余窗口仍是这次读数里的
                return Headline(title: tr("Gemini 额度已到重置时间", "The Gemini quota has reset"), color: .secondary,
                                detail: tr("等下次官方读数确认新的额度", "Waiting for the next official reading"))
            }
            guard let used = agy.primaryUsedPercent, let top = agy.primaryWindow else {
                return Headline(title: agyStatus.isEmpty ? tr("额度未知", "Quota unknown") : agyStatus, color: .secondary)
            }
            let remaining = Fmt.percent(max(0, 100 - used))
            let short = AgyWindowRow.shortName(top.window)
            let title = used >= 100
                ? tr("\(top.group) \(short)已用完", "\(top.group) \(short) is used up")
                : tr("\(top.group) \(short)已用 \(Fmt.percent(used))", "\(top.group) \(short): \(Fmt.percent(used)) used")
            return Headline(title: title,
                            color: used >= 90 ? Color(nsColor: .systemRed) : used >= 75 ? Color(nsColor: .systemOrange) : .primary,
                            // 和 Claude / Codex 一样，第二行是她说的话（心情和头像同一个），剩余多少看下面的卡片
                            detail: agy.petLine(mood: mood, now: now)
                                ?? tr("\(top.group) 组 · 还剩 \(remaining)", "\(top.group) group · \(remaining) left"))
        }
    }

    private var desktopText: String {
        desktopRunning
            ? tr("\(entry.serviceName) 桌面端已打开", "\(entry.serviceName) desktop app is open")
            : tr("\(entry.serviceName) 桌面端未打开", "\(entry.serviceName) desktop app is closed")
    }

    // MARK: - agy 官方入口

    private var agyLinks: some View {
        HStack(spacing: 8) {
            if canOpenAntigravity {
                CapsuleButton(title: tr("打开 Antigravity", "Open Antigravity"), systemImage: "arrow.up.forward.app",
                              action: onOpenAntigravity)
            }
            CapsuleButton(title: tr("/usage 说明", "/usage guide"), systemImage: "book", prominent: false) {
                onOpenOfficial(.antigravity)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - 页脚

    private func footer(now: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            // 刚点过刷新：几秒内这里换成结果提示，之后回到「官方读数 · 几分钟前」
            Group {
                if let notice = refreshNotice, notice.entry == entry {
                    Label(notice.text, systemImage: Self.noticeIcon(notice.kind))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Self.noticeColor(notice.kind))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(notice.text)
                        .transition(.opacity.combined(with: .offset(y: 3)))
                        .id(notice.at)
                } else {
                    Text(sourceLine(now: now))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .help(sourceHelp)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.22), value: refreshNotice)
            Spacer(minLength: 4)
            Button(tr("官方用量页", "Official page")) { onOpenOfficial(entry) }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)
                .help(tr("在浏览器打开 \(entry.serviceName) 的官方用量页", "Open \(entry.serviceName)’s official usage page"))
            Button(tr("退出", "Quit"), action: onQuit)
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    static func noticeIcon(_ kind: RefreshNotice.Kind) -> String {
        switch kind {
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .tooSoon: return "clock.fill"
        }
    }

    static func noticeColor(_ kind: RefreshNotice.Kind) -> Color {
        switch kind {
        case .done: return Color(nsColor: .systemGreen)
        case .failed: return Color(nsColor: .systemOrange)
        case .tooSoon: return .secondary
        }
    }

    /// 页脚只说读数是什么时候的；来源细节放在悬停说明里
    private func sourceLine(now: Date) -> String {
        let readAt: Date?
        switch entry {
        case .claude, .codex: readAt = snapshot?.officialAt
        case .antigravity: readAt = reading?.checkedAt
        }
        guard let readAt else {
            // 已经试过、没读到（比如没装命令行）：不说「等待读取」，免得和标题的原因对不上
            if entry == .claude, !claudeStatus.isEmpty { return tr("官方读数 · 没读到", "Official reading · not available") }
            return tr("官方读数 · 等待读取", "Official reading · pending")
        }
        return tr("官方读数 · \(Fmt.ago(readAt, now: now))", "Official reading · \(Fmt.ago(readAt, now: now))")
    }

    private var sourceHelp: String {
        switch entry {
        case .claude: return tr("来源：官方 Claude Code CLI 的 /usage，每 12 分钟读一次，用完 Claude Code 后也会自动读",
                                "Source: the official Claude Code CLI’s /usage, every 12 min and after Claude Code activity")
        case .codex: return tr("来源：Codex 每轮对话后记在本机日志里的官方读数", "Source: official readings Codex logs after every turn")
        case .antigravity: return tr("来源：官方 agy CLI 的 /usage，每 12 分钟读一次", "Source: the official agy CLI’s /usage, every 12 min")
        }
    }
}

/// 精简的额度卡片：标题 + 大数字 + 进度条 + 一行重置时间；照这速度会在重置前用完、或比平均节奏快很多时才多一行
struct QuotaCard: View {
    var window: UsageWindow
    var now: Date

    var body: some View {
        let pace = window.pace(now: now)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.displayTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(Fmt.percent(window.clampedPercent))
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Level.text(window.percent))
                    .contentTransition(.numericText())
            }
            UsageBar(percent: window.clampedPercent, official: window.official, tint: Level.bar(window.percent), pace: pace?.expected)
            Text(resetText)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            if let exhaustion = window.projectedExhaustion(now: now) {
                Label(tr("照这个速度，\(Fmt.clock(exhaustion, now: now)) 左右用完", "At this rate, it runs out around \(Fmt.clock(exhaustion, now: now))"),
                      systemImage: "flame.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(nsColor: .systemOrange))
            } else if let pace, pace.ahead >= 10 {
                PaceLine(pace: pace)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
        .accessibilityElement(children: .combine)
    }

    private var resetText: String {
        if let reset = window.resetsAt {
            let when = Fmt.fromNow(reset.timeIntervalSince(now)), clock = Fmt.clock(reset, now: now)
            return window.percent >= 100
                ? tr("\(when)恢复 · \(clock)", "Back \(when) · \(clock)")
                : tr("\(when)重置 · \(clock)", "Resets \(when) · \(clock)")
        }
        return window.percent < 0.5
            ? tr("还没开始计时", "Not started yet")
            : tr("重置时间以官方页面为准", "See the official page for the reset time")
    }
}

extension OfficialQuotaEntry {
    /// 面板上的服务名
    var serviceName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .antigravity: return "Antigravity"
        }
    }

    var tabName: String { self == .antigravity ? "agy" : serviceName }

    var glyph: String {
        switch self {
        case .claude: return MenuBarIcon.glyph(for: .claude)
        case .codex: return MenuBarIcon.glyph(for: .codex)
        case .antigravity: return "sparkles"
        }
    }
}

/// 三家服务的切换条：液态玻璃胶囊轨道，选中的那家是一颗明亮的玻璃胶囊。
/// 和系统分段控件一样：点一下滑过去，也可以按住胶囊左右拖，松手停在离得最近的那家。
/// 整条只有一颗胶囊（不在各格之间删了再建），切换时不会留下残影。
/// 每格一行：小圆点 + 服务名 + 百分比。macOS 26 以下退回毛玻璃材质
struct OfficialTabs: View {
    var selected: OfficialQuotaEntry
    /// 每家最紧张窗口的百分比；没有可靠的官方读数时没有
    var percents: [OfficialQuotaEntry: Double?] = [:]
    /// 读数较旧的几家：数字变灰
    var dimmed: Set<OfficialQuotaEntry> = []
    /// 正在用的几家（最近 10 分钟有动静）
    var active: Set<OfficialQuotaEntry> = []
    var onSelect: (OfficialQuotaEntry) -> Void
    @Environment(\.colorScheme) private var colorScheme
    /// 各格在切换条里的位置（量出来的，名字长短不同时各格不一定一样宽）
    @State private var frames: [OfficialQuotaEntry: CGRect] = [:]
    /// 正在拖：胶囊中心跟着手指的横坐标
    @State private var dragX: CGFloat?
    /// 刚松手选中、外面还没换过来的那家：胶囊先停在这里，不弹回旧位置
    @State private var pending: OfficialQuotaEntry?
    /// 上一次是拖完松手（落位带一点回弹）还是点一下（干脆落位）
    @State private var dropped = false
    /// 键盘焦点在哪一格（开了「全键盘控制」才会有）
    @FocusState private var focused: OfficialQuotaEntry?

    private static let space = "OfficialTabs"

    var body: some View {
        // 液态玻璃接口只在 macOS 26 SDK（Swift 6.2 起）里有；更旧的工具链（比如 CI）只编毛玻璃版本
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 4) {
                track {
                    // 选中态：不带颜色的明亮玻璃（带主题色在暗色下会发褐）；浅色下用实白加柔和阴影，才和轨道分得开。
                    // 暗色下玻璃会透出面板后面的东西，后面是亮色地图、网页时轨道和胶囊一样亮：
                    // 胶囊提亮并加一圈亮边，轨道垫一层深色底，不靠背景也分得开
                    Capsule()
                        .fill(Color.white.opacity(colorScheme == .dark ? 0.22 : 0.95))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.35 : 0), lineWidth: 0.75))
                        .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.14), radius: 2, y: 1)
                        .glassEffect(.regular, in: .capsule)
                }
                .padding(3)
                // 浅色背景上玻璃轨道几乎看不出来：加一层很淡的深色底和细描边；暗色下深色底更重，压住透进来的亮背景
                .background(Capsule().fill(Color.black.opacity(colorScheme == .dark ? 0.32 : 0.07)))
                .overlay(Capsule().strokeBorder(Color.black.opacity(colorScheme == .dark ? 0 : 0.08), lineWidth: 0.5))
                .glassEffect(.regular, in: .capsule)
            }
        } else {
            materialBar
        }
        #else
        materialBar
        #endif
    }

    /// macOS 26 以前：毛玻璃轨道 + 白色胶囊
    private var materialBar: some View {
        track {
            Capsule()
                .fill(colorScheme == .dark ? Color.white.opacity(0.22) : Color.white)
                .overlay(Capsule().strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.35 : 0), lineWidth: 0.75))
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.12), radius: 2, y: 1)
        }
        .padding(4)
        .background(Capsule().fill(.ultraThinMaterial))
        .background(Capsule().fill(Color.black.opacity(colorScheme == .dark ? 0.32 : 0.06)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
    }

    /// 胶囊现在该停的那家：拖动中是手指下面那格，否则是选中的那家
    private var target: OfficialQuotaEntry { dragX.map { Self.nearest($0, in: frames) ?? selected } ?? pending ?? selected }

    static func nearest(_ x: CGFloat, in frames: [OfficialQuotaEntry: CGRect]) -> OfficialQuotaEntry? {
        guard !frames.isEmpty else { return nil }
        return OfficialQuotaEntry.allCases.min { abs((frames[$0]?.midX ?? .infinity) - x) < abs((frames[$1]?.midX ?? .infinity) - x) }
    }

    /// 拖动时胶囊中心的位置：带磁吸。手指在某格中间一带时胶囊几乎吸在这格正中，
    /// 越靠近两格交界跟得越快，过了交界就被下一格吸过去——拖起来有一格一格卡上的手感。
    /// 交界两边连续（左格右边缘 = 右格左边缘），不会跳；两头不超出第一格和最后一格的中心
    static func magnetized(_ x: CGFloat, in frames: [OfficialQuotaEntry: CGRect]) -> CGFloat? {
        guard let at = nearest(x, in: frames), let rest = frames[at],
              let first = frames[OfficialQuotaEntry.allCases.first!], let last = frames[OfficialQuotaEntry.allCases.last!] else { return nil }
        let half = max(rest.width / 2, 1)
        let t = min(max((x - rest.midX) / half, -1), 1)
        let pulled = rest.midX + (t < 0 ? -1 : 1) * pow(abs(t), 2.4) * half
        return min(max(pulled, first.midX), last.midX)
    }

    /// 胶囊的位置和宽度：拖动时按磁吸后的位置，宽度取手指下那格的；否则停在选中的那格。
    /// 各格位置在同一次布局里传进来（渲染预览图时没有第二次布局，不能等 @State 回写）
    private func pillRect(_ frames: [OfficialQuotaEntry: CGRect]) -> CGRect? {
        let at = dragX.flatMap { Self.nearest($0, in: frames) } ?? pending ?? selected
        guard let rest = frames[at] else { return nil }
        guard let dragX, let mid = Self.magnetized(dragX, in: frames) else { return rest }
        return CGRect(x: mid - rest.width / 2, y: rest.minY, width: rest.width, height: rest.height)
    }

    /// 拖动跟手：快、几乎不回弹（磁吸曲线本身负责「卡上」的感觉）
    private static let follow = Animation.interactiveSpring(response: 0.16, dampingFraction: 0.86)
    /// 点一下：短而干脆，不来回晃
    private static let tapSettle = Animation.spring(response: 0.26, dampingFraction: 0.92)
    /// 拖完松手：落位时轻轻一顿
    private static let dropSettle = Animation.spring(response: 0.3, dampingFraction: 0.74)

    private func track<Pill: View>(@ViewBuilder pill: @escaping () -> Pill) -> some View {
        segments
            .coordinateSpace(name: Self.space)
            .onPreferenceChange(TabFramesKey.self) { frames = $0 }
            .backgroundPreferenceValue(TabFramesKey.self, alignment: .topLeading) { frames in
                if let rect = pillRect(frames) {
                    pill()
                        .frame(width: rect.width, height: rect.height)
                        // 拖着时稍微鼓起来一点，像系统的液态玻璃滑块；点一下不鼓
                        .scaleEffect(dragX == nil ? 1 : 1.05)
                        .offset(x: rect.minX, y: rect.minY)
                        // 只让胶囊自己动，不带动面板其它部分
                        .animation(dragX != nil ? Self.follow : dropped ? Self.dropSettle : Self.tapSettle, value: rect)
                        .animation(.spring(response: 0.24, dampingFraction: 0.8), value: dragX == nil)
                }
            }
            .onChange(of: selected) { pending = nil }
            // 拖过交界、被下一格吸住时，触控板轻轻一震
            .onChange(of: target) { if dragX != nil { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) } }
            .contentShape(Capsule())
            // 点和拖共用一个手势：横向挪过几个点才算拖（胶囊这时才跟手），否则松手当点击，胶囊直接落到那一格。
            // 这一层和各格所在的坐标系同一个原点（外边距加在外面），用自己的坐标就行
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        if dragX != nil || abs(value.translation.width) > 4 { dragX = value.location.x }
                    }
                    .onEnded { value in
                        let entry = Self.nearest(value.location.x, in: frames) ?? selected
                        dropped = dragX != nil
                        dragX = nil
                        pending = entry
                        if entry != selected { onSelect(entry) }
                    }
            )
    }

    private var segments: some View {
        HStack(spacing: 0) {
            ForEach(OfficialQuotaEntry.allCases, id: \.self) { entry in
                let on = entry == target
                let percent = percents[entry] ?? nil
                HStack(spacing: 5) {
                        Circle().fill(Self.tint(entry)).frame(width: 6, height: 6)
                            .opacity(on || active.contains(entry) ? 1 : 0.7)
                            // 正在用：圆点外一圈同色光晕
                            .background(Circle().fill(Self.tint(entry).opacity(active.contains(entry) ? 0.3 : 0)).frame(width: 12, height: 12))
                            .help(active.contains(entry) ? tr("\(entry.serviceName) 正在用", "\(entry.serviceName) is in use") : "")
                        Text(entry.tabName)
                            .font(.system(size: 12, weight: on ? .semibold : .medium))
                            .foregroundStyle(on ? .primary : .secondary)
                            .fixedSize()
                        Text(percent.map { Fmt.percent($0) } ?? "–")
                            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(dimmed.contains(entry) ? Color.secondary : percent.map { Level.text($0) } ?? Color.secondary)
                            .contentTransition(.numericText())
                            .fixedSize()  // 名字和数字都不截断
                }
                .lineLimit(1)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: TabFramesKey.self, value: [entry: proxy.frame(in: .named(Self.space))])
                })
                .help(tr("看 \(entry.serviceName) 的额度", "Show \(entry.serviceName) usage"))
                // 开了「全键盘控制」时每格能用 Tab 选到（和按钮一样，平时不抢焦点）：空格 / 回车切过去，左右方向键换到相邻那家。
                // 系统的方形焦点框换成贴合胶囊的描边
                .focusable(interactions: .activate)
                .focused($focused, equals: entry)
                .focusEffectDisabled()
                .overlay(Capsule().strokeBorder(Color.accentColor, lineWidth: 2).padding(1).opacity(focused == entry ? 1 : 0))
                .onKeyPress(.space) { choose(entry) }
                .onKeyPress(.return) { choose(entry) }
                .onKeyPress(.leftArrow) { step(-1, from: entry) }
                .onKeyPress(.rightArrow) { step(1, from: entry) }
                // 手势挂在整条上，读屏时每格仍是一个能按的按钮
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(entry.serviceName)
                .accessibilityValue(percent.map { Fmt.percent($0) } ?? tr("未知", "Unknown"))
                .accessibilityAddTraits(entry == selected ? [.isButton, .isSelected] : .isButton)
                .accessibilityAction { onSelect(entry) }
            }
        }
        .animation(.easeOut(duration: 0.15), value: target)
    }

    private func choose(_ entry: OfficialQuotaEntry) -> KeyPress.Result {
        dropped = false
        pending = entry
        if entry != selected { onSelect(entry) }
        return .handled
    }

    /// 方向键：焦点和选中一起挪到相邻那家；到头了就停在原地
    private func step(_ by: Int, from entry: OfficialQuotaEntry) -> KeyPress.Result {
        let all = OfficialQuotaEntry.allCases
        guard let index = all.firstIndex(of: entry), all.indices.contains(index + by) else { return .handled }
        focused = all[index + by]
        return choose(all[index + by])
    }

    static func tint(_ entry: OfficialQuotaEntry) -> Color {
        switch entry {
        case .claude: return Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex: return Color(red: 0.25, green: 0.65, blue: 0.55)
        case .antigravity: return Color(red: 0.36, green: 0.52, blue: 0.95)
        }
    }
}

/// 刷新按钮：同一个箭头，匀速转圈。点一下至少转满一圈；点了刷新、官方 CLI 还在读时（Claude / agy）一直转，
/// 读完把手上这一圈转完再停，不会半路跳回原位，也不换成系统的小菊花
struct RefreshButton: View {
    var busy: Bool
    var help: String
    var action: () -> Void
    @State private var angle = 0.0
    /// 手上这一圈转到什么时候：新的一圈等它转完再接，不叠在一起忽快忽慢
    @State private var lapEnds = Date.distantPast
    private static let lap: TimeInterval = 0.8

    var body: some View {
        IconButton(systemName: "arrow.clockwise",
                   help: busy ? tr("正在读取官方额度", "Reading official usage") : help,
                   rotation: angle) {
            guard !busy else { return }
            action()
            if Date() >= lapEnds { turn() }
        }
        // 读取中一圈接一圈；读完或按钮被撤下（换页签、进设置）时 SwiftUI 取消这个任务，已经起步的那圈照常转完
        .task(id: busy) {
            guard busy else { return }
            while !Task.isCancelled {
                let wait = lapEnds.timeIntervalSinceNow
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                if Task.isCancelled { return }
                turn()
            }
        }
    }

    private func turn() {
        lapEnds = Date().addingTimeInterval(Self.lap)
        withAnimation(.linear(duration: Self.lap)) { angle += 360 }
    }
}

/// 切换条各格的位置
private struct TabFramesKey: PreferenceKey {
    static let defaultValue: [OfficialQuotaEntry: CGRect] = [:]
    static func reduce(value: inout [OfficialQuotaEntry: CGRect], nextValue: () -> [OfficialQuotaEntry: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// 迷你圆环：按百分比填色；没有读数时是一圈灰色虚线
struct MiniRing: View {
    var percent: Double?
    var tint: Color

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: 2.2)
            if let percent {
                Circle()
                    .trim(from: 0, to: max(0.04, min(percent, 100) / 100))
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            } else {
                Circle().stroke(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1.2, dash: [2, 2]))
            }
        }
        .frame(width: 12, height: 12)
        .accessibilityHidden(true)
    }
}

/// agy 的一个模型组：同组的几个窗口放在一张卡片里，五小时在上、每周在下
struct AgyGroup: Identifiable {
    var id: String { name }
    var name: String
    var windows: [AgyQuotaPresentation.WindowState]

    static func of(_ windows: [AgyQuotaPresentation.WindowState]) -> [AgyGroup] {
        var groups: [AgyGroup] = []
        for window in windows {
            if let index = groups.firstIndex(where: { $0.name == window.group }) {
                groups[index].windows.append(window)
            } else {
                groups.append(AgyGroup(name: window.group, windows: [window]))
            }
        }
        // 短窗口在上：和旧面板「5 小时会话」在「本周额度」上面一样
        return groups.map { group in
            var group = group
            group.windows.sort { ($0.window == "五小时" ? 0 : 1) < ($1.window == "五小时" ? 0 : 1) }
            return group
        }
    }
}

/// 一个模型组的卡片：每个窗口一行「标题 + 已用百分比 + 进度条 + 剩余和重置时间」，旧额度卡片的画法
struct AgyGroupCard: View {
    var group: AgyGroup
    var now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(group.name)
                .font(.system(size: 12, weight: .semibold))
            ForEach(group.windows) { AgyWindowRow(window: $0, now: now) }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}

struct AgyWindowRow: View {
    var window: AgyQuotaPresentation.WindowState
    var now: Date

    var body: some View {
        let used = window.usedPercent
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(windowName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if let used {
                    Text(tr("已用", "Used"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(Fmt.percent(used))
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Level.text(used))
                        .contentTransition(.numericText())
                } else {
                    Text("–")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(.tertiary)
                }
            }
            // 每周窗口画平均节奏刻度（和 Claude 卡片一样）；多用 10 个点以上时多一行提醒
            let pace = window.pace(now: now)
            UsageBar(percent: used ?? 0, official: used ?? 0, tint: Level.bar(used ?? 0), pace: pace?.expected)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let pace, pace.ahead >= 10 {
                PaceLine(pace: pace)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// 头部用的短名：五小时 / 每周
    static func shortName(_ window: String) -> String {
        switch window {
        case "每周": return tr("每周", "weekly")
        case "五小时": return tr("5 小时", "5-hour")
        default: return window
        }
    }

    private var windowName: String {
        switch window.window {
        case "每周": return tr("每周窗口", "Weekly window")
        case "五小时": return tr("五小时窗口", "5-hour window")
        default: return window.window
        }
    }

    private var detail: String {
        guard let used = window.usedPercent, let remaining = window.remainingPercent else {
            return tr("已到重置时间 · 等下次官方读数", "Reset time reached · waiting for the next official reading")
        }
        let left = tr("剩余 \(Fmt.percent(remaining))", "\(Fmt.percent(remaining)) left")
        guard let reset = window.resetsAt else {
            return left + tr(" · 官方未显示重置时间", " · no reset time shown")
        }
        let when = Fmt.fromNow(reset.timeIntervalSince(now)), clock = Fmt.clock(reset, now: now)
        return left + " · " + (used >= 100
            ? tr("\(when)恢复 · \(clock)", "back \(when) · \(clock)")
            : tr("\(when)重置 · \(clock)", "resets \(when) · \(clock)"))
    }
}

/// agy 还没有可靠读数：说清原因，不画百分比
struct AgyUnknownCard: View {
    var status: String
    var querying: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(tr("agy 官方额度", "agy official quota"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if querying {
                    ProgressView().controlSize(.small)
                } else {
                    Text("–")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(.tertiary)
                }
            }
            UsageBar(percent: 0, official: 0, tint: .gray, pace: nil)
            Label {
                Text(querying
                     ? tr("正在用官方 CLI 读取 /usage…", "Reading /usage with the official CLI…")
                     : tr("会自动重试（最长每 12 分钟一次）；也可以打开 Antigravity，在设置里查看用量。",
                          "Retries automatically (up to every 12 minutes). You can also open Antigravity and check usage in Settings."))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "info.circle")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}

/// Claude / Codex 暂时没有可用的官方读数：说明原因，给官方入口
struct OfficialEntryCard: View {
    var entry: OfficialQuotaEntry
    /// 为什么没有读数（快照里的说明）
    var reason: String?
    var onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(tr("\(entry.serviceName) 额度", "\(entry.serviceName) usage"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("–")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
            UsageBar(percent: 0, official: 0, tint: .gray, pace: nil)
            Label {
                Text(reason ?? tr("正在读取本机记下的官方读数…", "Reading the official readings recorded on this Mac…"))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "info.circle")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            CapsuleButton(title: tr("在浏览器查看 \(entry.serviceName) 用量", "View \(entry.serviceName) usage in browser"),
                          systemImage: "arrow.up.right.square", action: onOpen)
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}

/// 胶囊按钮（和接力卡片的「查看」按钮同一种画法：ImageRenderer 画不出系统样式的按钮）
/// 有新版本时页脚上方的一条：说是哪个版本，点了自动下载安装；正在下载 / 安装时转圈；没成功时说原因、改为打开发布页
struct UpdateBar: View {
    var status: UpdateStatus
    var action: () -> Void

    var body: some View {
        if let offer = status.offer {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title(offer))
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 4)
                if status.busy {
                    ProgressView().controlSize(.small)
                } else if case .failed = status {
                    CapsuleButton(title: tr("打开发布页", "Release page"), systemImage: "arrow.up.forward.square", prominent: false, action: action)
                } else if offer.download == nil {
                    CapsuleButton(title: tr("去下载", "Download"), systemImage: "arrow.up.forward.square", action: action)
                } else {
                    CapsuleButton(title: tr("更新", "Update"), systemImage: "arrow.down.circle", action: action)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(0.1)))
            .accessibilityElement(children: .combine)
        }
    }

    private var icon: String {
        if case .failed = status { return "exclamationmark.circle.fill" }
        return "arrow.down.circle.fill"
    }

    private var tint: Color {
        if case .failed = status { return Color(nsColor: .systemOrange) }
        return .accentColor
    }

    private func title(_ offer: UpdateOffer) -> String {
        switch status {
        case .downloading: return tr("正在下载 \(offer.version)…", "Downloading \(offer.version)…")
        case .installing: return tr("正在安装，马上重新打开…", "Installing, reopening shortly…")
        case .failed: return tr("没能自动更新到 \(offer.version)", "Couldn't update to \(offer.version) automatically")
        default: return tr("有新版本 \(offer.version)", "Version \(offer.version) is available")
        }
    }

    private var detail: String? {
        switch status {
        case .failed(_, let reason): return tr("\(reason)。可以去发布页手动下载。", "\(reason). You can download it from the release page.")
        case .available(let offer) where offer.download == nil:
            return tr("这一版要去发布页手动下载", "This version needs a manual download from the release page")
        case .available: return tr("点「更新」自动下载，校验后替换并重新打开", "Click Update to download, verify, replace and reopen")
        default: return nil
        }
    }
}

struct CapsuleButton: View {
    var title: String
    var systemImage: String
    var prominent = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11.5, weight: .semibold))
                .fixedSize()
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill((prominent ? Color.accentColor : Color.primary).opacity(prominent ? 0.16 : 0.07)))
                .foregroundStyle(prominent ? Color.accentColor : Color.secondary)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

/// 面板各部分的自然高度，加起来就是窗口该有的高度
struct PanelHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value += nextValue() }
}

/// 小状态标签：主题色淡底 + 同色系深一档的字（浅色压暗、深色提亮），有颜色特点也看得清
struct StatusBadge: View {
    var text: String
    var tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Level.readable(tint))
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.15)))
    }
}
