import Foundation

/// 官方 Claude Code CLI 交互式 `/usage` 面板上的一次读数。
/// 只认「Current session / Current week …」标题下明确写着「NN% used」的块；版式变了就是未知，不推算。
public struct ClaudeUsageReading: Equatable, Codable, Sendable {
    public enum Status: String, Codable, Sendable { case available, unknown, signInRequired, confirmationRequired, unavailable }

    public enum Kind: Equatable, Codable, Sendable {
        case session
        case week
        /// 某一类模型单独的每周额度，比如「Current week (Sonnet only)」里的「Sonnet only」
        case weekModel(String)
    }

    public struct Window: Equatable, Codable, Sendable {
        public let kind: Kind
        public let usedPercent: Double
        /// 面板上「Resets …」换算出的时刻；没有这一行或认不出时是 nil
        public let resetsAt: Date?

        public init(kind: Kind, usedPercent: Double, resetsAt: Date?) {
            self.kind = kind
            self.usedPercent = usedPercent
            self.resetsAt = resetsAt
        }
    }

    public let status: Status
    public let windows: [Window]
    public let checkedAt: Date
    public let message: String

    public init(status: Status, windows: [Window] = [], checkedAt: Date = Date(), message: String = "") {
        self.status = status
        self.windows = windows
        self.checkedAt = checkedAt
        self.message = message
    }

    /// 读数多久内算数：和刷新间隔一样，过了就是未知
    public static var freshFor: TimeInterval { AgyRefreshPolicy.interval }
}

/// CLI 现在停在哪个画面。探测程序只在认得的画面上按键，认不得就放弃
public enum ClaudeCLIScreen: Equatable, Sendable {
    case theme
    case securityNotes
    /// 信任文件夹的确认框；yesSelected：光标已经在「Yes, I trust this folder」上
    case trust(yesSelected: Bool)
    case login
    case prompt
    case usageLoading
    case usageReady
    case unknown

    public static func classify(_ terminal: VirtualTerminal) -> ClaudeCLIScreen {
        let text = terminal.normalizedText
        let lower = text.lowercased()
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        if lower.contains("% used") {
            return lower.contains("refreshing") || lower.contains("loading") ? .usageLoading : .usageReady
        }
        if lower.contains("select login method") || lower.contains("not logged in") || lower.contains("please run /login")
            || lower.contains("oauth token has expired") || lower.contains("invalid api key") {
            return .login
        }
        if lower.contains("trust this folder") {
            let yes = lines.contains { $0.hasPrefix("❯") && $0.lowercased().contains("yes, i trust this folder") }
            return .trust(yesSelected: yes)
        }
        if lower.contains("choose the text style") { return .theme }
        if lower.contains("press enter to continue") { return .securityNotes }
        // 输入框：上下两条横线中间一行以 ❯ 开头
        if lines.contains(where: { $0.hasPrefix("❯") }), lines.contains(where: { $0.hasPrefix("────") }) {
            return .prompt
        }
        return .unknown
    }
}

public enum ClaudeUsageParser {
    /// 从还原好的屏幕里读额度窗口
    public static func parse(_ terminal: VirtualTerminal, now: Date) -> ClaudeUsageReading {
        parse(lines: terminal.lines, now: now)
    }

    public static func parse(lines raw: [String], now: Date) -> ClaudeUsageReading {
        let lines = raw.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var windows: [ClaudeUsageReading.Window] = []
        var index = 0
        while index < lines.count {
            let title = lines[index]
            guard let kind = kind(of: title) else { index += 1; continue }
            var used: Double?
            var reset: Date?
            var cursor = index + 1
            // 标题后面几行里：进度条那一行带「NN% used」，再下面一行是「Resets …」。遇到下一个标题就停
            while cursor < lines.count, cursor <= index + 4, Self.kind(of: lines[cursor]) == nil {
                let line = lines[cursor]
                if used == nil, let match = line.range(of: "([0-9]{1,3}(?:\\.[0-9]+)?)% used", options: .regularExpression) {
                    used = Double(line[match].replacingOccurrences(of: "% used", with: ""))
                } else if used != nil, line.hasPrefix("Resets ") {
                    reset = resetDate(String(line.dropFirst("Resets ".count)), now: now)
                    break
                }
                cursor += 1
            }
            if let used, used.isFinite, (0...100).contains(used), !windows.contains(where: { $0.kind == kind }) {
                windows.append(.init(kind: kind, usedPercent: used, resetsAt: reset))
            }
            index = max(index + 1, cursor)
        }
        guard !windows.isEmpty else {
            return .init(status: .unknown, checkedAt: now, message: tr("未识别官方 /usage 面板", "Official /usage panel not recognised"))
        }
        return .init(status: .available, windows: windows, checkedAt: now)
    }

    static func kind(of title: String) -> ClaudeUsageReading.Kind? {
        if title == "Current session" { return .session }
        if title == "Current week" || title == "Current week (all models)" { return .week }
        if title.hasPrefix("Current week ("), title.hasSuffix(")") {
            let name = String(title.dropFirst("Current week (".count).dropLast())
            return name.isEmpty ? nil : .weekModel(name)
        }
        return nil
    }

    private static let months = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
                                 "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]

    /// 「4:20am (Australia/Sydney)」「Nov 22 at 10am (Australia/Sydney)」「Nov 22, 10am (…)」：按面板写的时区换算。
    /// 只有钟点时取下一次；没有年份时取最近的将来。认不出、或不在合理范围（一周多一点以内）就是 nil
    static func resetDate(_ text: String, now: Date) -> Date? {
        let pattern = "^(?:([A-Za-z]{3})[a-z]* ([0-9]{1,2})(?:,| at|, at) )?([0-9]{1,2})(?::([0-9]{2}))? ?(am|pm) \\(([^)]+)\\)$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func group(_ i: Int) -> String? {
            Range(match.range(at: i), in: text).map { String(text[$0]) }
        }
        guard let zoneName = group(6), let zone = TimeZone(identifier: zoneName),
              let hourText = group(3), var hour = Int(hourText), (1...12).contains(hour),
              let meridiem = group(5)?.lowercased() else { return nil }
        let minute = group(4).flatMap(Int.init) ?? 0
        guard (0...59).contains(minute) else { return nil }
        if hour == 12 { hour = 0 }
        if meridiem == "pm" { hour += 12 }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let today = calendar.dateComponents([.year, .month, .day], from: now)
        var parts = DateComponents(year: today.year, month: today.month, day: today.day, hour: hour, minute: minute)
        var result: Date?
        if let monthName = group(1)?.lowercased().prefix(3), let dayText = group(2) {
            guard let month = months[String(monthName)], let day = Int(dayText), (1...31).contains(day) else { return nil }
            parts.month = month
            parts.day = day
            result = calendar.date(from: parts)
            // 跨年：12 月底看到「Jan 2」
            if let date = result, date < now.addingTimeInterval(-86400) {
                parts.year = (parts.year ?? 0) + 1
                result = calendar.date(from: parts)
            }
        } else {
            result = calendar.date(from: parts)
            if let date = result, date <= now { result = calendar.date(byAdding: .day, value: 1, to: date) }
        }
        guard let date = result, date > now.addingTimeInterval(-300), date <= now.addingTimeInterval(8 * 86400) else { return nil }
        return date
    }
}

extension ClaudeUsageReading {
    /// 有效期内的读数变成面板和菜单栏用的快照。history：之前的读数（只在内存里），用来算按官方读数的消耗速度
    public func snapshot(now: Date, history: [ClaudeUsageReading] = []) -> UsageSnapshot {
        guard status == .available else {
            return UsageSnapshot(provider: .claude, windows: [], generatedAt: now,
                                 notes: message.isEmpty ? [] : [message], hasData: false)
        }
        guard (0..<Self.freshFor).contains(now.timeIntervalSince(checkedAt)) else {
            let ago = Fmt.ago(checkedAt, now: now)
            return UsageSnapshot(provider: .claude, windows: [], generatedAt: now, officialAt: checkedAt,
                                 notes: [tr("上次用官方 CLI 读到额度是\(ago)，超过 15 分钟的读数不当作现在的额度。",
                                            "The last official CLI reading was \(ago); readings older than 15 minutes aren’t treated as current usage.")],
                                 hasData: false)
        }
        let windows = self.windows.map { window -> UsageWindow in
            let (id, title, duration) = Self.describe(window.kind)
            let lookback: TimeInterval = duration > 86400 ? 86400 : 1800
            // 读数之后已经过了重置时间：新窗口还没有用量
            if let reset = window.resetsAt, now >= reset {
                return UsageWindow(id: id, title: title, duration: duration, percent: 0, burnLookback: lookback)
            }
            let start = window.resetsAt?.addingTimeInterval(-duration)
            let series = (history + [self]).compactMap { reading -> UsageSample? in
                guard reading.status == .available, reading.checkedAt <= now,
                      let same = reading.windows.first(where: { $0.kind == window.kind }),
                      Self.sameWindow(same.resetsAt, window.resetsAt) else { return nil }
                return UsageSample(time: reading.checkedAt, value: same.usedPercent)
            }.sorted { $0.time < $1.time }
            return UsageWindow(id: id, title: title, duration: duration, percent: window.usedPercent,
                               official: window.usedPercent, officialAt: checkedAt,
                               startedAt: start, resetsAt: window.resetsAt, scheduleKnown: window.resetsAt != nil,
                               burnPerHour: start.flatMap { CodexProvider.burn(series, windowStart: $0, lookback: lookback, now: now) },
                               burnLookback: lookback)
        }
        return UsageSnapshot(provider: .claude, windows: windows, generatedAt: now, officialAt: checkedAt, notes: [])
    }

    /// 下一次界面要变的时刻：读数过期，或某个窗口到了重置时间
    public func nextChange(after now: Date) -> Date? {
        guard status == .available else { return nil }
        return ([checkedAt.addingTimeInterval(Self.freshFor)] + windows.compactMap(\.resetsAt)).filter { $0 > now }.min()
    }

    static func describe(_ kind: Kind) -> (id: String, title: String, duration: TimeInterval) {
        switch kind {
        case .session: return ("five_hour", UsageWindow.title(minutes: 300), 5 * 3600)
        case .week: return ("seven_day", UsageWindow.title(minutes: 10080), 7 * 86400)
        case .weekModel(let name):
            let slug = name.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "_", options: .regularExpression)
            return ("seven_day_\(slug)", tr("本周 · \(name)", "Weekly · \(name)"), 7 * 86400)
        }
    }

    /// 两次读数属于同一个窗口：重置时间差不多（面板上的钟点可能只到整点）
    static func sameWindow(_ a: Date?, _ b: Date?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return abs(a.timeIntervalSince(b)) < 3600
    }
}

/// 在固定位置找官方 Claude Code CLI，不走 PATH。
public enum ClaudeCLILocator {
    /// 用户自己装的 CLI 常见位置（按顺序）
    public static func installedCandidates(home: URL) -> [URL] {
        [home.appendingPathComponent(".local/bin/claude"), home.appendingPathComponent(".claude/local/claude"),
         URL(fileURLWithPath: "/opt/homebrew/bin/claude"), URL(fileURLWithPath: "/usr/local/bin/claude")]
    }

    /// Claude 桌面端自带的那份：Application Support/Claude/claude-code/<版本>/<校验目录>/claude.app，要有 .verified
    public static func bundledRoot(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/Claude/claude-code", isDirectory: true)
    }

    /// 版本号按数字比较，从新到旧（2.1.326 比 2.1.99 新）；不是纯数字版本号的目录不要
    public static func newestFirst(_ versions: [String]) -> [String] {
        let parsed = versions.compactMap { name -> (String, [Int])? in
            let parts = name.split(separator: ".").map { Int($0) }
            guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
            return (name, parts.map { $0! })
        }
        return parsed.sorted { a, b in
            for (x, y) in zip(a.1, b.1) where x != y { return x > y }
            return a.1.count > b.1.count
        }.map(\.0)
    }

    /// 专用检查目录在 ~/.claude/projects 下对应的会话文件夹名（CLI 把路径里不是字母数字的字符都换成 -）
    public static func sessionFolderName(for directory: URL) -> String {
        directory.path.replacingOccurrences(of: "[^A-Za-z0-9]", with: "-", options: .regularExpression)
    }
}
