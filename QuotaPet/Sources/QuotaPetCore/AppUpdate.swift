import Foundation

/// 只认纯数字的版本号（0.4.4、v0.4.5），按段比较：0.4.10 比 0.4.9 新，0.4 和 0.4.0 一样
public struct AppVersion: Comparable, Sendable, CustomStringConvertible {
    public let parts: [Int]
    public let description: String

    public init?(_ text: String) {
        let trimmed = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let pieces = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard !pieces.isEmpty, pieces.count <= 4,
              pieces.allSatisfy({ !$0.isEmpty && $0.count <= 6 && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else { return nil }
        parts = pieces.map { Int($0)! }
        description = trimmed
    }

    private func padded(_ count: Int) -> [Int] { parts + Array(repeating: 0, count: max(0, count - parts.count)) }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.parts.count, rhs.parts.count)
        return lhs.padded(count).lexicographicallyPrecedes(rhs.padded(count))
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.parts.count, rhs.parts.count)
        return lhs.padded(count) == rhs.padded(count)
    }
}

/// GitHub 上发布的新版本。download 为 nil 时（没有安装包、缺指纹、地址不对）只能打开发布页手动下载
public struct UpdateOffer: Equatable, Sendable {
    public struct Download: Equatable, Sendable {
        public let url: URL
        /// 小写十六进制的 SHA-256，来自 GitHub 给安装包算的 digest
        public let sha256: String
        public let size: Int

        public init(url: URL, sha256: String, size: Int) {
            self.url = url
            self.sha256 = sha256
            self.size = size
        }
    }

    public let version: String
    public let pageURL: URL
    public let download: Download?

    public init(version: String, pageURL: URL, download: Download?) {
        self.version = version
        self.pageURL = pageURL
        self.download = download
    }
}

/// 检查新版本：每天问一次 GitHub 上 QuotaPet 仓库的最新正式版。
/// 只发这一个 GET 请求，不带任何本机信息；仓库和主机写死在这里，不能用设置或参数改到别处
public enum AppUpdate {
    public static let repository = "chd44/claude-quota-pet"
    public static let latestReleaseURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    public static let releasesPage = URL(string: "https://github.com/\(repository)/releases/latest")!
    public static let checkInterval: TimeInterval = 86400

    /// 上次试过（成功失败都算）满一天才再查；上次的时间在未来（改过系统时钟）也重新查
    public static func shouldCheck(lastAttempt: Date?, now: Date) -> Bool {
        guard let lastAttempt else { return true }
        let elapsed = now.timeIntervalSince(lastAttempt)
        return elapsed >= checkInterval || elapsed < -300
    }

    public enum Result: Equatable, Sendable {
        case upToDate
        case available(UpdateOffer)
    }

    /// 解析 releases/latest 的回复。读不懂的回复返回 nil（当作这次没查到，明天再查）
    public static func parse(_ data: Data, current: String) -> Result? {
        guard let release = try? JSONDecoder().decode(Release.self, from: data),
              let running = AppVersion(current) else { return nil }
        if release.draft == true || release.prerelease == true { return .upToDate }
        guard let latest = AppVersion(release.tag_name) else { return nil }
        guard latest > running else { return .upToDate }
        guard let page = URL(string: release.html_url), isReleasePage(page) else { return nil }
        let name = "QuotaPet-\(latest.description).zip"
        let download = release.assets.first { $0.name == name }.flatMap { asset -> UpdateOffer.Download? in
            guard let url = URL(string: asset.browser_download_url), isReleaseAsset(url, tag: release.tag_name, name: name),
                  let digest = asset.digest, digest.hasPrefix("sha256:") else { return nil }
            let hex = String(digest.dropFirst("sha256:".count)).lowercased()
            guard hex.count == 64, hex.allSatisfy(\.isHexDigit), asset.size > 0, asset.size < 200_000_000 else { return nil }
            return UpdateOffer.Download(url: url, sha256: hex, size: asset.size)
        }
        return .available(UpdateOffer(version: latest.description, pageURL: page, download: download))
    }

    /// 发布页只能是这个仓库在 github.com 上的页面
    public static func isReleasePage(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.user == nil && url.port == nil
            && url.path.hasPrefix("/\(repository)/releases/")
    }

    /// 安装包只能是这个仓库这个版本的那个 zip
    public static func isReleaseAsset(_ url: URL, tag: String, name: String) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.user == nil && url.port == nil && url.query == nil
            && url.path == "/\(repository)/releases/download/\(tag)/\(name)"
    }

    /// 下载时 GitHub 会跳到它自己的文件服务器；只跟着跳到 GitHub 的主机
    public static func allowsRedirect(to url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.port == nil, let host = url.host?.lowercased() else { return false }
        return host == "github.com" || host.hasSuffix(".githubusercontent.com")
    }

    private struct Release: Decodable {
        let tag_name: String
        let html_url: String
        let draft: Bool?
        let prerelease: Bool?
        let assets: [Asset]
    }

    private struct Asset: Decodable {
        let name: String
        let size: Int
        let digest: String?
        let browser_download_url: String
    }
}

/// 面板和菜单里更新按钮的状态
public enum UpdateStatus: Equatable, Sendable {
    case none
    case available(UpdateOffer)
    case downloading(UpdateOffer)
    case installing(UpdateOffer)
    /// 自动更新没成功：说明原因，按钮改成打开发布页
    case failed(UpdateOffer, String)

    public var offer: UpdateOffer? {
        switch self {
        case .none: return nil
        case .available(let offer), .downloading(let offer), .installing(let offer), .failed(let offer, _): return offer
        }
    }

    public var busy: Bool {
        switch self {
        case .downloading, .installing: return true
        default: return false
        }
    }
}
