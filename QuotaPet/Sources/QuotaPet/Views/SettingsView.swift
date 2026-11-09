import ServiceManagement
import SwiftUI
import QuotaPetCore

/// 设置页：顶部按「通用 / Claude / Codex」分页，和面板上的切换条对应；本机没有 Codex 的记录时没有 Codex 这一页
struct SettingsView: View {
    enum Page: Hashable { case general, claude, codex }

    @ObservedObject var settings: AppSettings
    /// 打开「手动指定每周重置时间」时的默认值（当前推算出来的时间）
    var suggestedWeeklyReset: Date?
    /// 当前的换算率和学习记录
    var estimation: EstimationInfo?
    /// 本机有 Codex 的额度记录：多一个 Codex 分页，「什么时候出现」也看 Codex 桌面端（设置里关掉显示时不看）
    var hasCodex = false
    /// Codex 最近一次读数的时间，Codex 分页里说明用
    var codexReadingAt: Date?
    /// 在用 Codex（有数据、没在设置里关掉）：「打开时出现」「什么时候藏起来」要把 Codex 也算上
    var watchesCodex = false
    /// 有桌面端可以跟（见 MenuBarVisibility.shouldShow）；没有时「打开时出现」按一直显示算，说明里要讲
    var canFollowApp = true
    /// 「用命令行补官方读数」的状态；nil 表示没有这个功能（演示模式），不显示这一组
    var cliProbeStatus: ClaudeCLIProbeStatus?
    /// 一键「开启并登录」（弹终端登录）；nil 表示没找到命令行，不给按钮
    var onConnectCLI: (() -> Void)?
    /// Claude 最近一次官方读数（桌面端或命令行）的时间，「官方读数」说明里显示
    var claudeReadingAt: Date?
    var onBack: () -> Void
    /// 打开时在哪一页（渲染预览图时也用它指定）
    @State var page: Page = .general

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button(action: onBack) {
                    Label(tr("返回", "Back"), systemImage: "chevron.left").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Spacer()
                Text(tr("设置", "Settings")).font(.system(size: 14, weight: .semibold))
                Spacer()
                Color.clear.frame(width: 44, height: 1)  // 让标题居中
            }

            Picker(tr("设置分页", "Settings page"), selection: $page) {
                Text(tr("通用", "General")).tag(Page.general)
                Text("Claude").tag(Page.claude)
                if hasCodex { Text("Codex").tag(Page.codex) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch page == .codex && !hasCodex ? .general : page {
            case .general: general
            case .claude: claude
            case .codex: codex
            }
        }
        .padding(14)
    }


    @ViewBuilder private var general: some View {
        SettingsGroup(tr("菜单栏", "Menu Bar")) {
            VStack(alignment: .leading, spacing: 5) {
                Text(tr("什么时候出现", "When to show")).font(.system(size: 12))
                Picker(tr("什么时候出现", "When to show"), selection: $settings.visibility) {
                    ForEach(MenuBarVisibility.allCases) { Text($0.label(codex: watchesCodex)).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(settings.visibility.note(codex: watchesCodex, canFollow: canFollowApp))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(tr("宠物旁边显示", "Next to the pet")).font(.system(size: 12))
                Picker(tr("宠物旁边显示", "Next to the pet"), selection: $settings.menuBarText) {
                    ForEach(MenuBarTextMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            SwitchRow(tr("宠物动画", "Animate pet"), isOn: $settings.animatePet)
        }

        SettingsGroup(tr("提醒", "Notifications")) {
            SwitchRow(tr("用量提醒", "Usage alerts"), isOn: $settings.notificationsEnabled)
            HStack(spacing: 6) {
                Text(tr("提醒阈值", "Alert at")).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                ForEach([50, 75, 90, 100], id: \.self) { threshold in
                    Toggle("\(threshold)%", isOn: thresholdBinding(threshold))
                        .toggleStyle(.button)
                        .controlSize(.small)
                }
            }
            .disabled(!settings.notificationsEnabled)
            SwitchRow(tr("快用完时提前提醒", "Warn before running out"),
                      subtitle: tr("照最近的速度快用完时提醒一次：5 小时额度提前约半小时，每周额度提前约一天",
                                   "Alerts once when the recent pace will use it up: about 30 min ahead for the 5-hour window, a day ahead for the weekly quota"),
                      isOn: $settings.notifyRunningOut)
                .disabled(!settings.notificationsEnabled)
            SwitchRow(tr("额度恢复时提醒", "Notify when quota resets"), isOn: $settings.notifyOnReset)
            if settings.notificationsDenied, settings.notificationsEnabled || settings.notifyOnReset {
                VStack(alignment: .leading, spacing: 3) {
                    Text(tr("系统设置里没允许 QuotaPet 发通知，上面的提醒都弹不出来。",
                            "QuotaPet isn't allowed to send notifications in System Settings, so these alerts won't appear."))
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(tr("打开通知设置", "Open Notification Settings"), action: openNotificationSettings)
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                }
            }
        }

        SettingsGroup(tr("其他", "Other")) {
            VStack(alignment: .leading, spacing: 5) {
                Text(tr("语言", "Language")).font(.system(size: 12))
                Picker(tr("语言", "Language"), selection: $settings.language) {
                    Text(tr("跟随系统", "System")).tag(Language?.none)
                    ForEach(Language.allCases) { Text($0.nativeName).tag(Language?.some($0)) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            SwitchRow(tr("开机自动启动", "Launch at login"),
                      subtitle: watchesCodex
                          ? tr("开着才能在 Claude 或 Codex 打开时自动出现", "Lets the pet appear when Claude or Codex opens")
                          : tr("开着才能在 Claude 打开时自动出现", "Lets the pet appear when Claude opens"),
                      isOn: Binding(get: { settings.launchAtLogin }, set: { settings.launchAtLogin = $0 }))
            if settings.launchAtLoginNeedsApproval {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(tr("还要在「系统设置 → 通用 → 登录项」里允许 QuotaPet 才会生效",
                            "Allow QuotaPet in System Settings → General → Login Items to finish turning this on"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(tr("打开", "Open")) { SMAppService.openSystemSettingsLoginItems() }
                        .controlSize(.small)
                }
            } else if let error = settings.launchAtLoginError {
                // 只有不在「应用程序」文件夹里运行时，才建议挪过去（在那里也失败了，这句建议帮不上忙）
                Text(FirstLaunch.isInApplicationsFolder(Bundle.main.bundlePath)
                        ? tr("设置失败：\(error)", "Couldn't change this: \(error)")
                        : tr("设置失败：\(error)（把 App 放进「应用程序」文件夹后再试）",
                             "Couldn't change this: \(error) (move the app into the Applications folder and try again)"))
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var claude: some View {
        SettingsGroup(tr("宠物形象", "Pet")) {
            StylePicker(choices: PetStyle.claudeChoices, selection: $settings.petStyle)
        }

        SettingsGroup(tr("实时估算", "Live Estimate")) {
            SwitchRow(tr("用本机日志实时估算", "Estimate from local logs"),
                      subtitle: tr("两次官方读数之间，按 Claude Code 的用量推算（缓存读按半价算）",
                                   "Between official readings, estimate from Claude Code usage (cache reads count at half price)"),
                      isOn: $settings.liveEstimate)
            SwitchRow(tr("自动学习换算率", "Learn the rate automatically"),
                      subtitle: tr("每来一次官方读数就学一次，记录一直存在本机", "Learns from every official reading; records stay on this Mac"),
                      isOn: $settings.autoLearn)
                .disabled(!settings.liveEstimate)
            if settings.liveEstimate { ratesView }
            SwitchRow(tr("手动指定每周重置时间", "Set weekly reset time manually"),
                      subtitle: tr("推算不准时用，准确时间可以在 Claude 的设置页看到",
                                   "Use this if the estimate is off; Claude's settings page shows the exact time"),
                      isOn: weeklyOverrideBinding)
            if let anchor = settings.weeklyResetAnchor {
                DatePicker(tr("下次重置", "Next reset"), selection: Binding(get: { anchor }, set: { settings.weeklyResetAnchor = $0 }),
                           displayedComponents: [.date, .hourAndMinute])
                    .font(.system(size: 12))
            }
        }

        officialReading
    }

    /// 桌面端停止更新官方读数时的备用办法：让命令行发一个最小请求。默认开启
    @ViewBuilder private var officialReading: some View {
        if let status = cliProbeStatus {
            SettingsGroup(tr("官方读数", "Official Reading")) {
                officialGuide
                SwitchRow(tr("用 Claude 命令行补官方读数", "Fill in readings via the Claude command line"),
                          subtitle: tr("桌面端停更读数时的备用办法：用命令行自己的登录发一个最小请求，占一点额度",
                                       "A fallback for when the desktop app stops updating readings: the command line sends one tiny request with its own login, using a little quota"),
                          isOn: $settings.claudeCLIProbe)
                if settings.claudeCLIProbe {
                    Text(status.text(now: Date()))
                        .font(.system(size: 11))
                        .foregroundStyle(status.needsLogin || status == .notFound ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// 官方读数怎么更新：新版桌面端会停，用户得知道停了怎么办，也要有个一键绑定命令行的办法
    private var officialGuide: some View {
        let needsConnect = onConnectCLI != nil && (!settings.claudeCLIProbe || cliProbeStatus?.needsLogin == true)
        return VStack(alignment: .leading, spacing: 5) {
            Text(claudeReadingAt.map { tr("最近一次官方读数：\(Fmt.ago($0, now: Date()))", "Latest official reading: \(Fmt.ago($0, now: Date()))") }
                    ?? tr("还没有官方读数", "No official reading yet"))
                .font(.system(size: 11, weight: .semibold))
            Text(tr("读数停了？右键点一下菜单栏里的 Claude 图标，或重启桌面端。", "Readings stopped? Right-click Claude's menu bar icon, or restart the desktop app."))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if needsConnect {
                Text(tr("一劳永逸：登录一次命令行，之后读数自动补上。", "To fix it for good: sign in on the command line once, and readings fill in by themselves."))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(settings.claudeCLIProbe ? tr("登录 Claude 命令行", "Sign in to the Claude command line")
                                               : tr("开启并登录 Claude 命令行", "Turn on and sign in to the Claude command line")) {
                    onConnectCLI?()
                }
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder private var codex: some View {
        SettingsGroup("Codex") {
            SwitchRow(tr("显示 Codex 的额度", "Show Codex usage"),
                      subtitle: tr("关掉后，面板、菜单栏和提醒都只管 Claude", "When off, the popover, menu bar and alerts only cover Claude"),
                      isOn: $settings.showCodex)
        }

        SettingsGroup(tr("宠物形象", "Pet")) {
            StylePicker(choices: PetStyle.codexChoices, selection: $settings.codexPetStyle)
        }
        .disabled(!settings.showCodex)

        SettingsGroup(tr("数据从哪来", "Where the data comes from")) {
            Text(tr("Codex 每轮对话结束时，会把服务器给的已用百分比和重置时间记在 ~/.codex/sessions 的日志里。QuotaPet 只读这几个数字，不读登录凭据、不联网。网页和云端任务的用量，要等下次在这台 Mac 上用 Codex 时才会更新。",
                    "After every turn, Codex writes the usage percentage and reset time it got from the server to its logs in ~/.codex/sessions. QuotaPet reads only those numbers: no login credentials, no network. Usage from the web or cloud tasks shows up the next time you use Codex on this Mac."))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let at = codexReadingAt {
                Text(tr("最近一次读数：\(Fmt.ago(at, now: Date()))", "Last reading: \(Fmt.ago(at, now: Date()))"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 5 小时 每 1% ≈ $0.33 · 每周 每 1% ≈ $2.41，下面一行说明学了多少记录
    private var ratesView: some View {
        let starting = ClaudeRates.starting
        let session = estimation?.sessionUSDPerPercent ?? starting.usdPerSessionPercent
        let weekly = estimation?.weeklyUSDPerPercent ?? starting.usdPerWeeklyPercent
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 14) {
                Text(tr("5 小时：每 1% ≈ \(Fmt.usd(session))", "5-hour: 1% ≈ \(Fmt.usd(session))"))
                Text(tr("每周：每 1% ≈ \(Fmt.usd(weekly))", "Weekly: 1% ≈ \(Fmt.usd(weekly))"))
            }
            .font(.system(size: 12, weight: .medium))
            .monospacedDigit()
            Text(learningText)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(tr("在访达中查看记录", "Show records in Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([IntervalArchive.defaultURL])
            }
            .buttonStyle(.link)
            .font(.system(size: 11))
            .disabled(!FileManager.default.fileExists(atPath: IntervalArchive.defaultURL.path))
        }
        .padding(.leading, 2)
    }

    private var learningText: String {
        guard let estimation else { return tr("还没有数据", "No data yet") }
        let recorded = tr("已记录 \(estimation.recordedIntervals) 段（每段约 15 分钟）",
                          "\(plural(estimation.recordedIntervals, "interval")) recorded (about 15 min each).")
        guard settings.autoLearn else {
            return tr("自动学习已关闭，一直用起始值。", "Auto-learning is off, so the starting rate is used. ") + recorded
        }
        guard estimation.learnedIntervals > 0, let until = estimation.learnedUntil else {
            return tr("记录还不够，先用起始值（实测回归的结果）。",
                      "Not enough records yet, so the starting rate (from a measured regression) is used. ") + recorded
        }
        let learned = estimation.learnedIntervals, clock = Fmt.clock(until, now: Date())
        return tr("从 \(learned) 段有 Claude Code 用量的记录里学到，数据截至 \(clock)。",
                  "Learned from \(plural(learned, "interval")) with Claude Code usage, up to \(clock). ") + recorded
    }

    /// 系统设置 → 通知 → QuotaPet
    private func openNotificationSettings() {
        let id = Bundle.main.bundleIdentifier ?? "dev.quotapet.app"
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func thresholdBinding(_ threshold: Int) -> Binding<Bool> {
        Binding(get: { settings.thresholds.contains(threshold) },
                set: { on in
                    var set = Set(settings.thresholds)
                    if on { set.insert(threshold) } else { set.remove(threshold) }
                    settings.thresholds = set.sorted()
                })
    }

    private var weeklyOverrideBinding: Binding<Bool> {
        Binding(get: { settings.weeklyResetAnchor != nil },
                set: { on in
                    settings.weeklyResetAnchor = on ? (suggestedWeeklyReset ?? Date().addingTimeInterval(7 * 86400)) : nil
                })
    }
}

struct SettingsGroup<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) { content }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.045)))
        }
    }
}

/// 一组形象选项，一行放不下就换行
struct StylePicker: View {
    let choices: [PetStyle]
    @Binding var selection: PetStyle

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
            ForEach(choices) { style in
                StyleOption(style: style, isSelected: selection == style) { selection = style }
            }
        }
    }
}

/// 形象选项：半身像缩略图 + 名字，选中的描一圈强调色
struct StyleOption: View {
    let style: PetStyle
    let isSelected: Bool
    let action: () -> Void

    /// 半身像平滑缩到 48pt
    private static let thumbnails = Dictionary(uniqueKeysWithValues: PetStyle.allCases.map {
        ($0, PetRenderer.image(PetSprites.frames(for: .normal, style: $0)[0].portrait))
    })

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(nsImage: Self.thumbnails[style] ?? NSImage())
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 48, height: 48)
                    .accessibilityHidden(true)
                Text(style.label).font(.system(size: 11))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(style.label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct SwitchRow: View {
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool

    init(_ title: String, subtitle: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.subtitle = subtitle
        _isOn = isOn
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
    }
}
