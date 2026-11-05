import Foundation

/// 界面上的时间 / 数字格式，跟着界面语言走（见 Localization.swift）
public enum Fmt {
    /// 2 小时 14 分 / 3 天 4 小时 / 8 分钟 / 不到 1 分钟
    /// 2 hr 14 min / 3 days 4 hr / 8 min / under a minute
    public static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        let days = s / 86400, hours = s % 86400 / 3600, minutes = s % 3600 / 60
        if days > 0 {
            return hours > 0 ? tr("\(days) 天 \(hours) 小时", "\(plural(days, "day")) \(hours) hr") : tr("\(days) 天", plural(days, "day"))
        }
        if hours > 0 { return minutes > 0 ? tr("\(hours) 小时 \(minutes) 分", "\(hours) hr \(minutes) min") : tr("\(hours) 小时", "\(hours) hr") }
        if minutes > 0 { return tr("\(minutes) 分钟", "\(minutes) min") }
        return tr("不到 1 分钟", "under a minute")
    }

    /// 多久以后：约 2 小时 14 分后 / 不到 1 分钟后；in about 2 hr 14 min / in under a minute
    public static func fromNow(_ seconds: TimeInterval) -> String {
        let d = duration(seconds)
        return seconds.rounded() < 60 ? tr("\(d)后", "in \(d)") : tr("约 \(d)后", "in about \(d)")
    }

    /// 菜单栏用的紧凑写法（中英一样）：3d4h / 2h05m / 8m
    public static func compactDuration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        let days = s / 86400, hours = s % 86400 / 3600, minutes = s % 3600 / 60
        if days > 0 { return "\(days)d\(hours)h" }
        if hours > 0 { return String(format: "%dh%02dm", hours, minutes) }
        return "\(max(minutes, 1))m"
    }

    /// 15:05 / 明天 09:00 / 周三 17:45 / 昨天 22:10 / 10月2日 17:45
    /// 15:05 / tomorrow 09:00 / Wed 17:45 / yesterday 22:10 / Oct 2 17:45
    public static func clock(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let time = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if let d = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: d) {
            return tr("明天 \(time)", "tomorrow \(time)")
        }
        if let d = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: d) {
            return tr("昨天 \(time)", "yesterday \(time)")
        }
        if date > now, date.timeIntervalSince(now) < 6 * 86400 {
            return "\(weekday(date, calendar: calendar)) \(time)"
        }
        return "\(dateText(date, template: "MMMd", calendar: calendar)) \(time)"
    }

    /// 周三 / Wed
    public static func weekday(_ date: Date, calendar: Calendar = .current) -> String {
        dateText(date, template: "EEE", calendar: calendar)
    }

    /// 周三 / Wed、10月2日 / Oct 2：按界面语言用系统的写法，农历、希伯来历等非公历也对
    private static func dateText(_ date: Date, template: String, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: L10n.language.rawValue)
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }

    /// 刚刚 / 3 分钟前 / 2 小时前 / 3 天前；just now / 3 min ago / 2 hr ago / 3 days ago
    public static func ago(_ date: Date, now: Date) -> String {
        let s = now.timeIntervalSince(date)
        if s < 60 { return tr("刚刚", "just now") }
        if s < 3600 { return tr("\(Int(s / 60)) 分钟前", "\(Int(s / 60)) min ago") }
        if s < 86400 { return tr("\(Int(s / 3600)) 小时前", "\(Int(s / 3600)) hr ago") }
        let days = Int(s / 86400)
        return tr("\(days) 天前", "\(plural(days, "day")) ago")
    }

    /// 四舍五入到整数，但还没到 100 的最多显示 99%：「100%」只留给真用完了的（官方读数、限流消息），
    /// 不然 Codex 的 99.6% 这种读数会显示成 100%，菜单栏却没有恢复倒计时、宠物也没睡
    public static func percent(_ v: Double) -> String {
        let n = Int(v.rounded())
        return "\(v < 100 ? min(n, 99) : n)%"
    }

    public static func usd(_ v: Double) -> String { String(format: "$%.2f", v) }

    public static func tokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1e6) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1e3) }
        return "\(n)"
    }
}

/// 菜单栏上宠物旁边显示什么
public enum MenuBarTextMode: String, CaseIterable, Identifiable, Sendable {
    case petOnly, session, sessionAndWeekly, tightest

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .petOnly: return tr("仅宠物", "Pet only")
        case .session: return tr("5 小时", "5-hour")
        case .sessionAndWeekly: return tr("5h + 周", "5h + week")
        case .tightest: return tr("最紧张", "Highest")
        }
    }
}

public enum MenuBarText {
    /// 返回要显示的文字，以及文字对应的最高使用率（用来决定要不要标橙 / 标红）。
    /// 被限流时不显示百分比，改成显示多久后恢复。
    public static func make(_ snap: UsageSnapshot?, mode: MenuBarTextMode, now: Date) -> (text: String, level: Double) {
        guard let snap, snap.hasData else { return ("", 0) }
        if snap.windows.contains(where: { $0.percent >= 100 }) {
            // 多个窗口都满了，要等最晚恢复的那个
            if let latest = snap.lastToRecover?.resetsAt {
                return (Fmt.compactDuration(latest.timeIntervalSince(now)), 100)
            }
            return ("100%", 100)
        }
        var shown: [UsageWindow]
        switch mode {
        case .petOnly: return ("", 0)
        case .session: shown = [snap.window("five_hour")].compactMap { $0 }
        case .sessionAndWeekly: shown = [snap.window("five_hour"), snap.window("seven_day")].compactMap { $0 }
        case .tightest: shown = [snap.tightest].compactMap { $0 }
        }
        // 这家没有这种窗口（比如 Codex 有的套餐只有每周额度）：显示最紧张的那个
        if shown.isEmpty { shown = [snap.tightest].compactMap { $0 } }
        let text = shown.map { Fmt.percent($0.clampedPercent) }.joined(separator: " · ")
        return (text, shown.map(\.percent).max() ?? 0)
    }
}
