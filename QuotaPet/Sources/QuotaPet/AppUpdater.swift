import AppKit
import CryptoKit
import Foundation
import QuotaPetCore

/// 检查和安装新版本。
/// - 每天最多向 GitHub 查一次最新正式版（AppUpdate.latestReleaseURL），只发一个 GET，不带本机信息、不存 cookie
/// - 用户点了更新才下载；下载完核对大小和 GitHub 给的 SHA-256，解开后再核对 App 标识、版本号和签名
/// - 任何一步不对就不替换，改为打开发布页；替换由一个小脚本在本程序退出后完成，失败就还原旧版
@MainActor
final class AppUpdater {
    private let settings: AppSettings
    private let state: OfficialPanelState
    private var timer: Timer?
    private var checking = false
    /// 状态变了（出现 / 消失更新按钮）：外面重建菜单
    var onChange: () -> Void = {}
    /// 为了更新而退出前：停掉正在跑的官方 CLI 查询（不走「退出」那条路，那条会暂停桌面自动带起）
    var prepareExit: () -> Void = {}

    init(settings: AppSettings, state: OfficialPanelState) {
        self.settings = settings
        self.state = state
    }

    /// 正在运行的版本号；直接 swift run（没有 Info.plist）时没有，就不检查
    static var currentVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    func start() {
        check()
        // 每小时看一眼到没到一天；真正的请求一天最多一次
        let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func settingChanged() {
        if settings.checkForUpdates {
            check()
        } else if !state.update.busy {
            set(.none)
        }
    }

    func check() {
        guard settings.checkForUpdates, !checking, !state.update.busy, let current = Self.currentVersion,
              AppUpdate.shouldCheck(lastAttempt: settings.updateLastAttempt, now: Date()) else { return }
        settings.updateLastAttempt = Date()
        checking = true
        Task {
            let result = await Self.fetchLatest(current: current)
            checking = false
            guard settings.checkForUpdates, !state.update.busy else { return }
            switch result {
            case .available(let offer)?: set(.available(offer))
            case .upToDate?: set(.none)
            case nil: break  // 没查到：保留上次的结果，明天再查
            }
        }
    }

    nonisolated static func fetchLatest(current: String) async -> AppUpdate.Result? {
        var request = URLRequest(url: AppUpdate.latestReleaseURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("QuotaPet/\(current)", forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: Self.sessionConfiguration(resourceTimeout: 45))
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(for: request, delegate: RedirectGuard()),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count < 2_000_000 else { return nil }
        return AppUpdate.parse(data, current: current)
    }

    /// 不存 cookie、不用缓存、不带凭据，同时限制总资源超时（防止慢速连接永久卡住）
    nonisolated static func sessionConfiguration(resourceTimeout: TimeInterval = 60) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = resourceTimeout
        return configuration
    }

    // MARK: - 安装

    func install() {
        guard let offer = state.update.offer, !state.update.busy else { return }
        if case .failed = state.update {
            NSWorkspace.shared.open(offer.pageURL)
            return
        }
        guard let download = offer.download, let target = InstallTarget.current() else {
            NSWorkspace.shared.open(offer.pageURL)
            return
        }
        set(.downloading(offer))
        Task {
            do {
                let staged = try await Task.detached(priority: .userInitiated) {
                    try await Self.prepare(download, version: offer.version, target: target)
                }.value
                set(.installing(offer))
                try Self.launchSwap(staged, target: target)
                prepareExit()
                // 给脚本一点时间开始等待，再退出
                try? await Task.sleep(nanoseconds: 300_000_000)
                NSApp.terminate(nil)
            } catch {
                set(.failed(offer, (error as? UpdateError)?.message ?? error.localizedDescription))
            }
        }
    }

    private func set(_ status: UpdateStatus) {
        guard state.update != status else { return }
        state.update = status
        onChange()
    }

    /// 要被替换的就是正在运行的这个 App：必须是 .app、不在系统的临时隔离位置（从「下载」里直接打开时会这样）、写得进去
    struct InstallTarget: Sendable {
        let app: URL
        let bundleID: String
        let pid: Int32
        let desktopAutostart: Bool

        @MainActor static func current() -> InstallTarget? {
            let app = Bundle.main.bundleURL.resolvingSymlinksInPath()
            let fm = FileManager.default
            guard app.pathExtension == "app", !app.path.contains("/AppTranslocation/"),
                  let bundleID = Bundle.main.bundleIdentifier, bundleID == "dev.quotapet.app",
                  fm.isWritableFile(atPath: app.path), fm.isWritableFile(atPath: app.deletingLastPathComponent().path) else { return nil }
            return InstallTarget(app: app, bundleID: bundleID, pid: ProcessInfo.processInfo.processIdentifier,
                                 desktopAutostart: CommandLine.arguments.contains("--desktop-autostart"))
        }
    }

    struct Staged: Sendable {
        let newApp: URL
        let folder: URL
        let script: URL
    }

    struct UpdateError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    /// 下载、核对、解开，准备好替换用的脚本。临时目录和 App 在同一个磁盘上，替换时是移动不是复制
    nonisolated static func prepare(_ download: UpdateOffer.Download, version: String, target: InstallTarget) async throws -> Staged {
        let fm = FileManager.default
        let folder = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target.app, create: true)
        do {
            let session = URLSession(configuration: sessionConfiguration(resourceTimeout: 300))
            defer { session.finishTasksAndInvalidate() }
            var request = URLRequest(url: download.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
            request.setValue("QuotaPet/\(version)", forHTTPHeaderField: "User-Agent")
            let (file, response) = try await session.download(for: request, delegate: RedirectGuard())
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError(tr("下载失败", "Download failed")) }
            let zip = folder.appendingPathComponent("update.zip")
            try fm.moveItem(at: file, to: zip)
            let size = (try? fm.attributesOfItem(atPath: zip.path)[.size] as? Int) ?? -1
            guard size == download.size, try sha256(of: zip) == download.sha256 else {
                throw UpdateError(tr("下载的文件和 GitHub 上登记的不一致", "The download doesn't match what GitHub lists"))
            }
            let unpacked = folder.appendingPathComponent("new", isDirectory: true)
            try await run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
            try? fm.removeItem(at: zip)
            let apps = (try fm.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)).filter { $0.pathExtension == "app" }
            guard apps.count == 1, let app = apps.first,
                  let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
                  info["CFBundleIdentifier"] as? String == target.bundleID,
                  info["CFBundleShortVersionString"] as? String == version else {
                throw UpdateError(tr("安装包内容不对", "The update package isn't what was expected"))
            }
            try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
            let script = folder.appendingPathComponent("swap.sh")
            try swapScript.write(to: script, atomically: true, encoding: .utf8)
            return Staged(newApp: app, folder: folder, script: script)
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
    }

    /// 等本程序退出后再换：把旧版挪开、新版移进去，失败就把旧版放回去；最后清掉临时目录，重新打开
    nonisolated static let swapScript = """
    #!/bin/sh
    # QuotaPet 更新：$1 本程序的 pid，$2 新版，$3 要替换的位置，$4 临时目录，$5 启动参数
    pid="$1"; new="$2"; dest="$3"; stage="$4"; flag="$5"
    n=0
    while kill -0 "$pid" 2>/dev/null; do
        n=$((n + 1))
        if [ "$n" -gt 600 ]; then rm -rf "$stage"; exit 1; fi
        sleep 0.1
    done
    old="$stage/previous.app"
    if mv "$dest" "$old"; then
        if ! mv "$new" "$dest"; then mv "$old" "$dest"; fi
    fi
    rm -rf "$stage"
    if [ "$flag" = "--desktop-autostart" ]; then open "$dest" --args --desktop-autostart; else open "$dest"; fi
    """

    static func launchSwap(_ staged: Staged, target: InstallTarget) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // 路径只当参数传，不拼进脚本（路径里可能有空格和中文）
        process.arguments = [staged.script.path, String(target.pid), staged.newApp.path, target.app.path, staged.folder.path,
                             target.desktopAutostart ? "--desktop-autostart" : ""]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: staged.folder)
            throw UpdateError(tr("没能启动安装", "Couldn't start the installer"))
        }
    }

    nonisolated static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func run(_ tool: String, _ arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let finished = ProcessExit(process)  // 不用 waitUntilExit：它偶尔漏掉结束通知、永远不返回
        try process.run()
        if !(await finished.waitAsync(timeout: 300)) {
            if process.isRunning { process.terminate() }
            if !(await finished.waitAsync(timeout: 5)) {
                if process.isRunning, process.processIdentifier > 0 { kill(process.processIdentifier, SIGKILL) }
                _ = await finished.waitAsync(timeout: 5)
            }
        }
        // 没确认结束就不读退出码（还在运行时读会崩），按失败处理
        guard finished.hasExited, process.terminationStatus == 0 else {
            throw UpdateError(tool.hasSuffix("codesign") ? tr("新版签名校验没通过", "The new version failed its signature check")
                                                         : tr("解压失败", "Couldn't unpack the update"))
        }
    }
}

/// 只跟着跳到 GitHub 自己的主机（AppUpdate.allowsRedirect）
private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(AppUpdate.allowsRedirect) == true ? request : nil)
    }
}
