import Combine
import Foundation
import ServiceManagement
import QuotaPetCore

/// 用户设置，存在 UserDefaults 里
@MainActor
final class AppSettings: ObservableObject {
    private let defaults: UserDefaults
    let allowsSystemActions: Bool

    @Published var menuBarText: MenuBarTextMode {
        didSet { defaults.set(menuBarText.rawValue, forKey: Keys.menuBarText) }
    }
    /// 什么时候出现在菜单栏：Claude 打开时 / 一直
    @Published var visibility: MenuBarVisibility {
        didSet { defaults.set(visibility.rawValue, forKey: Keys.visibility) }
    }
    /// Claude 的宠物形象
    @Published var petStyle: PetStyle {
        didSet { defaults.set(petStyle.rawValue, forKey: Keys.petStyle) }
    }
    /// 正常模式的静态宠物：独立保存，允许 Claude 和 Codex 的全部形象。
    @Published var officialPetChoice: OfficialPetChoice {
        didSet { defaults.set(officialPetChoice.rawValue, forKey: Keys.officialPetStyle) }
    }
    /// Preserve the last ordinary style when visiting the agy official entry.
    private var officialClaudePetStyle: PetStyle {
        didSet { defaults.set(officialClaudePetStyle.rawValue, forKey: Keys.officialClaudePetStyle) }
    }

    private var officialCodexPetStyle: PetStyle {
        didSet { defaults.set(officialCodexPetStyle.rawValue, forKey: Keys.officialCodexPetStyle) }
    }

    private var officialAntigravityPetChoice: OfficialPetChoice {
        didSet { defaults.set(officialAntigravityPetChoice.rawValue, forKey: Keys.officialAntigravityPetChoice) }
    }

    /// 现在跟着哪家，以及每家记住的形象
    var officialSelection: OfficialPetSelection {
        OfficialPetSelection(choice: officialPetChoice, claudeStyle: officialClaudePetStyle, codexStyle: officialCodexPetStyle,
                             antigravityChoice: officialAntigravityPetChoice)
    }

    func selectOfficialPet(_ choice: OfficialPetChoice) {
        var selection = officialSelection
        selection.select(choice)
        saveOfficialSelection(selection)
    }

    func selectOfficialEntry(_ entry: OfficialQuotaEntry) {
        var selection = officialSelection
        selection.select(entry: entry)
        saveOfficialSelection(selection)
    }

    private func saveOfficialSelection(_ selection: OfficialPetSelection) {
        officialClaudePetStyle = selection.claudeStyle
        officialCodexPetStyle = selection.codexStyle
        officialAntigravityPetChoice = selection.antigravityChoice
        officialPetChoice = selection.choice
    }

    /// Codex 的宠物形象（和 Claude 各选各的，见 PetStyle.codexChoices）
    @Published var codexPetStyle: PetStyle {
        didSet { defaults.set(codexPetStyle.rawValue, forKey: Keys.codexPetStyle) }
    }
    /// 本机有 Codex 的记录时，在面板、菜单栏上显示它、给它发提醒
    @Published var showCodex: Bool {
        didSet { defaults.set(showCodex, forKey: Keys.showCodex) }
    }
    /// 菜单栏和面板自动跟随正在用的那家（ActiveService）
    @Published var autoFollowActive: Bool {
        didSet { defaults.set(autoFollowActive, forKey: Keys.autoFollowActive) }
    }
    @Published var animatePet: Bool {
        didSet { defaults.set(animatePet, forKey: Keys.animatePet) }
    }
    @Published var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Keys.notificationsEnabled) }
    }
    /// 用量提醒的阈值（百分比）
    @Published var thresholds: [Int] {
        didSet { defaults.set(thresholds, forKey: Keys.thresholds) }
    }
    /// 照最近的速度快用完时提前提醒（见 UsageWindow.warningLead）
    @Published var notifyRunningOut: Bool {
        didSet { defaults.set(notifyRunningOut, forKey: Keys.notifyRunningOut) }
    }
    @Published var notifyOnReset: Bool {
        didSet { defaults.set(notifyOnReset, forKey: Keys.notifyOnReset) }
    }
    /// 用本机 Claude Code 日志估算两次官方读数之间的用量
    @Published var liveEstimate: Bool {
        didSet { defaults.set(liveEstimate, forKey: Keys.liveEstimate) }
    }
    /// 从持续记录的区间里自动学习换算率
    @Published var autoLearn: Bool {
        didSet { defaults.set(autoLearn, forKey: Keys.autoLearn) }
    }
    /// 用 Claude 官方命令行补官方读数（联网：命令行发一个最小请求）。默认开启（设置里可关），见 CLIProbe
    @Published var claudeCLIProbe: Bool {
        didSet { defaults.set(claudeCLIProbe, forKey: Keys.claudeCLIProbe) }
    }
    /// 手动指定的每周重置时间；nil = 自动推算
    @Published var weeklyResetAnchor: Date? {
        didSet { defaults.set(weeklyResetAnchor, forKey: Keys.weeklyResetAnchor) }
    }
    /// 界面语言；nil = 跟随系统
    @Published var language: Language? {
        // 在 willSet 里切换：@Published 赋值时就会通知订阅者（早于 didSet），它们要读到新语言
        willSet { L10n.language = newValue ?? .preferred() }
        didSet { defaults.set(language?.rawValue, forKey: Keys.language) }
    }
    /// 开机自启设置失败时系统给的原因（界面上再套一句提示，跟着界面语言走）
    @Published private(set) var launchAtLoginError: String?
    /// 打开了开机自启，但要用户在「系统设置 → 通用 → 登录项」里允许（以前在那里关掉过）。已经帮用户打开了那一页
    var launchAtLoginNeedsApproval: Bool { allowsSystemActions && SMAppService.mainApp.status == .requiresApproval }
    var desktopAutoLaunchNeedsApproval: Bool { allowsSystemActions && desktopService.status == .requiresApproval }
    /// 系统设置里没允许 QuotaPet 发通知（NotificationManager 更新，不存）：提醒开着也弹不出来，设置页要说一声
    @Published var notificationsDenied = false

    /// defaults：渲染预览图时用临时的一份，不动本机真实的设置
    init(defaults: UserDefaults = .standard, allowsSystemActions: Bool = true) {
        self.defaults = defaults
        self.allowsSystemActions = allowsSystemActions
        defaults.register(defaults: [
            Keys.animatePet: true,
            Keys.autoFollowActive: true,
            Keys.notificationsEnabled: true,
            Keys.thresholds: [75, 90, 100],
            Keys.notifyRunningOut: true,
            Keys.notifyOnReset: true,
            Keys.liveEstimate: true,
            Keys.autoLearn: true,
            Keys.showCodex: true,
        ])
        menuBarText = MenuBarTextMode(rawValue: defaults.string(forKey: Keys.menuBarText) ?? "") ?? .session
        visibility = MenuBarVisibility(rawValue: defaults.string(forKey: Keys.visibility) ?? "") ?? .withClaude
        // 存的形象不在这家的那一组里（比如以前的版本存的）就用那组的第一款
        petStyle = PetStyle(rawValue: defaults.string(forKey: Keys.petStyle) ?? "").flatMap { PetStyle.claudeChoices.contains($0) ? $0 : nil }
            ?? PetStyle.claudeChoices[0]
        let initialOfficialPet = OfficialPetChoice(rawValue: defaults.string(forKey: Keys.officialPetStyle) ?? "")
            ?? OfficialPetChoice(rawValue: defaults.string(forKey: Keys.petStyle) ?? "")
            ?? OfficialPetChoice(rawValue: PetStyle.classic.rawValue)!
        officialPetChoice = initialOfficialPet
        let initialOfficialSelection = OfficialPetSelection(choice: initialOfficialPet,
            claudeStyle: PetStyle(rawValue: defaults.string(forKey: Keys.officialClaudePetStyle) ?? "")
                ?? PetStyle(rawValue: defaults.string(forKey: Keys.petStyle) ?? "") ?? .classic,
            codexStyle: PetStyle(rawValue: defaults.string(forKey: Keys.officialCodexPetStyle) ?? "")
                ?? PetStyle(rawValue: defaults.string(forKey: Keys.codexPetStyle) ?? "") ?? .dragon,
            antigravityChoice: OfficialPetChoice(rawValue: defaults.string(forKey: Keys.officialAntigravityPetChoice) ?? "") ?? .antigravity)
        officialClaudePetStyle = initialOfficialSelection.claudeStyle
        officialCodexPetStyle = initialOfficialSelection.codexStyle
        officialAntigravityPetChoice = initialOfficialSelection.antigravityChoice
        codexPetStyle = PetStyle(rawValue: defaults.string(forKey: Keys.codexPetStyle) ?? "")
            .flatMap { PetStyle.codexChoices.contains($0) ? $0 : nil } ?? PetStyle.codexChoices[0]
        showCodex = defaults.bool(forKey: Keys.showCodex)
        animatePet = defaults.bool(forKey: Keys.animatePet)
        autoFollowActive = defaults.bool(forKey: Keys.autoFollowActive)
        notificationsEnabled = defaults.bool(forKey: Keys.notificationsEnabled)
        thresholds = (defaults.array(forKey: Keys.thresholds) as? [Int]) ?? [75, 90, 100]
        notifyRunningOut = defaults.bool(forKey: Keys.notifyRunningOut)
        notifyOnReset = defaults.bool(forKey: Keys.notifyOnReset)
        liveEstimate = defaults.bool(forKey: Keys.liveEstimate)
        autoLearn = defaults.bool(forKey: Keys.autoLearn)
        weeklyResetAnchor = defaults.object(forKey: Keys.weeklyResetAnchor) as? Date
        claudeCLIProbe = defaults.object(forKey: Keys.claudeCLIProbe) as? Bool ?? true
        language = Language(rawValue: defaults.string(forKey: Keys.language) ?? "")
        L10n.language = language ?? .preferred()  // init 里不会触发 willSet
    }

    /// 用户在设置里关掉、不在面板和菜单栏上显示的几家
    var hiddenProviders: Set<ProviderID> { Self.hiddenProviders(showCodex: showCodex) }

    nonisolated static func hiddenProviders(showCodex: Bool) -> Set<ProviderID> { showCodex ? [] : [.codex] }

    var providerConfig: ClaudeProvider.Config {
        Self.providerConfig(liveEstimate: liveEstimate, autoLearn: autoLearn, weeklyResetAnchor: weeklyResetAnchor,
                            useCLIReadings: claudeCLIProbe)
    }

    nonisolated static func providerConfig(liveEstimate: Bool, autoLearn: Bool, weeklyResetAnchor: Date?,
                                           useCLIReadings: Bool) -> ClaudeProvider.Config {
        var config = ClaudeProvider.Config()
        config.liveEstimate = liveEstimate
        config.autoLearn = autoLearn
        config.weeklyResetAnchor = weeklyResetAnchor
        config.useCLIReadings = useCLIReadings
        return config
    }

    /// 开机自启（SMAppService，macOS 13+）。设置页的开关用它：是用户自己开关的
    var launchAtLogin: Bool {
        get { allowsSystemActions && (SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval) }
        set { setLaunchAtLogin(newValue, byUser: true) }
    }

    /// 开关开机自启。开关成功过一次就不再替用户自动打开（FirstLaunch.loginItemPendingKey，规则见 clearsLoginItemPending）。
    /// byUser：用户在设置里点的。要在系统设置里允许时，只有用户自己点的才帮他打开「登录项」那一页
    func setLaunchAtLogin(_ on: Bool, byUser: Bool) {
        guard allowsSystemActions else { return }
        objectWillChange.send()
        let service = SMAppService.mainApp
        var succeeded = true
        do {
            if on {
                try service.register()
            } else {
                try service.unregister()
            }
            launchAtLoginError = nil
        } catch {
            succeeded = false
            launchAtLoginError = error.localizedDescription
        }
        // 注册上了，只是用户以前在系统设置里关掉过：报错没用，要去「登录项」里允许
        if on && launchAtLoginNeedsApproval {
            succeeded = true
            launchAtLoginError = nil
            if byUser { SMAppService.openSystemSettingsLoginItems() }
        }
        if LaunchModeTransition.shouldDisablePrevious(enabling: on, succeeded: succeeded,
                                                       active: service.status == .enabled,
                                                       needsApproval: launchAtLoginNeedsApproval) {
            do {
                if desktopService.status == .enabled || desktopService.status == .requiresApproval {
                    try desktopService.unregister()
                }
                defaults.set(false, forKey: "desktopAutoLaunchEnabled")
                defaults.synchronize()
                desktopAutoLaunchError = nil
            } catch {
                launchAtLoginError = tr("主程序登录启动已开启，但关闭桌面助手失败：\(error.localizedDescription)",
                                        "Main app login launch is on, but the desktop helper could not be disabled: \(error.localizedDescription)")
            }
        }
        if FirstLaunch.clearsLoginItemPending(enabling: on, succeeded: succeeded, bundlePath: Bundle.main.bundlePath) {
            defaults.removeObject(forKey: FirstLaunch.loginItemPendingKey)
        }
    }

    private var desktopService: SMAppService { .agent(plistName: "dev.quotapet.launcher.plist") }
    @Published private(set) var desktopAutoLaunchError: String?
    var desktopAutoLaunch: Bool {
        get { allowsSystemActions && defaults.bool(forKey: "desktopAutoLaunchEnabled") && (desktopService.status == .enabled || desktopService.status == .requiresApproval) }
        set {
            guard allowsSystemActions else { return }
            objectWillChange.send()
            do {
                if newValue { try desktopService.register() } else { try desktopService.unregister() }
                defaults.set(newValue, forKey: "desktopAutoLaunchEnabled")
                defaults.set(false, forKey: "desktopAutoLaunchPaused")
                defaults.synchronize()
                desktopAutoLaunchError = desktopService.status == .requiresApproval
                    ? tr("请在系统设置的登录项中允许后台助手", "Allow the background helper in System Settings → Login Items") : nil
                if LaunchModeTransition.shouldDisablePrevious(enabling: newValue, succeeded: true,
                                                               active: desktopService.status == .enabled,
                                                               needsApproval: desktopAutoLaunchNeedsApproval) {
                    do {
                        let previous = SMAppService.mainApp
                        if previous.status == .enabled || previous.status == .requiresApproval {
                            try previous.unregister()
                        }
                        launchAtLoginError = nil
                    } catch {
                        desktopAutoLaunchError = tr("桌面助手已开启，但关闭主程序登录启动失败：\(error.localizedDescription)",
                                                    "Desktop helper is on, but main app login launch could not be disabled: \(error.localizedDescription)")
                    }
                }

            } catch { desktopAutoLaunchError = error.localizedDescription }
        }
    }
    func pauseDesktopAutoLaunch() {
        defaults.set(true, forKey: "desktopAutoLaunchPaused")
        defaults.synchronize()
    }
    func resumeDesktopAutoLaunch() {
        defaults.set(false, forKey: "desktopAutoLaunchPaused")
        defaults.synchronize()
    }

    private enum Keys {
        static let menuBarText = "menuBarText"
        static let visibility = "visibility"
        static let petStyle = "petStyle"
        static let officialPetStyle = "officialPetStyle"
        static let officialClaudePetStyle = "officialClaudePetStyle"
        static let officialCodexPetStyle = "officialCodexPetStyle"
        static let officialAntigravityPetChoice = "officialAntigravityPetChoice"
        static let codexPetStyle = "codexPetStyle"
        static let showCodex = "showCodex"
        static let animatePet = "animatePet"
        static let autoFollowActive = "autoFollowActive"
        static let notificationsEnabled = "notificationsEnabled"
        static let thresholds = "thresholds"
        static let notifyRunningOut = "notifyRunningOut"
        static let notifyOnReset = "notifyOnReset"
        static let liveEstimate = "liveEstimate"
        static let autoLearn = "autoLearn"
        static let weeklyResetAnchor = "weeklyResetAnchor"
        static let claudeCLIProbe = "claudeCLIProbe"
        static let language = "language"
    }
}
