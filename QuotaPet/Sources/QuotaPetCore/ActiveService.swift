import Foundation

/// 菜单栏自动跟随「正在用的那家」。
/// - 最近 window（10 分钟）里有动静的算正在用（Claude 看对话写入，Codex 看每轮新读数，agy 看对话目录写入）
/// - 只有一家：跟它；几家同时在用：跟用得最紧的（百分比最高），一样紧时跟最近有动静的
/// - 没有一家在用：不动，留在当前这家
public enum ActiveService {
    public static let window: TimeInterval = 10 * 60
    /// 手动点了页签之后，这么久之内不自动切走
    public static let manualHold: TimeInterval = 10 * 60

    /// 现在正在用的几家，最近有动静的在前
    public static func active(_ lastActive: [OfficialQuotaEntry: Date], now: Date) -> [OfficialQuotaEntry] {
        lastActive.filter { now.timeIntervalSince($0.value) >= 0 && now.timeIntervalSince($0.value) < window }
            .sorted { $0.value > $1.value }
            .map(\.key)
    }

    public static func pick(lastActive: [OfficialQuotaEntry: Date], used: [OfficialQuotaEntry: Double], now: Date) -> OfficialQuotaEntry? {
        let candidates = active(lastActive, now: now)
        guard candidates.count > 1 else { return candidates.first }
        // 几家同时在用：跟最需要盯着的那家；没有读数的排在后面；一样紧时保持「最近有动静」的顺序
        return candidates.enumerated().max { a, b in
            let ua = used[a.element] ?? -1, ub = used[b.element] ?? -1
            return ua != ub ? ua < ub : a.offset > b.offset
        }?.element
    }

    /// 现在该不该自动切：开关开着、面板没开着、手动选择的保持期已过
    public static func mayFollow(enabled: Bool, panelOpen: Bool, manualAt: Date?, now: Date) -> Bool {
        guard enabled, !panelOpen else { return false }
        guard let manualAt else { return true }
        return now.timeIntervalSince(manualAt) >= manualHold
    }
}
