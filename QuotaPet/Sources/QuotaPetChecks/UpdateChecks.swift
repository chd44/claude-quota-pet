import Foundation
import QuotaPetCore

/// 检查新版本：版本号比较、解析 GitHub 回复、地址只认这个仓库、一天最多查一次。全用合成数据，不联网
func checkAppUpdate() {
    // 版本号
    func v(_ text: String) -> AppVersion? { AppVersion(text) }
    check(v("0.4.10")! > v("0.4.9")! && v("v0.4.5")! > v("0.4.4")! && v("0.4")! == v("0.4.0")!, "版本号按数字逐段比较，v 前缀可有可无")
    check(v("0.5.0-beta") == nil && v("") == nil && v("0..1") == nil && v("1.٣") == nil && v("1.2.3.4.5") == nil,
          "只认纯数字版本号（预发布、空段、非 ASCII 数字都不认）")

    // 一天最多查一次（失败也算一次）；时钟往回拨了也重新查
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    check(AppUpdate.shouldCheck(lastAttempt: nil, now: now), "第一次启动就查")
    check(!AppUpdate.shouldCheck(lastAttempt: now.addingTimeInterval(-3600), now: now), "一小时前查过：不查")
    check(AppUpdate.shouldCheck(lastAttempt: now.addingTimeInterval(-86400), now: now), "满一天：再查")
    check(AppUpdate.shouldCheck(lastAttempt: now.addingTimeInterval(3600), now: now), "上次时间在未来（改过时钟）：重新查")

    // 解析 releases/latest
    let repo = AppUpdate.repository
    let digest = String(repeating: "ab", count: 32)
    func release(tag: String = "v0.4.5", page: String? = nil, asset: String? = nil, name: String? = nil,
                 digest: String?? = .some("sha256:" + String(repeating: "ab", count: 32)), size: Int = 1000,
                 draft: Bool = false, prerelease: Bool = false) -> Data {
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let assetName = name ?? "QuotaPet-\(version).zip"
        var assetJSON: [String: Any] = ["name": assetName, "size": size,
                                        "browser_download_url": asset ?? "https://github.com/\(repo)/releases/download/\(tag)/\(assetName)"]
        if let digest = digest { assetJSON["digest"] = digest }
        let json: [String: Any] = ["tag_name": tag, "html_url": page ?? "https://github.com/\(repo)/releases/tag/\(tag)",
                                   "draft": draft, "prerelease": prerelease, "assets": [assetJSON]]
        return try! JSONSerialization.data(withJSONObject: json)
    }
    func offer(_ data: Data, current: String = "0.4.4") -> UpdateOffer? {
        if case .available(let offer)? = AppUpdate.parse(data, current: current) { return offer }
        return nil
    }

    let good = offer(release())
    check(good?.version == "0.4.5" && good?.download?.sha256 == digest && good?.download?.size == 1000
          && good?.download?.url.absoluteString == "https://github.com/\(repo)/releases/download/v0.4.5/QuotaPet-0.4.5.zip",
          "新版本：带安装包地址、指纹和大小")
    check(AppUpdate.parse(release(tag: "v0.4.4"), current: "0.4.4") == .upToDate, "同一版本：已是最新")
    check(AppUpdate.parse(release(tag: "v0.4.3"), current: "0.4.4") == .upToDate, "更旧的版本：不提示")
    check(AppUpdate.parse(release(draft: true), current: "0.4.4") == .upToDate
          && AppUpdate.parse(release(prerelease: true), current: "0.4.4") == .upToDate, "草稿和预发布不算")
    check(AppUpdate.parse(release(tag: "v0.5.0-beta"), current: "0.4.4") == nil, "版本号不是纯数字：当作没查到")
    check(AppUpdate.parse(Data("not json".utf8), current: "0.4.4") == nil, "读不懂的回复：当作没查到")
    check(AppUpdate.parse(release(page: "https://evil.example/\(repo)/releases/tag/v0.4.5"), current: "0.4.4") == nil,
          "发布页不在 github.com 这个仓库：不认")

    // 缺任何一样就只能手动下载（download 为 nil），不自动安装
    check(offer(release(digest: .some(nil)))?.download == nil, "没有 SHA-256 指纹：不自动安装")
    check(offer(release(digest: "md5:abc"))?.download == nil && offer(release(digest: "sha256:xyz"))?.download == nil, "指纹格式不对：不自动安装")
    check(offer(release(asset: "https://evil.example/QuotaPet-0.4.5.zip"))?.download == nil, "安装包不在 github.com：不自动安装")
    check(offer(release(asset: "https://github.com/someone/fork/releases/download/v0.4.5/QuotaPet-0.4.5.zip"))?.download == nil,
          "安装包在别的仓库：不自动安装")
    check(offer(release(name: "QuotaPet-0.4.5.dmg"))?.download == nil, "没有这个版本的 zip：不自动安装")
    check(offer(release(size: 0))?.download == nil, "大小不对：不自动安装")

    // 下载跳转只跟到 GitHub 的主机
    check(AppUpdate.allowsRedirect(to: URL(string: "https://release-assets.githubusercontent.com/x")!)
          && AppUpdate.allowsRedirect(to: URL(string: "https://objects.githubusercontent.com/x")!), "跳到 GitHub 的文件服务器：可以")
    check(!AppUpdate.allowsRedirect(to: URL(string: "http://objects.githubusercontent.com/x")!)
          && !AppUpdate.allowsRedirect(to: URL(string: "https://githubusercontent.com.evil.example/x")!)
          && !AppUpdate.allowsRedirect(to: URL(string: "https://evil.example/x")!), "http、仿冒的主机：不跟")
    check(AppUpdate.latestReleaseURL.absoluteString == "https://api.github.com/repos/\(repo)/releases/latest",
          "只问这个仓库的最新正式版")

    // 状态
    let sample = UpdateOffer(version: "0.4.5", pageURL: AppUpdate.releasesPage, download: nil)
    check(UpdateStatus.downloading(sample).busy && UpdateStatus.installing(sample).busy && !UpdateStatus.available(sample).busy
          && UpdateStatus.none.offer == nil && UpdateStatus.failed(sample, "x").offer == sample, "更新状态：下载、安装中算忙")
}
