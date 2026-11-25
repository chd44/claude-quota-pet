import Foundation

public struct AgyQuotaReading: Codable, Sendable {
    public enum Status: String, Codable, Sendable { case available, unknown, signInRequired, confirmationRequired, unavailable }
    /// One explicitly labelled remaining-percentage row of the official panel, in panel order.
    public struct Window: Equatable, Codable, Sendable {
        public let group: String
        /// "每周" or "五小时", as labelled by the official panel.
        public let window: String
        public let remainingPercent: Double
        public let resetsAt: Date?
        public init(group: String, window: String, remainingPercent: Double, resetsAt: Date? = nil) {
            self.group = group; self.window = window; self.remainingPercent = remainingPercent; self.resetsAt = resetsAt
        }
    }
    public let status: Status
    public let remainingPercent: Double?
    public let groupName: String?
    public let groupTitle: String?
    public let windowTitle: String?
    public let resetsAt: Date?
    public let checkedAt: Date
    public let message: String
    /// Every window the official panel listed; the tightest fields above summarise these.
    public let windows: [Window]
    public init(status: Status, remainingPercent: Double? = nil, groupName: String? = nil, checkedAt: Date = Date(), message: String = "", groupTitle: String? = nil, windowTitle: String? = nil, resetsAt: Date? = nil, windows: [Window] = []) {
        self.status = status; self.remainingPercent = remainingPercent; self.groupName = groupName
        self.checkedAt = checkedAt; self.message = message
        self.groupTitle = groupTitle; self.windowTitle = windowTitle; self.resetsAt = resetsAt
        self.windows = windows
    }
}

/// Only accepts an explicitly labelled remaining percentage column. A changed or
/// unrecognised official terminal layout is unknown, never zero or an estimate.
public enum AgyQuotaParser {
    static let signInMarkers = ["not signed in", "sign in to", "log in to", "select login method", "not logged in", "please run /login"]
    static let startupLoginMarkers = ["select login method", "please sign in", "sign in to", "log in to", "please run /login", "not logged in"]
    static let confirmMarkers = ["do you trust", "enter confirm", "permission required"]

    /// 启动阶段（还没发 /usage）就已经明确停在登录交互界面（不含启动横幅里瞬时的 "You are currently not signed in"）
    public static func startupSignInRequired(_ terminal: VirtualTerminal) -> Bool {
        let lower = terminal.normalizedText.lowercased()
        return startupLoginMarkers.contains { lower.contains($0) }
    }

    /// 屏幕上带登录或确认提示的去重标准化行集合
    public static func noticeSet(_ terminal: VirtualTerminal) -> Set<String> {
        Set(terminal.lines.compactMap { line -> String? in
            let normalized = line.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
                .lowercased()
            guard !normalized.isEmpty else { return nil }
            return (signInMarkers + confirmMarkers).contains { normalized.contains($0) } ? normalized : nil
        })
    }

    /// 发出 /usage 之后的这次解析能不能当最终结果。读到额度就算；「要登录」「要确认」只有在发命令之后
    /// 屏幕上出现了此前没有的新提示内容才算：既不受启动横幅重画多出一份的影响，也能在横幅被清掉、换出真正登录提示时立即认出
    public static func settles(_ reading: AgyQuotaReading, notices: Set<String>, baseline: Set<String>) -> Bool {
        switch reading.status {
        case .available: return true
        case .signInRequired, .confirmationRequired: return !notices.subtracting(baseline).isEmpty
        case .unknown, .unavailable: return false
        }
    }

    /// 从还原好的终端屏幕解析：只看现在显示的这一屏（局部重画、清屏后的旧帧不算）
    public static func parse(terminal: VirtualTerminal, now: Date = Date()) -> AgyQuotaReading {
        parse(terminal.lines.joined(separator: "\n"), now: now)
    }

    public static func parse(_ output: String, now: Date = Date()) -> AgyQuotaReading {
        let plain = output
            .replacingOccurrences(of: "\u{1B}\\][^\\u0007]*(?:\\u0007|\u{1B}\\\\)", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{1B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        let lower = plain.lowercased()
        // 额度面板在屏幕上就以面板为准：agy 启动横幅里即使已登录也会写「You are currently not signed in」，
        // 还原整屏后它会留在面板上方，不能因此判成未登录
        let hasPanel = lower.contains("quota") && lower.contains("within each group") && lower.contains("5-hour limit")
        if !hasPanel {
            if signInMarkers.contains(where: { lower.contains($0) }) {
                return .init(status: .signInRequired, checkedAt: now, message: "请先在官方 agy CLI 登录")
            }
            if confirmMarkers.contains(where: { lower.contains($0) }) {
                return .init(status: .confirmationRequired, checkedAt: now, message: "官方 CLI 需要交互确认")
            }
            return .init(status: .unknown, checkedAt: now, message: "未识别官方额度面板")
        }
        var group: String?
        var window: String?
        var candidates: [(Double, String, String, Date?)] = []
        var unpairedPercent = false
        for line in plain.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = trimmed.lowercased()
            if text == "gemini models" { group = "Gemini"; window = nil }
            else if text == "claude and gpt models" { group = "Claude / GPT"; window = nil }
            // agy 1.5.15 起 Argon 并入 GEMINI MODELS 组（只在「Models within this group」里列名，不单独计额度）；
            // 下面两条只为还没更新的旧版 CLI 保留它单独的每周窗口
            else if text.contains("argon") && trimmed == trimmed.uppercased() { group = "Gemini Argon"; window = nil }
            else if trimmed == trimmed.uppercased(), trimmed.range(of: "[A-Z]", options: .regularExpression) != nil { group = nil; window = nil }
            if text == "gemini 4 argon weekly limit" { group = "Gemini Argon"; window = "每周" }
            if text.hasPrefix("refreshes in "), !candidates.isEmpty {
                let parts = text.replacingOccurrences(of: "refreshes in ", with: "").split(separator: " ")
                var seconds: Double = 0
                var valid = !parts.isEmpty
                for part in parts {
                    guard let suffix = part.last, let number = Double(part.dropLast()), number >= 0 else { valid = false; break }
                    switch suffix { case "d": seconds += number * 86400; case "h": seconds += number * 3600; case "m": seconds += number * 60; case "s": seconds += number; default: valid = false }
                }
                if valid { candidates[candidates.count - 1].3 = now.addingTimeInterval(seconds) }
            }
            if text == "weekly limit remaining" { window = "每周" }
            else if text == "five hour limit remaining" { window = "五小时" }
            guard trimmed.contains("%") else { continue }
            // Only the bar line immediately following an explicit remaining label.
            guard let group, let label = window,
                  let range = trimmed.range(of: "[0-9]+(?:\\.[0-9]+)?%$", options: .regularExpression),
                  trimmed.hasPrefix("["),
                  let value = Double(trimmed[range].dropLast()), value.isFinite, (0...100).contains(value) else {
                unpairedPercent = true; continue
            }
            candidates.append((value, group, label, nil)); window = nil
        }
        let required = Set(["Gemini · 每周", "Gemini · 五小时", "Claude / GPT · 每周", "Claude / GPT · 五小时"])
        let received = Set(candidates.map { $0.1 + " · " + $0.2 })
        guard required.isSubset(of: received), !unpairedPercent, let tightest = candidates.min(by: { $0.0 < $1.0 }) else {
            return .init(status: .unknown, checkedAt: now, message: "官方额度格式未确认，未推算百分比")
        }
        return .init(status: .available, remainingPercent: tightest.0, groupName: tightest.1 + " · " + tightest.2, checkedAt: now, message: "官方 CLI 剩余额度", groupTitle: tightest.1, windowTitle: tightest.2, resetsAt: tightest.3,
                     windows: candidates.map { AgyQuotaReading.Window(group: $0.1, window: $0.2, remainingPercent: $0.0, resetsAt: $0.3) })
    }
}
