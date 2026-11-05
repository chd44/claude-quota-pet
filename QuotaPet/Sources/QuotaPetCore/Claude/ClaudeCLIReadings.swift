import Foundation

/// 官方命令行（Claude 桌面端自带的 claude）发一次最小请求时，服务端随响应回来的额度读数。
/// 只在用户打开「用命令行补官方读数」之后才有（默认关闭），QuotaPet 自己不联网：联网的是命令行，用它自己的登录。
public struct CLIReading: Codable, Equatable, Sendable {
    public var time: Date
    /// 命令行登录的组织（`claude auth status` 里的 orgId）。和桌面端对不上的读数不用，见 ClaudeCLIReadings.merge
    public var org: String?
    /// 5 小时、每周额度的已用百分比（0–100）
    public var session: Double?
    public var weekly: Double?
    /// 两个窗口的重置时间（官方给的，不用推算）
    public var sessionResetsAt: Date?
    public var weeklyResetsAt: Date?

    public init(time: Date, org: String? = nil, session: Double? = nil, weekly: Double? = nil,
                sessionResetsAt: Date? = nil, weeklyResetsAt: Date? = nil) {
        self.time = time
        self.org = org
        self.session = session
        self.weekly = weekly
        self.sessionResetsAt = sessionResetsAt
        self.weeklyResetsAt = weeklyResetsAt
    }

    /// 和桌面端的读数同一种形式（fh、sd），合并后下游（换算率学习、窗口推算、其他端用量）都不用改
    public var sample: PlanUsageSample? {
        var values: [String: Double] = [:]
        if let session { values["fh"] = session }
        if let weekly { values["sd"] = weekly }
        return values.isEmpty ? nil : PlanUsageSample(time: time, org: org, values: values)
    }
}

public enum ClaudeCLIReadings {
    /// 记录保留多久：和本机日志的保留期差不多
    public static let retention: TimeInterval = 8 * 86400

    // MARK: - 解析

    /// 从 `claude -p … --output-format stream-json --verbose` 的输出里取额度读数。
    /// 输出里有 `rate_limit_event`：`rate_limit_info.unifiedWindows.five_hour / seven_day` 各有 `utilization`（0–1，
    /// 超额时可能略大于 1）和 `resetsAt`（秒级时间戳）；快到限额时的老格式只有 `rateLimitType` + `utilization`。
    /// 一行行解析、不认识的行跳过（命令行更新后字段可能变，认不出就是 nil，调用方退回估算）。
    public static func parse(_ output: String, org: String?, now: Date) -> CLIReading? {
        var reading = CLIReading(time: now, org: org)
        var found = false

        func apply(window id: String, utilization: Any?, resetsAt: Any?, rejected: Bool, percentFormat: Bool) {
            var percent = percentValue(utilization, percentFormat: percentFormat)
            if rejected { percent = 100 }  // 被拒绝就是这个窗口用完了
            let reset = dateValue(resetsAt, now: now, window: id)
            guard percent != nil || reset != nil else { return }
            found = true
            switch id {
            case "five_hour":
                if let percent { reading.session = percent }
                if let reset { reading.sessionResetsAt = reset }
            case "seven_day":
                if let percent { reading.weekly = percent }
                if let reset { reading.weeklyResetsAt = reset }
            default:
                break
            }
        }

        for line in output.split(whereSeparator: \.isNewline) {
            guard line.contains("rate_limit_event"),
                  let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["type"] as? String == "rate_limit_event",
                  let info = object["rate_limit_info"] as? [String: Any] else { continue }
            let rejected = info["status"] as? String == "rejected"
            let type = info["rateLimitType"] as? String
            if let windows = info["unifiedWindows"] as? [String: Any] {
                let entries: [(id: String, window: [String: Any])] = windows.compactMap { element in
                    (element.value as? [String: Any]).map { (id: element.key, window: $0) }
                }
                let percentFormat = entries.contains { looksLikePercent($0.window["utilization"]) }
                for entry in entries {
                    apply(window: entry.id, utilization: entry.window["utilization"], resetsAt: entry.window["resetsAt"],
                          rejected: rejected && entry.id == type, percentFormat: percentFormat)
                }
            } else if let type {
                apply(window: type, utilization: info["utilization"], resetsAt: info["resetsAt"], rejected: rejected,
                      percentFormat: looksLikePercent(info["utilization"]))
            }
        }
        return found ? reading : nil
    }

    /// utilization 换成百分比，保留一位小数，去掉浮点误差。官方格式是 0–1 的比例；超额时可能略大于 1，照样乘 100、封顶 100（算用完），
    /// 不能当成已经是百分比，不然 1.05 会变成 1%。percentFormat：同一条读数里有明显是百分比的数（见 looksLikePercent），
    /// 说明命令行改成了直接给百分比，这时不乘 100
    static func percentValue(_ value: Any?, percentFormat: Bool = false) -> Double? {
        guard let v = number(value), v >= 0 else { return nil }
        let percent = percentFormat ? v : v * 100
        return (min(percent, 100) * 10).rounded() / 10
    }

    /// 比例再超额也到不了 2 倍，大于 2 的只能是已经换成百分比的数
    static func looksLikePercent(_ value: Any?) -> Bool { (number(value) ?? 0) > 2 }

    /// 数字字段（布尔值不算），不是有限的数时是 nil
    private static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let v = n.doubleValue
        return v.isFinite ? v : nil
    }

    /// 秒级时间戳（毫秒的也认）；不在这个窗口说得通的范围里（格式变了）就不用
    static func dateValue(_ value: Any?, now: Date, window: String) -> Date? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        var seconds = number.doubleValue
        guard seconds.isFinite, seconds > 0 else { return nil }
        if seconds > 1e11 { seconds /= 1000 }
        let date = Date(timeIntervalSince1970: seconds)
        let length = window == "five_hour" ? ClaudeProvider.sessionDuration : ClaudeProvider.weekDuration
        // 重置时间在将来，最远一个窗口以后；留 5 分钟的时钟误差
        guard date > now.addingTimeInterval(-300), date <= now.addingTimeInterval(length + 3600) else { return nil }
        return date
    }

    // MARK: - 合并

    /// 桌面端的读数 + 命令行的读数，按时间排序。组织以桌面端最近一次的为准（桌面端没有就用命令行最近一次的），
    /// 对不上的命令行读数不用：命令行登的可能是另一个账号，混进来会让百分比来回跳
    public static func merge(desktop: [PlanUsageSample], cli: [CLIReading]) -> [PlanUsageSample] {
        let org = desktop.last?.org ?? latest(cli)?.org
        let extra = cli.filter { matches($0, org: org) }.compactMap(\.sample)
        guard !extra.isEmpty else { return desktop }
        return (desktop + extra).enumerated()
            .sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }
            .map(\.element)
    }

    private static func latest(_ cli: [CLIReading]) -> CLIReading? { cli.max { $0.time < $1.time } }

    /// 读数是不是这个组织的。已经知道桌面端的组织时，读数里没有组织（命令行没给）就核对不了，不用；
    /// 桌面端的组织也不知道时没法核对，都用
    private static func matches(_ reading: CLIReading, org: String?) -> Bool {
        guard let org else { return true }
        return reading.org == org
    }

    /// 能用的命令行读数（组织对得上的），按时间排序
    public static func usable(_ cli: [CLIReading], desktopOrg: String?) -> [CLIReading] {
        let org = desktopOrg ?? latest(cli)?.org
        return cli.filter { matches($0, org: org) }.sorted { $0.time < $1.time }
    }

    /// 最近一次读数里官方给的重置时间（5 小时、每周）
    public static func latestResets(_ readings: [CLIReading]) -> (session: Date?, weekly: Date?) {
        (readings.last { $0.sessionResetsAt != nil }?.sessionResetsAt,
         readings.last { $0.weeklyResetsAt != nil }?.weeklyResetsAt)
    }
}

/// 命令行读数的记录，存在 ~/Library/Application Support/QuotaPet/cli-readings.jsonl：一行一条，只追加，只保留最近 8 天。
/// 重启之后读数序列不断开（桌面端的读数在它自己的文件里）。只有一个写入方（探测器），读的一方每次按文件修改时间重读。
public final class CLIReadingArchive: @unchecked Sendable {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/QuotaPet/cli-readings.jsonl")
    }

    public let url: URL

    public init(url: URL = CLIReadingArchive.defaultURL) {
        self.url = url
    }

    public var modificationDate: Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// 文件里的读数（按时间排序）。写坏了的行（写到一半）跳过
    public func readings(now: Date = Date()) -> [CLIReading] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return Self.decode(data, keepingAfter: now.addingTimeInterval(-ClaudeCLIReadings.retention), now: now)
    }

    /// 追加一条。文件里有过了保留期的旧行时，整个重写一次（原子替换）。返回是否写成功
    @discardableResult
    public func append(_ reading: CLIReading, now: Date = Date()) -> Bool {
        guard reading.time.timeIntervalSince1970.isFinite, var line = try? Self.encoder.encode(reading) else { return false }
        line.append(0x0A)
        let cutoff = now.addingTimeInterval(-ClaudeCLIReadings.retention)

        // 文件里有过了保留期的行（或写坏的行）：留下没过期的，连同这一条整个重写（原子替换）
        if let data = try? Data(contentsOf: url), !data.isEmpty {
            let kept = Self.decode(data, keepingAfter: cutoff, now: now)
            if kept.count < data.split(separator: 0x0A).count {
                var out = Data()
                for r in kept {
                    guard let encoded = try? Self.encoder.encode(r) else { continue }
                    out.append(encoded)
                    out.append(0x0A)
                }
                out.append(line)
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                return (try? out.write(to: url, options: .atomic)) != nil
            }
        }
        return JSONLFile.append(line, to: url)
    }

    static func decode(_ data: Data, keepingAfter cutoff: Date, now: Date) -> [CLIReading] {
        var byTime: [Int64: CLIReading] = [:]
        for line in data.split(separator: 0x0A) {
            guard let r = try? decoder.decode(CLIReading.self, from: Data(line)),
                  r.time.timeIntervalSince1970.isFinite, r.time > cutoff, r.time <= now.addingTimeInterval(300) else { continue }
            byTime[Int64((r.time.timeIntervalSince1970 * 1000).rounded())] = r
        }
        return byTime.values.sorted { $0.time < $1.time }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()
}

// MARK: - 找命令行、什么时候探测

public enum ClaudeCLI {
    /// 桌面端下载的命令行：~/Library/Application Support/Claude/claude-code/<版本>/<哈希>/claude.app/Contents/MacOS/claude
    public static var desktopRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude/claude-code")
    }

    /// 找一份能用的命令行：先找桌面端自带的（版本最高的），再找常见的安装位置。没有就是 nil
    public static func locate(desktopRoot: URL = ClaudeCLI.desktopRoot,
                              home: URL = FileManager.default.homeDirectoryForCurrentUser,
                              extraCandidates: [String]? = nil) -> URL? {
        let fm = FileManager.default
        let versions = ((try? fm.contentsOfDirectory(atPath: desktopRoot.path)) ?? [])
            .sorted { compareVersions($0, $1) == .orderedDescending }
        for version in versions {
            let dir = desktopRoot.appendingPathComponent(version)
            for hash in ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() {
                let binary = dir.appendingPathComponent(hash).appendingPathComponent("claude.app/Contents/MacOS/claude")
                if isExecutableFile(binary) { return binary }
            }
        }
        let fallbacks = extraCandidates ?? [
            home.appendingPathComponent(".local/bin/claude").path,
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            home.appendingPathComponent(".claude/local/claude").path,
        ]
        return fallbacks.map { URL(fileURLWithPath: $0) }.first(where: isExecutableFile)
    }

    /// 在终端里登录用的命令（路径带空格，用单引号包起来）
    public static func loginCommand(_ binary: URL) -> String {
        "'" + binary.path.replacingOccurrences(of: "'", with: "'\\''") + "' auth login"
    }

    private static func isExecutableFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: url.path)
    }

    /// 按点分的数字比较版本号（2.1.295 > 2.1.30）；不是数字的段按 0
    static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p < q ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}

/// 什么时候让命令行查一次官方读数。每次查都是一个真实请求（占一点额度），而且 5 小时窗口从第一次请求才开始计时，
/// 所以只在「你本来就在用」的时候查：5 小时窗口已经在跑、窗口里有本机用量没被官方读数看到、官方读数也有一阵没来了。
/// 桌面端的后台刷新在正常工作时，官方读数不会旧到这个程度，不会多查。
public enum ClaudeCLIProbePolicy {
    /// 两次自动探测至少隔这么久；失败了按倍数往后退，最多退到 maxBackoff
    public static let interval: TimeInterval = 15 * 60
    public static let maxBackoff: TimeInterval = 2 * 3600
    /// 官方读数旧到这个程度才补：桌面端每 15 分钟一次，多留 2 分钟，别和它撞在一起
    public static let staleAfter: TimeInterval = WindowInference.sampleSpacing + 2 * 60
    /// 手动刷新两次探测之间至少隔这么久
    public static let manualSpacing: TimeInterval = 30

    public static func retryDelay(failures: Int) -> TimeInterval {
        min(interval * pow(2, Double(max(0, min(failures, 6)))), maxBackoff)
    }

    /// - sessionEndsAt：当前 5 小时窗口的结束时间（nil：窗口没在跑）
    /// - officialAt：最近一次官方读数（桌面端或命令行）的时间
    /// - lastActiveAt：本机最近一次 Claude Code 请求的时间
    public static func shouldProbe(now: Date, sessionEndsAt: Date?, officialAt: Date?, lastActiveAt: Date?,
                                   lastAttempt: Date?, failures: Int) -> Bool {
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < retryDelay(failures: failures) { return false }
        guard let end = sessionEndsAt, end > now else { return false }
        guard let active = lastActiveAt, officialAt.map({ active > $0 }) ?? true else { return false }
        if let officialAt, now.timeIntervalSince(officialAt) < staleAfter { return false }
        return true
    }

    /// 手动刷新：用户明确要新读数，不看窗口、用量和读数新旧，只防连点
    public static func shouldProbeManually(now: Date, lastAttempt: Date?) -> Bool {
        lastAttempt.map { now.timeIntervalSince($0) >= manualSpacing } ?? true
    }
}

/// 「用命令行补官方读数」现在是什么状态，设置页上说明用
public enum ClaudeCLIProbeStatus: Equatable, Sendable {
    /// 开着，还没查过
    case idle
    case querying
    case ok(at: Date)
    case failed(at: Date)
    case notFound
    case notLoggedIn
    /// 命令行登录的账号和桌面端不是同一个
    case wrongAccount

    public func text(now: Date) -> String {
        switch self {
        case .idle:
            return tr("已打开：你在用 Claude Code、官方读数又旧了的时候，会自动查一次",
                      "On: checks once when you're using Claude Code and the official reading has gone stale")
        case .querying:
            return tr("正在查询…", "Checking…")
        case .ok(let at):
            return tr("上次查询：\(Fmt.ago(at, now: now))", "Last check: \(Fmt.ago(at, now: now))")
        case .failed(let at):
            return tr("上次查询没成功（\(Fmt.ago(at, now: now))），之后会自动重试",
                      "The last check didn't work (\(Fmt.ago(at, now: now))); it will retry automatically")
        case .notFound:
            return tr("没找到 Claude 命令行（桌面端第一次用 Code 页时会下载）",
                      "Couldn't find the Claude command line (the desktop app downloads it the first time you use the Code tab)")
        case .notLoggedIn:
            return tr("命令行还没用 Claude 账号登录。在终端里运行下面的命令，登录一次：",
                      "The command line isn't signed in with a Claude account. Run this in Terminal to sign in once:")
        case .wrongAccount:
            return tr("命令行登录的账号和桌面端不是同一个，它的读数不会用。先用 auth logout 退出，再登录桌面端用的那个账号",
                      "The command line is signed in to a different account than the desktop app, so its readings aren't used. Run auth logout, then sign in with the desktop app's account")
        }
    }

    /// 要不要给出登录命令
    public var needsLogin: Bool { self == .notLoggedIn || self == .wrongAccount }
}
