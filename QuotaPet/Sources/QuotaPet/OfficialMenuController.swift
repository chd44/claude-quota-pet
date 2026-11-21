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
    @Published var querying = false
    @Published var agyStatus = ""
    @Published var runningApps: Set<String> = []
    @Published var maxHeight: CGFloat = .infinity
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
                                     usage: state.usage,
                                     desktopRunning: state.runningApps.contains(desktopID),
                                     canOpenAntigravity: canOpenAntigravity,
                                     onSelect: onSelect, onOpenOfficial: onOpenOfficial, onOpenAntigravity: onOpenAntigravity,
                                     refreshing: entry == .claude ? state.claudeQuerying : entry == .antigravity ? state.querying : false,
                                     onRefresh: { onRefresh(entry) },
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
    /// 监听 Claude Code 的对话文件有没有写入（只看文件事件，不读内容），用来在干完活后自动读一次官方额度
    private var activityWatcher: FileWatcher?
    private var activityTimer: Timer?
    private var lastActivity = Date.distantPast
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
            ? UsageStore(providers: [CodexProvider()], settings: settings) : nil
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
        claudeMonitor.onChange = { [weak self] in self?.updateUsage() }
        // 三家一直保持读数：切换页签只换显示，不清空、不重读（打开面板就能看到三家已有的数据）
        agyMonitor.select(true)
        claudeMonitor.select(true)
        updateReading()
        settings.$officialPetChoice.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateImage() }
        }.store(in: &subscriptions)
        settings.$menuBarText.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.updateImage() }
            .store(in: &subscriptions)
        settings.$language.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.updateReading() }
            .store(in: &subscriptions)
        usageStore?.$snapshots.receive(on: RunLoop.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateUsage() }  // @Published 在赋值之前就通知：等新值落定再读
        }.store(in: &subscriptions)
        // 每分钟兜底一次：读数过期、重置时间到了，面板和菜单栏要跟着变
        usageStore?.$tick.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            self?.watchClaudeActivity()  // ~/.claude/projects 启动时还不存在的话，之后补上
            self?.updateUsage()
        }
            .store(in: &subscriptions)
        usageStore?.start()
        watchClaudeActivity()
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
    func popoverDidClose(_ notification: Notification) { state.page = .overview }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuild() }
    func menuWillOpen(_ menu: NSMenu) { menuTracking = true }
    func menuDidClose(_ menu: NSMenu) { menuTracking = false }

    private func updateReading() {
        state.reading = agyMonitor.reading
        state.agyHistory = agyMonitor.history
        state.querying = agyMonitor.querying
        state.agyStatus = agyMonitor.summary
        updateUsage()
    }

    /// Claude（CLI 读数，按现在的时间判断过期）+ Codex（日志读数）
    private func updateUsage() {
        let now = Date()
        // Codex 的旧读数照样传给面板，由面板变灰显示（CodexProvider.isStale）
        state.usage = (usageStore?.snapshots ?? []).filter { $0.provider == .codex }
            + [claudeSnapshot(now: now)]
        state.claudeQuerying = claudeMonitor.querying
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
        let refresh = action(tr("立即刷新", "Refresh Now"), #selector(refreshCurrent), in: menu)
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
    private func watchClaudeActivity() {
        guard settings.allowsSystemActions, activityWatcher == nil else { return }
        let projects = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects").path
        activityWatcher = FileWatcher(paths: [projects]) { [weak self] events in
            MainActor.assumeIsolated {
                guard events.contains(where: { $0.path.hasSuffix(".jsonl") && !$0.path.contains("-QuotaPet-ClaudeQuotaCheck") }) else { return }
                self?.claudeActivity()
            }
        }
    }

    /// 活动停下 45 秒后读一次；一直在写的话，最晚每 3 分钟也读一次。
    /// 被限频拒绝时不丢：每 15 秒再看一次，直到活动之后真的读到了新读数
    private func claudeActivity() {
        lastActivity = Date()
        guard activityTimer == nil else { return }
        let timer = Timer(timeInterval: ActivityRefresh.checkEvery, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                switch ActivityRefresh.step(now: Date(), lastActivity: self.lastActivity,
                                            latestReadingAt: self.claudeMonitor.history.last?.checkedAt,
                                            querying: self.claudeMonitor.querying) {
                case .done:
                    timer.invalidate()
                    self.activityTimer = nil
                case .refresh:
                    self.claudeMonitor.refreshForActivity()
                case .wait:
                    break
                }
            }
        }
        activityTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// 刷新按钮：Claude / agy 马上用官方 CLI 重读（两次之间至少 30 秒），Codex 重读本机日志
    private func refresh(_ entry: OfficialQuotaEntry) {
        switch entry {
        case .claude: claudeMonitor.refreshNow()
        case .antigravity: agyMonitor.refreshNow()
        case .codex: usageStore?.refreshNow()
        }
        updateUsage()
    }

    @objc private func refreshCurrent() { refresh(settings.officialPetChoice.entry) }

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
