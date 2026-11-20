import AppKit
import QuotaPetCore
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var desktopSession = DesktopRunSession(automatic: CommandLine.arguments.contains("--desktop-autostart"))
    private var lifecycleSubscriptions: Set<AnyCancellable> = []
    private let demo: Bool
    private let watchBundleID: String
    private let enableLoginItem: Bool
    private var settings: AppSettings!
    private var store: UsageStore!
    private var animator: PetAnimator!
    private var statusController: StatusItemController!
    private var officialController: OfficialMenuController!

    init(demo: Bool, watchBundleID: String?, enableLoginItem: Bool) {
        self.demo = demo
        self.watchBundleID = watchBundleID ?? AppWatcher.claudeBundleID
        self.enableLoginItem = enableLoginItem
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 只保留一个实例：已经有一个先启动了（比如另一个位置的副本），就请它把宠物叫出来，自己退出
        if let primary = Self.earlierInstance() {
            Self.revealAndQuit(primary)
            return
        }

        settings = AppSettings(defaults: demo ? TransientDefaults() : .standard, allowsSystemActions: !demo)
        if demo {
            startDemo()
            return
        }

        UserDefaults.standard.set(true, forKey: FirstLaunch.launchedKey)
        if enableLoginItem { settings.setLaunchAtLogin(true, byUser: false) }
        if CommandLine.arguments.contains("--desktop-autostart") {
            observeDesktopSession()
        } else {
            settings.resumeDesktopAutoLaunch()
        }
        officialController = OfficialMenuController(settings: settings)
    }

    private func observeDesktopSession() {
        NSWorkspace.shared.publisher(for: \.runningApplications).sink { [weak self] apps in
            let ids = Set(apps.filter { !$0.isTerminated }.compactMap(\.bundleIdentifier))
            guard let self, self.desktopSession.shouldExit(
                claudeRunning: ids.contains(AppWatcher.claudeBundleID),
                codexRunning: ids.contains(AppWatcher.codexBundleID)) else { return }
            NSApp.terminate(nil)
        }.store(in: &lifecycleSubscriptions)
    }

    private func startDemo() {
        let watcher = AppWatcher(claudeBundleID: watchBundleID)
        store = UsageStore(providers: [DemoProvider(), DemoCodexProvider()],
                           settings: settings)
        animator = PetAnimator(settings: settings, style: settings.petStyle)
        statusController = StatusItemController(store: store, settings: settings, animator: animator,
                                                headerAnimator: PetAnimator(settings: settings, style: settings.petStyle, isVisible: false),
                                                appWatcher: watcher,
                                                keepVisible: true)

        store.start()
    }

    /// LaunchServices queues this event even while the app is starting.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard urls.contains(where: DesktopActivation.isCLI) else { return }
        desktopSession.keepRunning()
        lifecycleSubscriptions.removeAll()
        settings?.resumeDesktopAutoLaunch()
    }

    /// 比自己先启动的另一个 QuotaPet（几个都比自己早就挑最早的）；自己就是最早的时候是 nil
    private static func earlierInstance() -> NSRunningApplication? {
        guard let id = Bundle.main.bundleIdentifier else { return nil }
        let me = NSRunningApplication.current
        func key(_ app: NSRunningApplication) -> (launched: Date?, pid: Int32) { (app.launchDate, app.processIdentifier) }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != me.processIdentifier && !$0.isTerminated }
        guard let first = others.min(by: { FirstLaunch.launchedEarlier(key($0), than: key($1)) }),
              FirstLaunch.launchedEarlier(key(first), than: key(me)) else { return nil }
        return first
    }

    /// 重新打开正在运行的那个：它会收到 applicationShouldHandleReopen，把藏起来的宠物叫出来。之后自己退出
    private static func revealAndQuit(_ primary: NSRunningApplication) {
        guard let url = primary.bundleURL else {
            NSApp.terminate(nil)
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    /// App 已经在后台运行时又被打开（Spotlight、启动台、双击）：把藏起来的宠物叫出来
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        desktopSession.keepRunning()
        lifecycleSubscriptions.removeAll()
        settings?.resumeDesktopAutoLaunch()
        officialController?.reveal()
        statusController?.reveal()
        return false
    }
}
