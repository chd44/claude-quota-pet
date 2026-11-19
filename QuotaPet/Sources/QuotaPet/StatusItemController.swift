import AppKit
import Combine
import SwiftUI
import QuotaPetCore

/// 菜单栏上的宠物 + 文字。左键弹出面板，右键 / Control-点按弹出菜单。
/// 同时有 Claude 和 Codex 的数据时，宠物和数字跟着更紧张的那家，数字前面加一个小图标区分。
/// 默认只在 Claude（在用 Codex 时还有 Codex）桌面端打开时出现，设置里可以改成一直显示。
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private static let autosaveName = "QuotaPet"
    /// 系统记录图标位置的 key（用户按住 ⌘ 拖动后系统会更新它）
    private static let positionKey = "NSStatusItem Preferred Position \(autosaveName)"
    /// 我们自己备份的位置
    private static let savedPositionKey = "statusItemPosition"

    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let store: UsageStore
    private let settings: AppSettings
    /// 菜单栏上的宠物（跟着最紧张的那家）；面板上看的是同一家时也用它，表情同步
    private let animator: PetAnimator
    /// 面板切到另一家时，面板上的宠物
    private let headerAnimator: PetAnimator
    private let appWatcher: AppWatcher
    private let popoverState = PopoverState()
    private var imageCache: [ImageKey: NSImage] = [:]
    private var cancellables: Set<AnyCancellable> = []

    // 决定显不显示的几个条件
    private var visibility: MenuBarVisibility = .withClaude
    private var appRunning = false
    private var keepVisible: Bool   // 演示模式、第一次启动时一直显示（到退出为止）
    private var pinned: Bool        // 用户临时叫出来了（再次打开 QuotaPet）

    private struct ImageKey: Hashable {
        let picture: PetPicture
        let glyph: String?
    }

    init(store: UsageStore, settings: AppSettings, animator: PetAnimator, headerAnimator: PetAnimator, appWatcher: AppWatcher,
         keepVisible: Bool) {
        self.store = store
        self.settings = settings
        self.animator = animator
        self.headerAnimator = headerAnimator
        self.appWatcher = appWatcher
        self.keepVisible = keepVisible
        self.pinned = keepVisible

        Self.restorePosition()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = Self.autosaveName
        super.init()
        configureButton()
        configurePopover()

        // @Published 在赋值之前就通知，所以下面都用传进来的新值，不去读 store 的属性。
        // shown：要显示的几家（有数据、又没在设置里关掉的）
        let shown = Publishers.CombineLatest(store.$snapshots, settings.$showCodex)
            .map { snapshots, showCodex in UsageSnapshot.visible(snapshots, hidden: AppSettings.hiddenProviders(showCodex: showCodex)) }
        let glyph = Publishers.CombineLatest(shown, settings.$menuBarText)
            .map { shown, mode in Self.glyph(shown, mode: mode) }
            .removeDuplicates()
        Publishers.CombineLatest(animator.$frame, glyph)
            .sink { [weak self] frame, glyph in self?.showPet(frame.icon, glyph: glyph) }
            .store(in: &cancellables)
        Publishers.CombineLatest3(shown, settings.$menuBarText, settings.$language)
            .sink { [weak self] shown, mode, _ in self?.showText(shown, mode: mode) }
            .store(in: &cancellables)
        // tick：心情和时间有关，没有新快照时也要按时重算
        Publishers.CombineLatest4(shown.combineLatest(store.$tick), store.$errors, settings.$petStyle, settings.$codexPetStyle)
            .sink { [weak animator, weak store] shown, errors, claudeStyle, codexStyle in
                // 一家都显示不了（比如 Claude 第一次就读出错、又没有 Codex 的数据）又有出错的：疑惑
                let focus = UsageSnapshot.focus(of: shown.0)
                // memory 在快照赋值之前就记好了，这里读得到新的
                let memory = focus.flatMap { store?.memory[$0.provider] } ?? PetMemory()
                animator?.show(mood: PetStatus.of(focus, failed: !errors.isEmpty, memory: memory, now: Date()).mood,
                               style: PetStyle.of(focus?.provider ?? .claude, claudeStyle: claudeStyle, codexStyle: codexStyle))
            }
            .store(in: &cancellables)
        // 面板开着、用户还没自己点过切换条时，跟着宠物换：第一次打开时数据还没读完，读完后最紧张的那家可能换了
        shown
            .sink { [weak self] shown in
                guard let self, self.popoverState.isShown, !self.popoverState.picked,
                      let focus = UsageSnapshot.focus(of: shown)?.provider, focus != self.popoverState.selected else { return }
                self.popoverState.selected = focus
            }
            .store(in: &cancellables)
        // 面板开着、看的又不是菜单栏上那家时，面板上的宠物才要单独播
        Publishers.CombineLatest3(popoverState.$isShown, popoverState.$selected, shown)
            .sink { [weak headerAnimator] isShown, selected, shown in
                headerAnimator?.isVisible = isShown && selected != UsageSnapshot.focus(of: shown)?.provider
            }
            .store(in: &cancellables)
        let running = appWatcher.$claudeRunning.combineLatest(appWatcher.$codexRunning)
        let installed = appWatcher.$claudeInstalled.combineLatest(appWatcher.$codexInstalled)
        // Codex 还没算出来（刚启动时第一次扫描要一会儿）：先当作在用，不然只装了 Codex 桌面端的人开机时宠物会先出现再藏起来
        let codexPending = Publishers.CombineLatest(store.$snapshots, store.$errors)
            .map { snapshots, errors in !snapshots.contains { $0.provider == .codex } && errors[.codex] == nil }
        Publishers.CombineLatest4(settings.$visibility, running, installed, shown.combineLatest(codexPending))
            .sink { [weak self] visibility, running, installed, shownAndPending in
                let (shown, codexPending) = shownAndPending
                guard let self else { return }
                let usesCodex = shown.contains { $0.provider == .codex }
                self.visibility = visibility
                self.appRunning = running.0 || (running.1 && usesCodex)
                self.popoverState.usesCodex = usesCodex
                self.popoverState.claudeRunning = running.0
                self.popoverState.canFollowApp = installed.0 || (installed.1 && (usesCodex || codexPending))
                self.updateVisibility()
            }
            .store(in: &cancellables)
    }

    /// Claude（在用 Codex 时还有 Codex）开着，或设置成一直显示，或者根本没装桌面端，才出现；藏起来时动画也停掉，只在后台等着发提醒
    private func updateVisibility() {
        let show = visibility.shouldShow(appRunning: appRunning, canFollow: popoverState.canFollowApp, pinned: pinned || popover.isShown)
        if statusItem.isVisible != show {
            if show { Self.restorePosition() } else { Self.rememberPosition() }
            statusItem.isVisible = show
        }
        animator.isVisible = show
    }

    // 新图标默认排在菜单栏最左边，菜单栏一挤（尤其是刘海屏）就会藏到刘海后面。
    // 所以第一次把它放到最右边、紧挨着时钟（位置 0）。
    // macOS 26 在隐藏图标时会删掉位置记录，再显示就跑回最左边，所以隐藏前备份一份，显示前写回去。
    private static func restorePosition() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: positionKey) == nil {
            defaults.set(defaults.object(forKey: savedPositionKey) ?? 0, forKey: positionKey)
        }
    }

    private static func rememberPosition() {
        if let position = UserDefaults.standard.object(forKey: positionKey) {
            UserDefaults.standard.set(position, forKey: savedPositionKey)
        }
    }

    /// 宠物藏起来的时候，再次打开 QuotaPet（Spotlight / 启动台）就把它叫出来，并打开面板。
    /// untilQuit：第一次启动时用，面板关了也一直显示到退出（不然点一下通知授权的弹窗，面板一关宠物就又藏起来了）
    func reveal(untilQuit: Bool = false) {
        if untilQuit { keepVisible = true }
        pinned = true
        updateVisibility()
        // 图标刚出现时位置还没排好，等一下再弹面板
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.popover.isShown else { return }
                self.togglePopover()
            }
        }
    }

    // MARK: - 菜单栏

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(handleClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
    }

    /// glyph：数字前面的小图标，见 glyph(_:mode:)
    private func showPet(_ frame: PetPicture, glyph: String?) {
        let key = ImageKey(picture: frame, glyph: glyph)
        let image = imageCache[key] ?? MenuBarIcon.image(frame, glyph: glyph)
        imageCache[key] = image
        statusItem.button?.image = image
    }

    /// 不止一家时，数字前面加上跟着的那家的小图标（画在宠物那张图里）；只有一家、或者旁边没有数字时不加
    private static func glyph(_ shown: [UsageSnapshot], mode: MenuBarTextMode) -> String? {
        guard shown.count > 1, let focus = UsageSnapshot.focus(of: shown),
              !MenuBarText.make(focus, mode: mode, now: Date()).text.isEmpty else { return nil }
        return MenuBarIcon.glyph(for: focus.provider)
    }

    /// shown：要显示的几家（UsageSnapshot.visible）
    private func showText(_ shown: [UsageSnapshot], mode: MenuBarTextMode) {
        guard let button = statusItem.button else { return }
        let now = Date()
        let snapshot = UsageSnapshot.focus(of: shown)
        let (text, level) = MenuBarText.make(snapshot, mode: mode, now: now)
        let title = text.isEmpty ? "" : " " + text
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let limited = snapshot?.windows.contains { $0.percent >= 100 } ?? false
        if !limited, level >= 75 {
            // 快用完了：数字标橙 / 标红。被限流时宠物已经在睡觉了，倒计时就不标红吓人了
            let color: NSColor = level >= 90 ? .systemRed : .systemOrange
            button.attributedTitle = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: color])
        } else {
            button.font = font
            button.title = title
        }
        if let usage = tooltip(for: shown, now: now) {
            button.toolTip = usage
            // 不止一家时，数字是哪家的只靠小图标看，读屏要说出来
            let owner = shown.count > 1 && !text.isEmpty ? snapshot.map { tr("菜单栏显示的是 \($0.provider.displayName)。", "Showing \($0.provider.displayName). ") } : nil
            button.setAccessibilityLabel("QuotaPet " + (owner ?? "") + usage)
        } else {
            button.toolTip = tr("QuotaPet：还没有额度数据", "QuotaPet: no usage data yet")
            button.setAccessibilityLabel(button.toolTip)
        }
    }

    /// 各家各窗口的用量和重置时间；还没有数据时为 nil
    private func tooltip(for shown: [UsageSnapshot], now: Date) -> String? {
        let blocks = shown.filter(\.hasData).map { snapshot -> String in
            let lines = snapshot.windows.map { w -> String in
                var line = "\(w.displayTitle) \(Fmt.percent(w.clampedPercent))"
                if let reset = w.resetsAt {
                    let when = Fmt.fromNow(reset.timeIntervalSince(now))
                    line += tr("，\(when)重置", ", resets \(when)")
                }
                return line
            }
            let name = snapshot.provider.displayName
            return ([tr("\(name) 额度", "\(name) usage")] + lines).joined(separator: "\n")
        }
        return blocks.isEmpty ? nil : blocks.joined(separator: "\n\n")
    }

    // MARK: - 点击

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            togglePopover()
        }
    }

    private func configurePopover() {
        let root = PopoverRoot(store: store, settings: settings, state: popoverState, animator: animator,
                               headerAnimator: headerAnimator, onQuit: { NSApp.terminate(nil) })
        let host = NSHostingController(rootView: root)
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.delegate = self
    }

    private func togglePopover(page: PopoverState.Page = .overview) {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem.button else { return }
        popoverState.page = page
        popoverState.selected = store.focus?.provider ?? .claude  // 每次打开先看宠物跟着的那家
        popoverState.picked = false
        popoverState.opened()
        if let screen = button.window?.screen ?? NSScreen.main {
            popoverState.maxHeight = screen.visibleFrame.height - 30  // 留出面板的小箭头和一点边距
        }
        store.refresh()
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popoverState.isShown = true
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) {
        popoverState.page = .overview
        popoverState.isShown = false
        pinned = keepVisible
        updateVisibility()
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(menuItem(tr("立即刷新", "Refresh Now"), #selector(refreshNow), "r"))
        menu.addItem(menuItem(tr("设置…", "Settings…"), #selector(openSettings), ","))
        menu.addItem(.separator())
        menu.addItem(menuItem(tr("退出 QuotaPet", "Quit QuotaPet"), #selector(quit), "q"))
        statusItem.menu = menu
        statusItem.button?.performClick(nil)  // 弹出菜单，关掉后才返回
        statusItem.menu = nil
    }

    private func menuItem(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func refreshNow() { store.refreshNow() }
    @objc private func openSettings() { togglePopover(page: .settings) }
    @objc private func quit() { NSApp.terminate(nil) }
}
