import ServiceManagement
import SwiftUI
import QuotaPetCore

/// 正常模式的设置页（面板里点齿轮翻过来）：沿用旧设置页的分组卡片、缩略图形象选择和开关行。
/// 只放正常模式真正起作用的设置：宠物形象、菜单栏、启动方式、语言。
struct OfficialSettingsView: View {
    @ObservedObject var settings: AppSettings
    var artwork: (OfficialPetChoice, PetMood) -> NSImage
    var onShellSetup: () -> Void = {}
    var onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button(action: onBack) {
                    Label(tr("返回", "Back"), systemImage: "chevron.left").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)
                Spacer()
                Text(tr("设置", "Settings")).font(.system(size: 14, weight: .semibold))
                Spacer()
                Color.clear.frame(width: 44, height: 1)  // 让标题居中
            }

            SettingsGroup(tr("宠物形象", "Pet")) {
                Text(tr("点一个形象，宠物和菜单栏就跟着那一家；每家记得自己选过的形象。",
                        "Pick a pet to follow that service in the panel and menu bar. Each service remembers its own pet."))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                let selection = settings.officialSelection
                petRow("Claude", choices: PetStyle.claudeChoices.map { OfficialPetChoice(rawValue: $0.rawValue)! },
                       remembered: OfficialPetChoice(rawValue: selection.claudeStyle.rawValue)!)
                petRow("Codex", choices: PetStyle.codexChoices.map { OfficialPetChoice(rawValue: $0.rawValue)! },
                       remembered: OfficialPetChoice(rawValue: selection.codexStyle.rawValue)!)
                petRow("agy", choices: OfficialPetChoice.antigravityChoices, remembered: selection.antigravityChoice)
            }

            SettingsGroup(tr("菜单栏", "Menu Bar")) {
                SwitchRow(tr("自动跟随正在用的那家", "Follow the service in use"),
                          subtitle: tr("Claude Code、Codex 或 agy 一有动静，菜单栏和面板就切到那家；几家同时在用时显示用得最紧的。手动选了之后 10 分钟内不自动切换。",
                                       "When Claude Code, Codex or agy is active, the menu bar and panel switch to it; with several in use, the most constrained one is shown. A manual choice holds for 10 minutes."),
                          isOn: $settings.autoFollowActive)
                VStack(alignment: .leading, spacing: 5) {
                    Text(tr("宠物旁边显示", "Next to the pet")).font(.system(size: 12))
                    Picker(tr("宠物旁边显示", "Next to the pet"), selection: $settings.menuBarText) {
                        ForEach(MenuBarTextMode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text(tr("只显示官方读数；没有可靠读数时只显示宠物。agy 只有「最紧张」一种数字。",
                            "Official readings only; without a reliable reading only the pet shows. agy always shows its tightest window."))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            SettingsGroup(tr("启动方式", "Startup")) {
                SwitchRow(tr("随 Claude 或 Codex 桌面端启动", "Start with Claude or Codex desktop"),
                          subtitle: tr("轻量后台助手只等 macOS 的应用启动事件；手动退出后暂停，重新打开恢复。",
                                       "A lightweight helper waits for macOS app-launch events. Quitting pauses it until you reopen QuotaPet."),
                          isOn: Binding(get: { settings.desktopAutoLaunch || settings.desktopAutoLaunchNeedsApproval },
                                        set: { settings.desktopAutoLaunch = $0 }))
                    .disabled(!settings.allowsSystemActions)
                if let error = settings.desktopAutoLaunchError {
                    Text(error).font(.system(size: 10.5)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                SwitchRow(tr("登录时启动 QuotaPet", "Open QuotaPet at login"),
                          isOn: Binding(get: { settings.launchAtLogin }, set: { settings.launchAtLogin = $0 }))
                    .disabled(!settings.allowsSystemActions)
                if let error = settings.launchAtLoginError {
                    Text(error).font(.system(size: 10.5)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                if settings.desktopAutoLaunchNeedsApproval || settings.launchAtLoginNeedsApproval {
                    Button(tr("前往系统设置允许登录项…", "Allow login items in System Settings…")) {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                }
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tr("随终端命令启动", "Start with terminal commands")).font(.system(size: 12))
                        Text(tr("运行 claude 或 codex 时带起宠物", "Bring up the pet when you run claude or codex"))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button(tr("设置…", "Set Up…"), action: onShellSetup)
                        .controlSize(.small)
                }
            }

            SettingsGroup(tr("语言", "Language")) {
                Picker(tr("语言", "Language"), selection: $settings.language) {
                    Text(tr("跟随系统", "System")).tag(Language?.none)
                    ForEach(Language.allCases) { Text($0.nativeName).tag(Language?.some($0)) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Text(tr("数据只来自官方读数：Claude Code CLI 和 agy CLI 的 /usage（由官方 CLI 自己联网），以及 Codex 日志里服务器给的读数。QuotaPet 自己不联网，不读登录凭据和对话内容。",
                    "Data comes only from official readings: the Claude Code and agy CLIs’ /usage (the official CLIs do the network calls) and the readings Codex logs from its server. QuotaPet itself makes no network calls and reads no credentials or conversation content."))
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
    }

    /// 一家的形象：小标题 + 缩略图网格。跟着的那家标一个小爪印
    private func petRow(_ name: String, choices: [OfficialPetChoice], remembered: OfficialPetChoice) -> some View {
        let following = settings.officialPetChoice.entry == remembered.entry
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(name).font(.system(size: 12, weight: .medium))
                if following {
                    Image(systemName: "pawprint.fill").font(.system(size: 9)).foregroundStyle(.secondary)
                        .help(tr("宠物现在跟着这家", "The pet is following this service"))
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 66), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(choices, id: \.rawValue) { choice in
                    OfficialPetOption(label: choice.label, image: artwork(choice, .normal),
                                      isSelected: choice == remembered, isFollowed: following && choice == settings.officialPetChoice) {
                        settings.selectOfficialPet(choice)
                    }
                }
            }
        }
    }
}

/// 形象选项：半身像缩略图 + 名字。这家记住的那款描一圈；宠物正跟着的那款填满强调色
struct OfficialPetOption: View {
    let label: String
    let image: NSImage
    let isSelected: Bool
    let isFollowed: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityHidden(true)
                Text(label)
                    .font(.system(size: 10.5))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isFollowed ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
