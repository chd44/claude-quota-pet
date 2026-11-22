import Foundation

/// 菜单栏自动跟随「正在用的那家」。
/// - 最近 window（10 分钟）里有动静的算正在用（Claude 看对话写入，Codex 看日志里每轮的用量记录（带不带额度都算），agy 只看两个 conversations 目录里的写入；Claude 和 agy 按 ActivityLedger 认定的真实写入，时间都是写入/记录发生的时间，不是收到通知的时间）
/// - 不光有新动静时判断：面板收起、菜单关上、重新打开跟随开关、各家读数变了，都按现在的状态重新判断一次
/// - 动静分两种：「主动开始」（Codex 新一轮的开始记录；Claude Code 提交提示词时追加的 history.jsonl；新建的 Claude/agy 会话文件）
///   和「接着写」（已有会话里的回复、子任务、后台写日志）
/// - 几家同时在用：跟最近一次「主动开始」的那家（不论多久以前），只要它还在用（10 分钟内有动静，比如长任务还在写用量）；
///   别家接着写的再晚也抢不走，别家新的主动开始才能切过去。这家停下 10 分钟以后，跟最近有动静的那家
///   （刚切过去开始干活的就是你现在在用的；不看哪家额度更紧）
/// - 没有一家在用：不动，留在当前这家
public enum ActiveService {
    public static let window: TimeInterval = 10 * 60
    /// 手动点了页签之后，这么久之内不自动切走
    public static let manualHold: TimeInterval = 10 * 60

    /// 现在正在用的几家，最近有动静的在前；同一时刻的按固定顺序（Claude、Codex、agy），结果不随字典顺序变
    public static func active(_ lastActive: [OfficialQuotaEntry: Date], now: Date) -> [OfficialQuotaEntry] {
        let order = OfficialQuotaEntry.allCases
        return lastActive.filter { now.timeIntervalSince($0.value) >= 0 && now.timeIntervalSince($0.value) < window }
            .sorted { a, b in
                a.value != b.value ? a.value > b.value
                    : (order.firstIndex(of: a.key) ?? 0) < (order.firstIndex(of: b.key) ?? 0)
            }
            .map(\.key)
    }

    /// 该跟哪家：最近 10 分钟里最近有动静的那家，没有一家在用时 nil
    public static func pick(lastActive: [OfficialQuotaEntry: Date], now: Date) -> OfficialQuotaEntry? {
        pick(lastActive: lastActive, lastStart: [:], now: now)
    }

    /// 最近一次主动开始的那家（不论多久以前；同一时刻按固定顺序）
    static func owner(_ lastStart: [OfficialQuotaEntry: Date], now: Date) -> OfficialQuotaEntry? {
        let order = OfficialQuotaEntry.allCases
        return lastStart.filter { $0.value <= now }.max { a, b in
            a.value != b.value ? a.value < b.value : (order.firstIndex(of: a.key) ?? 0) > (order.firstIndex(of: b.key) ?? 0)
        }?.key
    }

    /// 该跟哪家：最近一次主动开始的那家还在用，就跟它；它已经停下（10 分钟没动静）或谁都没主动开始过，跟最近有动静的那家
    public static func pick(lastActive: [OfficialQuotaEntry: Date], lastStart: [OfficialQuotaEntry: Date], now: Date) -> OfficialQuotaEntry? {
        let candidates = active(lastActive, now: now)
        if let owner = owner(lastStart, now: now), candidates.contains(owner) { return owner }
        return candidates.first
    }

    /// 两家排先后用的那个时间：按主动开始选出来时用主动开始的时间，否则用最近的动静
    static func rank(_ entry: OfficialQuotaEntry, lastActive: [OfficialQuotaEntry: Date], lastStart: [OfficialQuotaEntry: Date],
                     now: Date) -> Date? {
        if let owner = owner(lastStart, now: now), active(lastActive, now: now).contains(owner) { return lastStart[entry] }
        return lastActive[entry]
    }

    /// 现在要自动切到哪家：不该切（见 mayFollow）、没有一家在用、或者已经是这家时返回 nil。
    /// paused = 面板或右键菜单开着；manualElapsed = 手动选择后实际过了多久（单调时钟，不受改系统时间影响），没手动选过时 nil
    public static func target(enabled: Bool, paused: Bool, manualElapsed: TimeInterval?, lastActive: [OfficialQuotaEntry: Date],
                              lastStart: [OfficialQuotaEntry: Date] = [:], current: OfficialQuotaEntry, now: Date) -> OfficialQuotaEntry? {
        guard mayFollow(enabled: enabled, panelOpen: paused, manualElapsed: manualElapsed),
              let next = pick(lastActive: lastActive, lastStart: lastStart, now: now), next != current,
              // 同一时刻：留在当前这家，不来回跳
              rank(current, lastActive: lastActive, lastStart: lastStart, now: now)
                != rank(next, lastActive: lastActive, lastStart: lastStart, now: now)
        else { return nil }
        return next
    }

    /// 现在该不该自动切：开关开着、面板没开着、手动选择后已经过了 manualHold（按实际经过的时间算）
    public static func mayFollow(enabled: Bool, panelOpen: Bool, manualElapsed: TimeInterval?) -> Bool {
        guard enabled, !panelOpen else { return false }
        guard let manualElapsed else { return true }
        return manualElapsed >= manualHold
    }

    /// 用两个日期表示手动选择的时间（自检、演示用）。App 里用单调时钟（见上面两个），系统时间往回拨或往前跳不影响保护期
    public static func target(enabled: Bool, paused: Bool, manualAt: Date?, lastActive: [OfficialQuotaEntry: Date],
                              lastStart: [OfficialQuotaEntry: Date] = [:], current: OfficialQuotaEntry, now: Date) -> OfficialQuotaEntry? {
        target(enabled: enabled, paused: paused, manualElapsed: manualAt.map { now.timeIntervalSince($0) },
               lastActive: lastActive, lastStart: lastStart, current: current, now: now)
    }

    public static func mayFollow(enabled: Bool, panelOpen: Bool, manualAt: Date?, now: Date) -> Bool {
        mayFollow(enabled: enabled, panelOpen: panelOpen, manualElapsed: manualAt.map { now.timeIntervalSince($0) })
    }
}
