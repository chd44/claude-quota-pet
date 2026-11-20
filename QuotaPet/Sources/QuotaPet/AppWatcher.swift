import AppKit
import Combine
import QuotaPetCore

/// 盯着 Claude 和 Codex 桌面端有没有在运行、装没装。
/// 用 runningApplications 的 KVO，不用 didLaunch / didTerminate 通知：
/// 那两个通知只发给有 Dock 图标的 App，KVO 什么 App 都能收到。
@MainActor
final class AppWatcher: ObservableObject {
    nonisolated static let claudeBundleID = "com.anthropic.claudefordesktop"
    nonisolated static let codexBundleID = "com.openai.codex"

    @Published private(set) var claudeRunning: Bool
    @Published private(set) var codexRunning: Bool
    /// 只用命令行、没装桌面端时，「打开时出现」永远等不到，宠物按一直显示算（MenuBarVisibility.shouldShow）
    @Published private(set) var claudeInstalled: Bool
    @Published private(set) var codexInstalled: Bool

    private var cancellables: Set<AnyCancellable> = []

    /// claudeBundleID 可以换成别的 App，调试用（--watch-bundle-id）
    init(claudeBundleID: String = AppWatcher.claudeBundleID, codexBundleID: String = AppWatcher.codexBundleID) {
        let apps = NSWorkspace.shared.runningApplications
        claudeRunning = Self.isRunning(claudeBundleID, in: apps)
        codexRunning = Self.isRunning(codexBundleID, in: apps)
        claudeInstalled = Self.isInstalled(claudeBundleID)
        codexInstalled = Self.isInstalled(codexBundleID)

        // runningApplications 只会在主线程变化
        let running = NSWorkspace.shared.publisher(for: \.runningApplications)
        running.map { Self.isRunning(claudeBundleID, in: $0) }
            .removeDuplicates()
            .sink { [weak self] in self?.claudeRunning = $0 }
            .store(in: &cancellables)
        running.map { Self.isRunning(codexBundleID, in: $0) }
            .removeDuplicates()
            .sink { [weak self] in self?.codexRunning = $0 }
            .store(in: &cancellables)
        // Recheck installation on workspace events, with no recurring timer.
        let recheck = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .map { _ in }
            .merge(with: $claudeRunning.map { _ in }, $codexRunning.map { _ in })
        recheck.map { Self.isInstalled(claudeBundleID) }
            .removeDuplicates()
            .sink { [weak self] in self?.claudeInstalled = $0 }
            .store(in: &cancellables)
        recheck.map { Self.isInstalled(codexBundleID) }
            .removeDuplicates()
            .sink { [weak self] in self?.codexInstalled = $0 }
            .store(in: &cancellables)
    }

    /// 看所有副本，不只看 LaunchServices 挑的那一个：它挑中的可能正好是废纸篓里的
    private nonisolated static func isInstalled(_ bundleID: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID)
            .contains { MenuBarVisibility.countsAsInstalled(appPath: $0.path, home: home) }
    }

    private nonisolated static func isRunning(_ bundleID: String, in apps: [NSRunningApplication]) -> Bool {
        apps.contains { $0.bundleIdentifier == bundleID && !$0.isTerminated }
    }
}
