import AppKit
import ServiceManagement
import Combine
import CryptoKit
import SwiftUI
import QuotaPetCore

/// 正常模式的菜单栏宠物：左键弹出额度面板（旧版布局），右键 / Control-点按弹出操作菜单。
/// 数据只来自官方读数：agy 和 Claude 读各自官方 CLI 的 /usage，Codex 读日志里服务器给的 rate_limits。
@MainActor
final class OfficialPanelState: ObservableObject {
    enum Page { case overview, settings }
    @Published var page: Page = .overview
    /// Claude / Codex 的官方读数快照
    @Published var usage: [UsageSnapshot] = []
    @Published var reading: AgyQuotaReading?
    @Published var agyHistory: [AgyQuotaReading] = []
    /// 正在用官方 CLI 读 Claude
    @Published var claudeQuerying = false
    /// 正在用的几家（ActiveService.window 内有动静），切换条上的小圆点带光晕
    @Published var activeEntries: Set<OfficialQuotaEntry> = []
    @Published var querying = false
    @Published var agyStatus = ""
    @Published var runningApps: Set<String> = []
    @Published var maxHeight: CGFloat = .infinity
    /// 点了刷新、还没读完的几家：只有它们的刷新按钮转圈（后台自动读取不转）
    @Published var manualRefreshing: Set<OfficialQuotaEntry> = []
    /// 点了刷新后在页脚停几秒的结果提示
    @Published var refreshNotice: RefreshNotice?
    /// 戳宠物的台词和连戳次数；从随机的一句开始
    var chat = PetChat(pick: .random(in: 0..<6))
}

/// 面板根视图：设置和读数一变，原地重画（不重建窗口，焦点和当前页都留着）
struct OfficialPanelRoot: View {
    @ObservedObject var state: OfficialPanelState
    @ObservedObject var settings: AppSettings
    var artwork: (OfficialPetChoice, PetMood) -> NSImage
    var pokeArtwork: (OfficialPetChoice, Bool) -> NSImage?
    var canOpenAntigravity: Bool
    var onSelect: (OfficialQuotaEntry) -> Void
    var onOpenOfficial: (OfficialQuotaEntry) -> Void
    var onOpenAntigravity: () -> Void
    var onShellSetup: () -> Void
    var onRefresh: (OfficialQuotaEntry) -> Void
    /// 页面的自然高度变了（换页签、换页面、读数更新）：外面平滑地把窗口调到这个高度
    var onHeight: (CGFloat) -> Void
    var onQuit: () -> Void

    var body: some View {
        let entry = settings.officialPetChoice.entry
        let desktopID = entry == .claude ? AppWatcher.claudeBundleID : AppWatcher.codexBundleID
        Group {
            switch state.page {
            case .overview:
                OfficialOverviewView(entry: entry, choice: settings.officialPetChoice, artwork: artwork,
                                     reading: state.reading, agyHistory: state.agyHistory,
                                     querying: state.querying, agyStatus: state.agyStatus,
                                     usage: state.usage, activeEntries: state.activeEntries,
                                     desktopRunning: state.runningApps.contains(desktopID),
                                     canOpenAntigravity: canOpenAntigravity,
                                     onSelect: onSelect, onOpenOfficial: onOpenOfficial, onOpenAntigravity: onOpenAntigravity,
                                     refreshing: entry == .claude ? state.claudeQuerying : entry == .antigravity ? state.querying : false,
                                     manualRefreshing: state.manualRefreshing.contains(entry),
                                     onRefresh: { onRefresh(entry) },
                                     refreshNotice: state.refreshNotice,
                                     onMenu: { state.page = .settings }, onQuit: onQuit,
                                     pokeArtwork: pokeArtwork,
                                     onPoke: { mood in state.chat.poke(mood: mood, now: Date()) },
                                     pinFooter: true, onHeight: onHeight)
            case .settings:
                ScrollView {
                    OfficialSettingsView(settings: settings, artwork: artwork, onShellSetup: onShellSetup,
                                         onBack: { state.page = .overview })
                        .background(GeometryReader { Color.clear.preference(key: PanelHeightKey.self, value: $0.size.height) })
                }
                .scrollBounceBehavior(.basedOnSize)
                .onPreferenceChange(PanelHeightKey.self) { onHeight($0) }
            }
        }
        .frame(width: 340)
        .frame(maxHeight: .infinity, alignment: .top)
        .id(settings.language)  // 换语言时整个面板重建
    }
}

@MainActor
final class OfficialMenuController: NSObject, NSMenuDelegate, NSPopoverDelegate, NSWindowDelegate {
    private let item = StatusItemPlacement.makeItem(length: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let popover = NSPopover()
    /// 图标被刘海或其他图标挤掉时，再次打开 App 用它在当前屏幕显示同一个面板
    private var floatingPanel: NSPanel?
    private let state = OfficialPanelState()
    private let settings: AppSettings
    private let agyMonitor: AgyQuotaMonitor
    /// Claude 的官方读数：选中 Claude 时用官方 Claude Code CLI 的交互式 /usage（安全模式、不给工具）
    private let claudeMonitor: ClaudeQuotaMonitor
    /// Codex 的官方读数：只读日志里服务器给的 rate_limits，不估算
    private let usageStore: UsageStore?
    /// Claude Code / agy 有没有在干活：只看对话目录的文件事件，不读内容。用来干完活后自动重读额度、跟随正在用的那家
    /// Claude 不算 QuotaPet 自己查额度用的专用目录（按完整的文件夹名，ClaudeQuotaProbe 用的同一个目录）
    private lazy var claudeActivity = ActivityWatch(source: .claude(
        home: FileManager.default.homeDirectoryForCurrentUser,
        ownFolders: { (check: URL) in [check, check.resolvingSymlinksInPath()].map(ClaudeCLILocator.sessionFolderName(for:)) }(
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/QuotaPet/ClaudeQuotaCheck", isDirectory: true))))
    /// agy 只认两个 conversations 目录里的真实写入；插件、缓存这类维护写入不算
    private lazy var agyActivity = ActivityWatch(source: .agy(home: FileManager.default.homeDirectoryForCurrentUser))
    /// 每家最近一次有动静的时间；手动选过哪家的时间；正在自动切换（不算手动）
    private var lastActive: [OfficialQuotaEntry: Date] = [:]
    /// 每家最近一次「主动开始」的时间（Codex 新一轮开始、Claude 提交提示词、新建会话）：接着写的后台活动抢不走它
    private var lastStart: [OfficialQuotaEntry: Date] = [:]
    /// QuotaPet 自己查 Claude 额度的时段（判 history.jsonl 的写入是不是自己的）：启动时固定下来的上一次运行的那次单独留着，
    /// 不进本次运行的滚动列表（挂着的离线候选可能很晚才放出，那时仍要对照得到它）；本次运行最近 8 次另记。
    /// 固定下来而不是每次判断时再读设置：本次第一次查询结束会覆盖设置里的那一条
    private var previousRunClaudeQuery: (started: Date, ended: Date)?
    private var ownClaudeQueries: [(started: Date, ended: Date)] = []
    /// 手动选择的时刻（单调时钟：开机以来的秒数，改系统时间不影响十分钟保护）
    private var manualAt: TimeInterval?
    private var autoSwitching = false
    private var subscriptions: Set<AnyCancellable> = []
    private var menuTracking = false
    private var revealPending = false
    private let antigravityURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.antigravity")

    init(settings: AppSettings) {
        self.settings = settings
        self.agyMonitor = AgyQuotaMonitor(enabled: settings.allowsSystemActions)
        self.claudeMonitor = ClaudeQuotaMonitor(enabled: settings.allowsSystemActions, cacheKey: "lastClaudeUsageReading",
                                                probe: { await ClaudeQuotaProbe().read() },
                                                nextChange: { reading, now in reading?.nextChange(after: now) })
        self.usageStore = settings.allowsSystemActions
            ? UsageStore(providers: [CodexProvider(rejected: settings.codexRejectedRecords())], settings: settings) : nil
        super.init()
        if let button = item.button {
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageOnly
        }
        menu.delegate = self
        configurePopover()
        agyMonitor.onChange = { [weak self] in self?.updateReading() }
        claudeMonitor.onChange = { [weak self] in self?.claudeQueryChanged() }
        captureLaunchState()
        // 三家一直保持读数：切换页签只换显示，不清空、不重读（打开面板就能看到三家已有的数据）
        agyMonitor.select(true)
        claudeMonitor.select(true)
        updateReading()
        settings.$officialPetChoice.dropFirst().sink { [weak self] _ in
            // 不是自动跟随切过去的，就是用户自己选的：之后 10 分钟内不自动切走
            if self?.autoSwitching == false { self?.manualAt = ProcessInfo.processInfo.systemUptime }
            DispatchQueue.main.async { self?.updateImage() }
        }.store(in: &subscriptions)
        // 重启前每家最近一次「主动开始」：已经跑了很久的长任务重启后仍是「用户最近主动开始的那家」，别家的后台写入抢不走。
        // 只恢复开始时间，不恢复「在用」：还在不在用照样看现在的动静
        lastStart = settings.followStarts(now: Date())
        settings.$menuBarText.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.updateImage() }
            .store(in: &subscriptions)
        // 重新打开自动跟随：马上按现在谁在用判断一次，不等下一次动静（@Published 赋值前就通知，等新值落定）
        settings.$autoFollowActive.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.followActive() }
        }.store(in: &subscriptions)
        settings.$language.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.updateReading() }
            .store(in: &subscriptions)
        usageStore?.$snapshots.receive(on: RunLoop.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateUsage() }  // @Published 在赋值之前就通知：等新值落定再读
        }.store(in: &subscriptions)
        // 每分钟兜底一次：读数过期、重置时间到了，面板和菜单栏要跟着变
        usageStore?.$tick.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            if self?.settings.allowsSystemActions == true { self?.watchActivity() }  // 目录启动时还不存在的话，之后补上
            self?.updateUsage()  // 里面会重新判断自动跟随
        }
            .store(in: &subscriptions)
        usageStore?.start()
        if settings.allowsSystemActions {
            claudeActivity.onActivity = { [weak self] time in self?.noteActive(.claude, at: time) }
            claudeActivity.refresh = { [weak self] in self?.claudeMonitor.refreshForActivity() }
            claudeActivity.latestReadingAt = { [weak self] in self?.claudeMonitor.history.last?.checkedAt }
            claudeActivity.querying = { [weak self] in self?.claudeMonitor.querying ?? false }
            claudeActivity.onStart = { [weak self] time in self?.noteStart(.claude, at: time) }
            // QuotaPet 自己用 Claude Code CLI 读 /usage 时，CLI 也可能往 history.jsonl 记一笔：
            // 只把写入时间落在这次查询进程运行期间的算自己的；查询还没结束时先挂起，结束后再判，不丢用户真实的提示词
            claudeActivity.startVerdict = { [weak self] time in
                guard let self else { return .user }
                // 当前这次查询，再对照更早的几次（含启动时固定下来的上一次运行的那次：重启后补扫会看到它留下的写入）
                return StartVerdict.judge(time, querying: self.claudeMonitor.querying, started: self.claudeMonitor.lastQueryStarted,
                                          ended: self.claudeMonitor.lastQueryEnded,
                                          earlier: (self.previousRunClaudeQuery.map { [$0] } ?? []) + self.ownClaudeQueries)
            }
            agyActivity.onActivity = { [weak self] time in self?.noteActive(.antigravity, at: time) }
            agyActivity.refresh = { [weak self] in self?.agyMonitor.refreshForActivity() }
            agyActivity.latestReadingAt = { [weak self] in self?.agyMonitor.history.last?.checkedAt }
            agyActivity.querying = { [weak self] in self?.agyMonitor.querying ?? false }
            // agy 查额度时 CLI 不往 conversations 里写（运行中的 App 多次查询前后，那里的修改时间都没变），不用屏蔽
            agyActivity.onStart = { [weak self] time in self?.noteStart(.antigravity, at: time) }
            watchActivity()
        }
        NSWorkspace.shared.publisher(for: \.runningApplications).receive(on: RunLoop.main).sink { [weak self] apps in
            self?.state.runningApps = Set(apps.filter { !$0.isTerminated }.compactMap(\.bundleIdentifier))
        }.store(in: &subscriptions)
    }

    /// 再次打开正在运行的 App（访达、Spotlight）：图标看得到就在它下面弹面板，
    /// 被刘海或别的图标挤掉、或者在另一块屏幕上时，在鼠标所在的屏幕上浮出同一个面板
    func reveal() {
        if !item.isVisible {
            StatusItemPlacement.restore()
            item.isVisible = true
        }
        guard !menuTracking, !revealPending else { return }
        revealPending = true
        // 图标刚出现时位置还没排好，等一下再弹
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                defer { self.revealPending = false }
                guard !self.menuTracking, !self.popover.isShown else { return }
                if self.buttonIsOnScreen { self.showPopover() } else { self.showFloatingPanel() }
            }
        }
    }

    /// 图标真的显示在鼠标所在屏幕的菜单栏上
    private var buttonIsOnScreen: Bool {
        guard let window = item.button?.window, window.occlusionState.contains(.visible),
              let screen = window.screen else { return false }
        let mouse = NSEvent.mouseLocation
        guard screen.frame.contains(mouse) else { return false }
        let frame = window.frame
        return frame.width > 0 && screen.frame.insetBy(dx: -1, dy: -1).contains(frame)
    }

    // MARK: - 点击

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showMenu() {
        if popover.isShown { popover.performClose(nil) }
        floatingPanel?.orderOut(nil)
        rebuild()
        item.menu = menu
        item.button?.performClick(nil)  // 弹出菜单，关掉后才返回
        item.menu = nil
    }

    private func makeRoot() -> OfficialPanelRoot {
        OfficialPanelRoot(state: state, settings: settings,
                          artwork: { [weak self] choice, mood in
                              self?.artwork(file: choice.file(mood: mood, panel: true), points: 96) ?? NSImage()
                          },
                          pokeArtwork: { [weak self] choice, annoyed in
                              guard let self, let file = choice.pokeFile(annoyed: annoyed, panel: true), Self.artExists(file) else { return nil }
                              return self.artwork(file: file, points: 96)
                          },
                          canOpenAntigravity: antigravityURL != nil,
                          onSelect: { [weak self] entry in self?.settings.selectOfficialEntry(entry) },
                          onOpenOfficial: { [weak self] entry in self?.open(entry.url) },
                          onOpenAntigravity: { [weak self] in self?.launchAntigravity() },
                          onShellSetup: { [weak self] in self?.shellSetup() },
                          onRefresh: { [weak self] entry in self?.refresh(entry) },
                          onHeight: { [weak self] height in self?.setPanelHeight(height) },
                          onQuit: { [weak self] in self?.quit() })
    }

    private func configurePopover() {
        let host = NSHostingController(rootView: makeRoot())
        host.sizingOptions = []  // 窗口尺寸由 setPanelHeight 平滑地调
        popover.contentViewController = host
        popover.contentSize = NSSize(width: 340, height: panelHeight)
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
    }

    private func showPopover() {
        guard let button = item.button else { return }
        floatingPanel?.orderOut(nil)
        updateUsage()  // 面板藏着时可能错过了更新：弹出前按现在的读数和时间重算一遍
        if let screen = button.window?.screen ?? NSScreen.main {
            state.maxHeight = screen.visibleFrame.height - 30  // 留出面板的小箭头和一点边距
        }
        NSApp.activate()
        // 角标对准头像，不对准整个图标的中心
        let pet = NSRect(x: MenuBarLayout.inset, y: 0, width: MenuBarLayout.petSize, height: button.bounds.height)
        popover.contentViewController?.view.layoutSubtreeIfNeeded()
        popover.animates = true
        popover.show(relativeTo: pet, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func showFloatingPanel() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let screen else { return }
        updateUsage()
        state.maxHeight = screen.visibleFrame.height - 40
        let panel = floatingPanel ?? {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 400),
                                styleMask: [.titled, .closable, .fullSizeContentView],
                                backing: .buffered, defer: true)
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isMovableByWindowBackground = true
            panel.level = .floating
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.delegate = self
            panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
            panel.standardWindowButton(.zoomButton)?.isHidden = true
            let host = NSHostingController(rootView: makeRoot())
            host.sizingOptions = []
            panel.contentViewController = host
            floatingPanel = panel
            return panel
        }()
        let size = NSSize(width: 340, height: panelHeight)
        let visible = screen.visibleFrame
        panel.setContentSize(size)
        panel.setFrameTopLeftPoint(NSPoint(x: visible.maxX - panel.frame.width - 12, y: visible.maxY - 8))
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    /// 浮出的面板点到别处就收起，和菜单栏弹出的面板一样
    func windowDidResignKey(_ notification: Notification) {
        guard !menuTracking, NSApp.modalWindow == nil else { return }
        floatingPanel?.orderOut(nil)
        state.page = .overview
        followActive()  // 面板开着时暂停的切换，收起后马上补上
    }

    private var panelHeight: CGFloat = 420

    /// 把面板窗口调到页面的自然高度。开着时用 ease-out 平滑伸缩（页脚贴着底边跟着走），藏着时直接设好
    private func setPanelHeight(_ natural: CGFloat) {
        let target = min(ceil(natural), state.maxHeight.isFinite ? state.maxHeight : natural)
        guard target > 40, abs(target - panelHeight) > 0.5 else { return }
        panelHeight = target
        let size = NSSize(width: 340, height: target)
        if popover.isShown {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.32
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.9, 0.3, 1)
                context.allowsImplicitAnimation = true
                popover.animates = true
                popover.contentSize = size
            }
        } else {
            popover.contentSize = size
        }
        if let panel = floatingPanel {
            // 浮动面板：上边缘不动，往下伸缩
            let top = panel.frame.maxY
            let frame = panel.frameRect(forContentRect: NSRect(origin: .zero, size: size))
            let newFrame = NSRect(x: panel.frame.minX, y: top - frame.height, width: frame.width, height: frame.height)
            panel.setFrame(newFrame, display: true, animate: panel.isVisible)
        }
    }

    /// 下次打开先看额度
    func popoverDidClose(_ notification: Notification) {
        state.page = .overview
        DispatchQueue.main.async { [weak self] in self?.followActive() }  // 面板开着时暂停的切换，收起后马上补上
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuild() }
    func menuWillOpen(_ menu: NSMenu) { menuTracking = true }
    func menuDidClose(_ menu: NSMenu) {
        menuTracking = false
        // 右键菜单开着时不自动切（「立即刷新」要刷的是打开菜单时那家），关上后马上补上。菜单项的动作在这之后才执行，所以晚一拍
        DispatchQueue.main.async { [weak self] in self?.followActive() }
    }

    private func updateReading() {
        state.reading = agyMonitor.reading
        state.agyHistory = agyMonitor.history
        state.querying = agyMonitor.querying
        state.agyStatus = agyMonitor.summary
        finishRefresh(.antigravity, agyMonitor)
        updateUsage()
    }

    /// Claude（CLI 读数，按现在的时间判断过期）+ Codex（日志读数）
    private func updateUsage() {
        let now = Date()
        // Codex 的旧读数照样传给面板，由面板变灰显示（CodexProvider.isStale）
        state.usage = (usageStore?.snapshots ?? []).filter { $0.provider == .codex }
            + [claudeSnapshot(now: now)]
        state.claudeQuerying = claudeMonitor.querying
        // Codex 每轮对话都会在日志里记一条用量：最近那条的时间就是它最近一次在用（不管有没有带总额度）
        let codex = state.usage.first(where: { $0.provider == .codex })
        if let at = codex?.lastActiveAt { recordActive(.codex, at: at) }
        // Codex 新一轮开始的记录（用户主动发起）：主动开始
        if let at = codex?.lastStartAt { recordStart(.codex, at: at) }
        // 每次都按现在的状态重新判断（比如上一家的动静刚满 10 分钟），不只在有新动静时
        followActive()
        updateImage()
    }

    private func claudeSnapshot(now: Date) -> UsageSnapshot {
        if let reading = claudeMonitor.reading {
            let snapshot = reading.snapshot(now: now, history: claudeMonitor.history)
            if snapshot.hasData || !claudeMonitor.querying { return snapshot }
        }
        let note = claudeMonitor.querying
            ? tr("正在用官方 Claude Code CLI 读取 /usage…", "Reading /usage with the official Claude Code CLI…")
            : tr("会用官方 Claude Code CLI 读取 /usage，每 15 分钟一次。",
                 "QuotaPet reads /usage with the official Claude Code CLI every 15 minutes.")
        return UsageSnapshot(provider: .claude, windows: [], generatedAt: now, notes: [note], hasData: false)
    }

    private func rebuild() {
        // 菜单开着时不重建，键盘焦点和展开的子菜单都留着
        guard !menuTracking else { return }
        menu.removeAllItems()
        let panel = action(tr("打开额度面板", "Open Usage Panel"), #selector(openPanel), in: menu)
        panel.image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: nil)
        let refresh = action(tr("立即刷新", "Refresh Now"), #selector(refreshCurrent(_:)), in: menu)
        // 打开菜单时是哪家就刷哪家：菜单开着时有别家动静、关上后宠物跟过去，也不改这一项要刷的对象
        refresh.representedObject = settings.officialPetChoice.entry
        refresh.keyEquivalent = "r"
        refresh.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: tr("官方额度", "Official usage")))
        for entry in OfficialQuotaEntry.allCases {
            if entry == .antigravity, antigravityURL != nil {
                let agy = submenu("Antigravity (agy)", in: menu)
                _ = action(tr("打开 Antigravity · 在设置中查看用量", "Open Antigravity · View usage in Settings"),
                           #selector(openAntigravity), in: agy)
                let guide = action(entry.title, #selector(openEntry(_:)), in: agy)
                guide.representedObject = entry.url
                continue
            }
            let row = action(entry.title, #selector(openEntry(_:)), in: menu)
            row.representedObject = entry.url
            if entry == .claude || entry == .codex {
                let id = entry == .claude ? AppWatcher.claudeBundleID : AppWatcher.codexBundleID
                let status = state.runningApps.contains(id)
                    ? tr("桌面端已打开 · 在浏览器查看额度", "Desktop app open · View usage in browser")
                    : tr("桌面端未打开 · 在浏览器查看额度", "Desktop app closed · View usage in browser")
                if #available(macOS 14.4, *) { row.subtitle = status }
                row.toolTip = status
            }
            row.image = NSImage(systemSymbolName: entry == .antigravity ? "book" : "arrow.up.right.square",
                                accessibilityDescription: nil)
        }
        menu.addItem(.separator())
        let appearance = submenu(tr("宠物形象", "Pet appearance"), in: menu)
        for style in PetStyle.allCases {
            let row = action(style.label, #selector(selectPetStyle(_:)), in: appearance)
            row.representedObject = style.rawValue
            row.state = style == settings.officialPetChoice.style ? .on : .off
            row.image = artwork(file: OfficialPetChoice(rawValue: style.rawValue)!.menuFile, points: 22)
        }
        let agyAppearance = submenu("Antigravity (agy)", in: appearance)
        for choice in OfficialPetChoice.antigravityChoices {
            let row = action(choice.label, #selector(selectPetStyle(_:)), in: agyAppearance)
            row.representedObject = choice.rawValue
            row.state = choice == settings.officialPetChoice ? .on : .off
            row.image = artwork(file: choice.menuFile, points: 22)
        }
        let percent = action(tr("菜单栏显示已用百分比", "Show used percentage in menu bar"), #selector(toggleMenuBarPercent), in: menu)
        percent.state = settings.menuBarText == .petOnly ? .off : .on
        percent.toolTip = tr("有可靠的官方读数时显示（目前只有 agy）", "Shown when a reliable official reading exists (currently agy only)")
        let startup = submenu(tr("启动方式", "Startup"), in: menu)
        let desktop = action(tr("随 Claude 或 Codex 桌面端启动", "Start with Claude or Codex desktop"),
                             #selector(toggleDesktop), in: startup)
        desktop.state = settings.desktopAutoLaunchNeedsApproval ? .mixed : (settings.desktopAutoLaunch ? .on : .off)
        desktop.toolTip = tr("助手等待 macOS 的应用启动事件。", "The helper waits for macOS app-launch events.")
        let login = action(tr("登录时启动 QuotaPet", "Open QuotaPet at login"), #selector(toggleLogin), in: startup)
        login.state = settings.launchAtLoginNeedsApproval ? .mixed : (settings.launchAtLogin ? .on : .off)
        _ = action(tr("终端联动设置…", "Terminal setup…"), #selector(shellSetup), in: startup)
        if settings.desktopAutoLaunchNeedsApproval || settings.launchAtLoginNeedsApproval {
            _ = action(tr("前往系统设置允许登录项…", "Allow login items in System Settings…"), #selector(openLoginItems), in: startup)
        }
        let language = submenu(tr("语言", "Language"), in: menu)
        let auto = action(tr("跟随系统", "System default"), #selector(selectLanguage(_:)), in: language)
        auto.state = settings.language == nil ? .on : .off
        for choice in Language.allCases {
            let row = action(choice.nativeName, #selector(selectLanguage(_:)), in: language)
            row.representedObject = choice.rawValue
            row.state = choice == settings.language ? .on : .off
        }
        menu.addItem(.separator())
        let quit = action(tr("退出 QuotaPet", "Quit QuotaPet"), #selector(quit), in: menu)
        quit.keyEquivalent = "q"
    }

    private func submenu(_ title: String, in parent: NSMenu) -> NSMenu {
        let child = NSMenu(title: title)
        parent.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = child
        return child
    }

    private func action(_ title: String, _ selector: Selector, in parent: NSMenu) -> NSMenuItem {
        let row = parent.addItem(withTitle: title, action: selector, keyEquivalent: "")
        row.target = self
        return row
    }

    /// 菜单栏：宠物 + 旁边的已用百分比（旧版的样子，75% 起标橙、90% 起标红）。只有可靠的官方读数才有数字
    /// 菜单栏：宠物 + 旁边的数字（旧版的样子，75% 起标橙、90% 起标红）。只有可靠的官方读数才有数字，宠物表情跟着这家自己的读数
    private func updateImage() {
        guard let button = item.button else { return }
        let now = Date()
        let choice = settings.officialPetChoice
        let entry = choice.entry
        let presentation = AgyQuotaPresentation(reading: choice.isAntigravity ? agyMonitor.reading : nil, now: now)
        let snapshot = state.usage.first { $0.provider == (entry == .claude ? .claude : .codex) }
        let codexStale = entry == .codex && CodexProvider.isStale(snapshot, now: now)
        let mood = codexStale ? .normal : OfficialOverviewView.artMood(entry: entry, snapshot: entry == .antigravity ? nil : snapshot,
                                                agyReading: agyMonitor.reading, agyHistory: agyMonitor.history,
                                                refreshing: entry == .antigravity ? agyMonitor.querying : entry == .claude && claudeMonitor.querying,
                                                now: now)
        let pet = artwork(file: choice.file(mood: mood, panel: false), points: 22)
        let text: String?, level: Double, limited: Bool
        if entry == .antigravity {
            text = MenuBarPercent.text(usedPercent: presentation.primaryUsedPercent, mode: settings.menuBarText)
            level = presentation.primaryUsedPercent ?? 0
            limited = level >= 100
        } else {
            let made = MenuBarText.make(snapshot, mode: settings.menuBarText, now: now)
            text = made.text.isEmpty ? nil : made.text
            level = made.level
            limited = snapshot?.windows.contains { $0.percent >= 100 } ?? false
        }
        // 宽度按这个显示模式下最长的文字固定：头像钉在最左边、数字左对齐，切换时不左右挪，面板的角标也不动
        // 旧读数在菜单栏照常显示（灰色在菜单栏上看不清），只在面板里变灰标明时间
        let color: NSColor? = codexStale ? nil
            : (text != nil && !limited && level >= 75) ? (level >= 90 ? .systemRed : .systemOrange) : nil
        let width = MenuBarLayout.width(mode: settings.menuBarText)
        if item.length != width { item.length = width }
        button.title = ""
        button.image = MenuBarLayout.image(pet: pet, text: text, color: color, width: width)
        let detail: String
        switch entry {
        case .antigravity: detail = "QuotaPet · " + agyMonitor.summary
        case .claude, .codex:
            if let snapshot, snapshot.hasData {
                detail = "QuotaPet · " + entry.serviceName + " · " + snapshot.windows.map { "\($0.displayTitle) \(Fmt.percent($0.clampedPercent))" }.joined(separator: " · ")
            } else {
                detail = "QuotaPet · " + entry.serviceName + " · " + tr("额度未知", "Quota unknown")
            }
        }
        button.toolTip = detail
        button.setAccessibilityLabel("QuotaPet")
        button.setAccessibilityValue(detail)
    }

    private var artworkCache: [String: NSImage] = [:]

    private static var digestCache: [String: Bool] = [:]

    /// 图存在、而且不是登记过的坏图
    static func artExists(_ file: String) -> Bool {
        guard let url = PaintedArt.root?.appendingPathComponent(file), FileManager.default.fileExists(atPath: url.path) else { return false }
        guard file.hasPrefix("agy/") else { return true }
        if let cached = digestCache[file] { return cached }
        let digest = (try? Data(contentsOf: url)).map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? ""
        let usable = !OfficialPetChoice.brokenArtDigests.contains(digest)
        digestCache[file] = usable
        return usable
    }

    private func artwork(file requested: String, points: CGFloat) -> NSImage {
        // 还没补的 agy 状态图退回这款的基础图
        let file = OfficialPetChoice.resolved(requested, exists: Self.artExists)
        if let cached = artworkCache[file] { return cached }
        let size = NSSize(width: points, height: points)
        let source = PaintedArt.root?.appendingPathComponent(file)
        let image = source.flatMap { NSImage(contentsOf: $0) }
            ?? NSImage(systemSymbolName: "pawprint", accessibilityDescription: "QuotaPet")!
        // Restrict the logical size before assigning to an NSStatusBarButton.
        image.size = size
        image.isTemplate = false
        artworkCache[file] = image
        return image
    }

    @objc private func selectPetStyle(_ row: NSMenuItem) {
        guard let value = row.representedObject as? String, let choice = OfficialPetChoice(rawValue: value) else { return }
        settings.selectOfficialPet(choice)
        rebuild()
        updateImage()
    }

    /// ~/.claude/projects 里的 .jsonl 被写入 = Claude Code 正在干活。QuotaPet 自己查额度留下的会话不算
    /// 开始监听 Claude Code 和 agy 的对话写入（目录启动时还不存在的话，每分钟兜底时补上）
    private func watchActivity() {
        claudeActivity.start()
        agyActivity.start()
    }

    /// 第一次查 Claude 额度之前调用：固定上一次运行时自己查询的时段，记下 history.jsonl 此刻的修改时间
    /// （这次查询的 CLI 可能改写它；补扫晚回来时也仍能认出上一次查询留下的写入、找回离线期间的提示词）
    private func captureLaunchState() {
        previousRunClaudeQuery = settings.ownClaudeQuery()
        if settings.allowsSystemActions { claudeActivity.captureOfflineStarts() }
    }

    /// Claude 的读数或查询状态变了。查询结束时记下这次查询的起止时间（存进设置：重启后也认得出它留下的 history.jsonl 写入；
    /// 也记进本次运行的列表：晚回来的补扫结果对照得到更早的几次）
    private func claudeQueryChanged() {
        if !claudeMonitor.querying, let started = claudeMonitor.lastQueryStarted,
           let ended = claudeMonitor.lastQueryEnded, ended >= started {
            settings.saveOwnClaudeQuery(started: started, ended: ended)
            if !ownClaudeQueries.contains(where: { $0.started == started && $0.ended == ended }) {
                ownClaudeQueries.append((started, ended))
                if ownClaudeQueries.count > 8 { ownClaudeQueries.removeFirst(ownClaudeQueries.count - 8) }
            }
        }
        claudeActivity.recheckPendingStarts()  // 查询结束了：挂起的提示词写入现在能判是不是自己的
        finishRefresh(.claude, claudeMonitor)
        updateUsage()
    }

    /// 某家有了动静：记下时间，更新「正在用」，必要时自动切过去
    private func noteActive(_ entry: OfficialQuotaEntry, at time: Date) {
        if recordActive(entry, at: time) { followActive() }
    }

    /// 某家有了「主动开始」：记下（也算一次动静），必要时自动切过去
    private func noteStart(_ entry: OfficialQuotaEntry, at time: Date) {
        let active = recordActive(entry, at: time)
        if recordStart(entry, at: time) || active { followActive() }
    }

    /// 只记主动开始的时间，规则和 recordActive 一样：未来的不记，更晚的才算
    @discardableResult
    private func recordStart(_ entry: OfficialQuotaEntry, at time: Date) -> Bool {
        let now = Date()
        if time > now.addingTimeInterval(ActivityLedger.futureTolerance) { return false }
        if let previous = lastStart[entry], previous >= time, previous <= now { return false }
        lastStart[entry] = time
        if lastActive[entry].map({ $0 < time }) ?? true { lastActive[entry] = time }
        settings.saveFollowStarts(lastStart)  // 重启后恢复
        return true
    }

    /// 只记时间不判断；更晚的动静才算数（重扫到同一条记录不续期）。
    /// 在未来的时间（复制、还原、时钟偏差留下的）不记：不能盖掉这家已经记下的有效时间，也不能等时间追上后凭空变成「在用」。
    /// 记下的时间比现在还晚（系统时钟往回拨过）时不挡新的：否则回拨后这家的新写入一直被丢掉
    @discardableResult
    private func recordActive(_ entry: OfficialQuotaEntry, at time: Date) -> Bool {
        let now = Date()
        if time > now.addingTimeInterval(ActivityLedger.futureTolerance) { return false }
        if let previous = lastActive[entry], previous >= time, previous <= now { return false }
        lastActive[entry] = time
        return true
    }

    /// 自动跟随正在用的那家（规则在 ActiveService）
    private func followActive() {
        let now = Date()
        // 记下的时间比现在还晚：系统时间往回拨过，这些是回拨之前的旧记录。丢掉，不能等时间追上后又压过回拨后真正的使用
        let limit = now.addingTimeInterval(ActivityLedger.futureTolerance)
        lastActive = lastActive.filter { $0.value <= limit }
        let kept = lastStart.filter { $0.value <= limit }
        if kept.count != lastStart.count {
            lastStart = kept
            settings.saveFollowStarts(kept)
        }
        let active = Set(ActiveService.active(lastActive, now: now))
        if state.activeEntries != active { state.activeEntries = active }
        let paused = popover.isShown || floatingPanel?.isVisible == true || menuTracking
        guard let target = ActiveService.target(enabled: settings.autoFollowActive, paused: paused,
                                                manualElapsed: manualAt.map { ProcessInfo.processInfo.systemUptime - $0 },
                                                lastActive: lastActive, lastStart: lastStart,
                                                current: settings.officialPetChoice.entry, now: now)
        else { return }
        autoSwitching = true
        settings.selectOfficialEntry(target)
        autoSwitching = false
    }

    /// 刷新按钮：Claude / agy 马上用官方 CLI 重读（两次之间至少 30 秒），Codex 重读本机日志
    private func refresh(_ entry: OfficialQuotaEntry) {
        switch entry {
        case .claude: manualRefresh(.claude, claudeMonitor)
        case .antigravity: manualRefresh(.antigravity, agyMonitor)
        case .codex:
            usageStore?.refreshNow()
            // 重读本机日志在后台队列里很快做完（日志一写入本来也会更新）：等刷新按钮转完一圈再报现在的读数
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self else { return }
                let snapshot = self.usageStore?.snapshot(for: .codex)
                self.showNotice(.codexReloaded(officialAt: snapshot?.hasData == true ? snapshot?.officialAt : nil, now: Date()))
            }
        }
        updateUsage()
    }

    /// 点了刷新、还没读完的几家，记的是点的时间：读完后据此判断这次有没有读到新读数
    private var refreshRequests: [OfficialQuotaEntry: Date] = [:]

    private func manualRefresh<R: TimedReading>(_ entry: OfficialQuotaEntry, _ monitor: CLIQuotaMonitor<R>) {
        let now = Date()
        if monitor.refreshNow() || monitor.querying {
            refreshRequests[entry] = now  // 正好在自动读：这次读完也报结果
            state.manualRefreshing.insert(entry)
        } else {
            showNotice(.tooSoon(entry: entry, wait: monitor.manualWait(now: now), now: now))
        }
    }

    /// 读完了：报这次点刷新的结果
    private func finishRefresh<R: TimedReading>(_ entry: OfficialQuotaEntry, _ monitor: CLIQuotaMonitor<R>) {
        guard let requested = refreshRequests[entry], !monitor.querying else { return }
        refreshRequests[entry] = nil
        state.manualRefreshing.remove(entry)
        showNotice(.cliFinished(entry: entry, usable: monitor.reading?.isUsable ?? false, checkedAt: monitor.reading?.checkedAt,
                                requestedAt: requested, message: monitor.reading?.message ?? "", now: Date()))
    }

    private func showNotice(_ notice: RefreshNotice) {
        state.refreshNotice = notice
        DispatchQueue.main.asyncAfter(deadline: .now() + RefreshNotice.duration) { [weak self] in
            if self?.state.refreshNotice == notice { self?.state.refreshNotice = nil }
        }
    }

    @objc private func refreshCurrent(_ sender: NSMenuItem) {
        refresh(sender.representedObject as? OfficialQuotaEntry ?? settings.officialPetChoice.entry)
    }

    @objc private func openPanel() {
        if buttonIsOnScreen { showPopover() } else { showFloatingPanel() }
    }

    /// 从右键菜单打开某家的官方入口：宠物也跟着换成这家（和 0.4.3 一样）
    @objc private func openEntry(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        if let entry = OfficialQuotaEntry.allCases.first(where: { $0.url == url }) {
            settings.selectOfficialEntry(entry)
        }
        open(url)
    }

    private func open(_ url: URL) {
        if !NSWorkspace.shared.open(url) {
            message(tr("未能打开官方页面", "Couldn’t open the official page"), url.absoluteString)
        }
    }

    @objc private func openAntigravity() {
        settings.selectOfficialEntry(.antigravity)
        launchAntigravity()
    }

    private func launchAntigravity() {
        guard let url = antigravityURL else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in self?.message(tr("未能打开 Antigravity", "Couldn’t open Antigravity"), error.localizedDescription) }
        }
    }

    @objc private func toggleMenuBarPercent() {
        settings.menuBarText = settings.menuBarText == .petOnly ? .tightest : .petOnly
    }

    @objc private func toggleDesktop() {
        settings.desktopAutoLaunch.toggle()
        if let issue = settings.desktopAutoLaunchError {
            message(tr("桌面启动设置", "Desktop startup"), issue)
        }
    }

    @objc private func toggleLogin() {
        settings.launchAtLogin = !(settings.launchAtLogin || settings.launchAtLoginNeedsApproval)
        if let issue = settings.launchAtLoginError { message(tr("登录项设置", "Login item"), issue) }
    }

    @objc private func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }

    @objc private func selectLanguage(_ row: NSMenuItem) {
        settings.language = (row.representedObject as? String).flatMap(Language.init(rawValue:))
        updateImage()
    }

    @objc private func shellSetup() {
        guard let url = Bundle.main.url(forResource: "quotapet-shell", withExtension: "sh") else {
            message(tr("需要打包好的 QuotaPet", "The app bundle is required"),
                    tr("请在已安装的 QuotaPet.app 中打开此项。", "Open this item from the installed QuotaPet.app."))
            return
        }
        let quoted = "'" + url.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let command = "source " + quoted
        let alert = NSAlert()
        alert.messageText = tr("随终端命令启动", "Start with terminal commands")
        alert.informativeText = tr("把下面一行加入 ~/.zshrc 或 ~/.bashrc。下次开启交互式终端并运行 codex 或 claude 时，宠物会出现。移除这行即可关闭。",
                                   "Add this line to ~/.zshrc or ~/.bashrc. In a new interactive shell, running codex or claude will show the pet. Remove the line to turn it off.")
            + "\n\n" + command
        alert.addButton(withTitle: tr("复制命令", "Copy command"))
        alert.addButton(withTitle: tr("关闭", "Close"))
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
        }
    }

    private func message(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }

    @objc private func quit() {
        agyMonitor.stop()
        claudeMonitor.stop()
        settings.pauseDesktopAutoLaunch()
        NSApp.terminate(nil)
    }
}


/// 菜单栏图标的固定排版：宠物 22pt 在左，数字在右边的区域里居中；左右留白对称，总宽度只随显示模式变（不随数字变）。
/// 数字用 13.5pt 半粗、单位（% h m d）用 10pt，百分比和倒计时风格统一、宽度也接近
@MainActor
enum MenuBarLayout {
    static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 13.5, weight: .semibold)
    static let unitFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
    static let petSize: CGFloat = 22
    static let gap: CGFloat = 5
    static let inset: CGFloat = 4

    /// 按百分比定宽（平时显示的都是它）；用完时的倒计时（「1h12m」「6d23h」）画的时候等比缩小塞进去
    static func width(mode: MenuBarTextMode) -> CGFloat {
        let samples: [String]
        switch mode {
        case .petOnly: return petSize + inset * 2
        case .session, .tightest: samples = ["100%"]
        case .sessionAndWeekly: samples = ["100% · 100%"]
        }
        let widest = samples.map { styled($0, color: .labelColor, scale: 1).size().width }.max() ?? 0
        return ceil(inset + petSize + gap + widest + inset)
    }

    /// 数字大、单位小，基线对齐
    static func styled(_ text: String, color: NSColor, scale: CGFloat) -> NSAttributedString {
        let number = scale == 1 ? numberFont : NSFont.monospacedDigitSystemFont(ofSize: numberFont.pointSize * scale, weight: .semibold)
        let unit = scale == 1 ? unitFont : NSFont.systemFont(ofSize: unitFont.pointSize * scale, weight: .semibold)
        let result = NSMutableAttributedString()
        for character in text {
            let isNumber = character.isNumber || character == "."
            result.append(NSAttributedString(string: String(character), attributes: [.font: isNumber ? number : unit, .foregroundColor: color]))
        }
        return result
    }

    /// 用绘制回调生成：菜单栏换深浅色时，默认文字颜色跟着系统走
    static func image(pet: NSImage, text: String?, color: NSColor?, width: CGFloat) -> NSImage {
        let height: CGFloat = 22
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            pet.draw(in: NSRect(x: inset, y: 0, width: petSize, height: petSize))
            if let text {
                let room = width - inset - petSize - gap - inset
                var label = styled(text, color: color ?? .labelColor, scale: 1)
                if label.size().width > room {
                    label = styled(text, color: color ?? .labelColor, scale: max(0.7, floor(room / label.size().width * 100) / 100))
                }
                let size = label.size()
                // 在头像右边的区域里居中：百分比和倒计时两边留白一样，高亮框里看着对称
                label.draw(at: NSPoint(x: inset + petSize + gap + max(0, (room - size.width) / 2), y: (height - size.height) / 2))
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}


/// 监听某家会话文件的真实写入（看文件事件和元数据，不读内容；判断规则在 ActivityLedger）：
/// 有写入时把写入发生的时间告诉外面；停下 45 秒后读一次额度，一直在写时最多每 3 分钟读一次，被限频拒绝时每 15 秒再试（ActivityRefresh）。
/// 写入早于最近一次读数的（历史数据）不安排重读。
/// 根目录后来才出现、被删了又重建、会话目录是符号链接并改了指向时重新接上监听：新监听先起来再换掉旧的，接上后把目录元数据比一遍，补上空档里的写入。
/// 整体核对目录（接上时、事件丢了、整个子目录移进来）放在后台线程，同时只跑一轮，期间再来的合并成下一轮
@MainActor
final class ActivityWatch {
    private let ledger: ActivityLedger
    /// agy：增量读会话的步骤记录，认出用户自己发的消息（续聊原会话也认得出）
    private let transcripts: AgyTranscriptReader
    private var pendingTranscripts = false
    /// 测试用、初始化时给定不再改：后台核对列完目录、开始读步骤记录之前在后台线程上调用（App 里为 nil）
    private let beforeTranscriptRead: (@Sendable () -> Void)?
    private var watcher: FileWatcher?
    /// 正在监听的路径（真的起来了才记）：存在的根目录，加上会话目录符号链接此刻指向的地方
    private var watchedPaths: [String] = []
    /// 根目录被移动、重建，或会话目录的链接变了：路径集合没变也要重建监听
    private var rootsChanged = false
    private var timer: Timer?
    /// 最近一次收到真实写入的时间（安排 45 秒后重读、限频用，按收到的时间算）
    private var lastActivity = Date.distantPast
    private let scanQueue = DispatchQueue(label: "QuotaPet.activity-scan", qos: .utility)
    /// 一批事件超过这么多就不在主线程上逐个核对
    static let inlineLimit = 256
    private var scanning = false
    private var pendingScan: [URL] = []
    /// 有真实写入：参数是写入发生的时间（文件的内容修改时间）
    var onActivity: (Date) -> Void = { _ in }
    /// 其中有「主动开始」（提交提示词、新建会话）：参数是它发生的时间
    var onStart: (Date) -> Void = { _ in }
    /// 此刻的写入可能是 QuotaPet 自己查额度留下的：不算主动开始（仍算一次动静）。旧接口，自检用；App 里用 startVerdict
    var suppressStarts: () -> Bool = { false }
    /// 这次主动开始是用户的、QuotaPet 自己查额度留下的，还是查询还没结束、暂时判不了（规则在 StartVerdict.judge）
    var startVerdict: (Date) -> StartVerdict = { _ in .user }
    /// 查询还没结束时挂起的主动开始，查询结束后再判
    private var pendingStarts: [Date] = []
    /// 早于 window 的主动开始（QuotaPet 没运行时提交的提示词、发的消息）：不算「现在在用」。
    /// 这家这次运行里有会话写入时（启动时就在写，或之后才恢复写入）才算它最近一次主动开始：
    /// 那时它仍在 24 小时以内、又没有更晚的开始，就和运行中记下的开始一样（之后没有会话写入就一直不算）
    private var heldStart: Date?
    /// agy：还没按「主动开始」的回看窗口（24 小时）找过步骤记录。第一次有会话写入的证据时找一次（启动时或之后）
    private var offlineLookbackPending = true

    /// 启动时、QuotaPet 第一次自己查额度之前调用：记下开始记录文件（Claude 的 history.jsonl）此刻的修改时间。
    /// 这次查询的 CLI 可能改写它，改写之后离线期间用户最后一次提交提示词的时间就看不到了
    func captureOfflineStarts() {
        for time in ledger.startFileTimes() { hold(time) }
    }

    private func hold(_ time: Date) {
        if heldStart.map({ time > $0 }) ?? true { heldStart = time }
    }

    /// 有会话写入了：挂着的离线开始照常判一次（QuotaPet 自己查询留下的仍算自己的）。和这次报的开始是同一个时间时不重复报
    private func releaseHeld(except reported: Date?) {
        guard let held = heldStart else { return }
        heldStart = nil
        let now = Date()
        guard held != reported, held >= now.addingTimeInterval(-ActivityLedger.startLookback),
              held <= now.addingTimeInterval(ActivityLedger.futureTolerance) else { return }
        route(held)
    }

    /// 查询结束后，把挂起的主动开始重新判一遍：是用户的就补报
    func recheckPendingStarts() {
        let pending = pendingStarts
        pendingStarts = []
        for start in pending { route(start) }
    }

    private func route(_ start: Date) {
        if suppressStarts() { return }
        switch startVerdict(start) {
        case .user: onStart(start)
        case .own: break
        case .undecided: pendingStarts.append(start)
        }
    }
    /// 已经报过的最近一次写入时间：同一次写入再报一遍（重复通知、后台核对）不再安排补读
    private var lastReported: Date?
    var refresh: () -> Void = {}
    var latestReadingAt: () -> Date? = { nil }
    var querying: () -> Bool = { false }
    /// 建监听流（自检时可以换掉，模拟失败）
    var makeWatcher: ([String], @escaping ([FileEvent]) -> Void) -> FileWatcher? = { FileWatcher(paths: $0, onChange: $1) }

    /// clock：读步骤记录时判断「在未来」用的时钟；beforeTranscriptRead：测试用的后台钩子（见上）
    init(source: ActivitySource, clock: @escaping @Sendable () -> Date = { Date() },
         beforeTranscriptRead: (@Sendable () -> Void)? = nil) {
        ledger = ActivityLedger(source: source, window: ActiveService.window)
        transcripts = AgyTranscriptReader(clock: clock)
        self.clock = clock
        self.beforeTranscriptRead = beforeTranscriptRead
    }
    private let clock: @Sendable () -> Date

    /// 接上（或重新接上）监听。启动时和每分钟兜底时调用；路径集合没变、也没被移动过时什么都不做
    func start() {
        let paths = ledger.source.watchPaths()
        guard paths != watchedPaths || rootsChanged || (watcher == nil && !paths.isEmpty) else { return }
        guard !paths.isEmpty else {
            watcher = nil
            watchedPaths = []
            rootsChanged = false
            return
        }
        // 新流起来了才换掉旧的；起不来就留着旧的（还能用的那几个目录不断），下次再试
        guard let new = makeWatcher(paths, { [weak self] events in
            MainActor.assumeIsolated { self?.handle(events) }
        }) else { return }
        watcher = new
        watchedPaths = paths
        rootsChanged = false
        // 监听起来以后再比一遍元数据（agy 连同步骤记录）：接上之前那段时间里的写入按写入时间补记；
        // 再在后台把会话目录里的全部文件记成基线（之后第一次碰到的旧文件只改了属性也认得出，不算活动）
        scan(ledger.source.scanTargets, transcripts: true)
        baseline()
    }

    private func baseline() {
        let ledger = ledger, now = Date()
        scanQueue.async {
            let scan = ledger.collectBaseline(now: now)
            DispatchQueue.main.async { MainActor.assumeIsolated { ledger.applyBaseline(scan) } }
        }
    }

    private func handle(_ events: [FileEvent]) {
        // 根目录被挪动，或会话目录（可能是符号链接）本身变了：重新接上监听
        let sessionDirectories = Set(ledger.source.scanDirectories.map { comparablePath($0.path) })
        let replaced: FileEventFlags = [.itemCreated, .itemRemoved, .itemRenamed]
        if events.contains(where: { $0.flags.contains(.rootChanged)
            || (sessionDirectories.contains(comparablePath($0.path)) && !$0.flags.isDisjoint(with: replaced)) }) {
            rootsChanged = true
            DispatchQueue.main.async { [weak self] in self?.start() }
        }
        // 一大批事件（解压、同步、批量改动）：不在主线程上逐个取元数据，交给后台整体核对一遍
        if events.count > Self.inlineLimit {
            scan(ledger.source.scanTargets, transcripts: true)
            return
        }
        // agy 步骤记录有新行：用户自己发的消息算主动开始（只读新追加的行，只看来源、类型和时间）
        let roots = ledger.source.transcriptRoots
        if !roots.isEmpty {
            let now = clock()
            for path in Set(events.map(\.path).filter { AgyTranscript.isTranscript($0, roots: roots) }) {
                // 第一次见到的文件往回多看一些：早于 window 的用户消息先挂着，等有会话写入再算（见 heldStart）
                guard let time = transcripts.read(path, now: now, window: ledger.window,
                                                  firstReadLookback: ActivityLedger.startLookback) else { continue }
                if time >= now.addingTimeInterval(-ledger.window) { activity(ActivityFinding(time: time, start: time)) } else { hold(time) }
            }
        }
        let parts = ledger.split(events)
        if let found = ledger.observeFinding(parts.files, now: Date()) {
            activity(found, sessionWrite: ledger.lastFindingHadSessionWrite)
        }
        if parts.full {
            scan(ledger.source.scanTargets, transcripts: true)
        } else if !parts.trees.isEmpty {
            scan(parts.trees)
        }
    }

    /// 在后台列目录、取元数据，回到主线程记账
    private func scan(_ directories: [URL], transcripts withTranscripts: Bool = false) {
        guard !scanning else {
            pendingScan += directories
            pendingTranscripts = pendingTranscripts || withTranscripts
            return
        }
        scanning = true
        let ledger = ledger, reader = transcripts, now = Date(), hook = beforeTranscriptRead, clock = clock
        let roots = withTranscripts ? ledger.source.transcriptRoots : []
        let lookbackPending = offlineLookbackPending
        scanQueue.async { [weak self] in
            let found = ledger.collect(directories, now: now)
            hook?()
            // agy 步骤记录：window 以内改过的，读新行（第一次见到的读末尾一段），找用户自己发的消息。
            // 用读的这一刻的时间：排队以后才写的用户消息不能被当成未来记录跳过。
            // 还没按回看窗口找过、这次又有会话写入的证据（会话文件 window 以内改过）：24 小时以内改过的步骤记录都读一遍——
            // 用户消息可能早于 window，之后那个会话只有会话文件在写、步骤记录没再动过。
            // 第一次见到的往回多看一些（早于 window 的先挂着，见 heldStart）
            let (paths, lookback) = AgyTranscriptReader.transcriptsToRead(roots: roots, scan: found, now: now, window: ledger.window,
                                                                          lookbackPending: lookbackPending)
            let userInput = paths
                .compactMap { reader.read($0, now: clock(), window: ledger.window, firstReadLookback: ActivityLedger.startLookback) }.max()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.scanning = false
                    if lookback { self.offlineLookbackPending = false }
                    // 核对开始以后被实时事件更新过的文件，旧结果不会再记进去（ActivityLedger.applyFinding）
                    let finding = self.ledger.applyFinding(found, now: Date())
                    let sessionWrite = self.ledger.lastFindingHadSessionWrite
                    if let userInput {
                        if userInput >= self.clock().addingTimeInterval(-self.ledger.window) {
                            self.activity(ActivityFinding(time: userInput, start: userInput))
                        } else {
                            self.hold(userInput)  // 早于 window：不算「现在在用」，等有会话写入再算
                        }
                    }
                    if let finding { self.activity(finding, sessionWrite: sessionWrite) }
                    // 这次按回看窗口找过：本来就是因为会话文件刚写过（可能已经被实时通知报过，这次核对没有新发现）
                    if lookback, finding == nil { self.releaseHeld(except: nil) }
                    if !self.pendingScan.isEmpty || self.pendingTranscripts {
                        let next = self.pendingScan, again = self.pendingTranscripts
                        self.pendingScan = []
                        self.pendingTranscripts = false
                        self.scan(next, transcripts: again)
                    }
                }
            }
        }
    }

    /// sessionWrite：其中有会话文件的真实写入（不只是开始记录文件）——挂着的离线开始这时才算；
    /// agy 第一次有会话写入、还没按回看窗口找过步骤记录时，补找一次
    private func activity(_ finding: ActivityFinding, sessionWrite: Bool = false) {
        let time = finding.time
        onActivity(time)
        if sessionWrite { releaseHeld(except: finding.start) }
        if let start = finding.start { route(start) }
        if sessionWrite, offlineLookbackPending, !ledger.source.transcriptRoots.isEmpty {
            scan(ledger.source.scanTargets, transcripts: true)
        }
        // 同一次写入已经报过（重复通知、后台核对又碰到）：不再安排补读
        if let reported = lastReported, time <= reported { return }
        lastReported = time
        // 这次写入之前就已经有读数比它新（补回来的历史写入）：额度里已经算上了，不用补读
        if let latest = latestReadingAt(), latest >= time { return }
        lastActivity = Date()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: ActivityRefresh.checkEvery, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                switch ActivityRefresh.step(now: Date(), lastActivity: self.lastActivity,
                                            latestReadingAt: self.latestReadingAt(), querying: self.querying()) {
                case .done:
                    timer.invalidate()
                    self.timer = nil
                case .refresh:
                    self.refresh()
                case .wait:
                    break
                }
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}
