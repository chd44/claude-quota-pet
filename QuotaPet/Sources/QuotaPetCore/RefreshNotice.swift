import Foundation

/// 点了刷新之后在面板页脚停留几秒的结果提示：读到了、没读到、或者刚读过要等一会儿
public struct RefreshNotice: Equatable {
    public enum Kind: Equatable { case done, failed, tooSoon }

    public let entry: OfficialQuotaEntry
    public let kind: Kind
    public let text: String
    public let at: Date

    /// 提示停留多久
    public static let duration: TimeInterval = 4

    public init(entry: OfficialQuotaEntry, kind: Kind, text: String, at: Date) {
        self.entry = entry; self.kind = kind; self.text = text; self.at = at
    }

    /// Claude / agy 用官方 CLI 读完：这次点刷新之后读到可用读数才算成功，旧读数、读失败都算没读到
    public static func cliFinished(entry: OfficialQuotaEntry, usable: Bool, checkedAt: Date?, requestedAt: Date,
                                   message: String, now: Date) -> RefreshNotice {
        if usable, let checkedAt, checkedAt >= requestedAt {
            return RefreshNotice(entry: entry, kind: .done, text: tr("已刷新 · 刚读到官方额度", "Refreshed · official usage just read"), at: now)
        }
        let reason = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return RefreshNotice(entry: entry, kind: .failed,
                             text: reason.isEmpty ? tr("没读到新的额度，稍后再试", "No new reading, try again later")
                                                  : tr("没读到新的额度：\(reason)", "No new reading: \(reason)"),
                             at: now)
    }

    /// 离上次开始读不到 30 秒，这次没启动
    public static func tooSoon(entry: OfficialQuotaEntry, wait: TimeInterval?, now: Date) -> RefreshNotice {
        let text: String
        if let wait, wait >= 1 {
            let seconds = Int(wait.rounded(.up))
            text = tr("刚读过，\(seconds) 秒后可以再刷新", "Just read, refresh again in \(seconds) s")
        } else {
            text = tr("现在读不了，稍后再试", "Can’t read right now, try again later")
        }
        return RefreshNotice(entry: entry, kind: .tooSoon, text: text, at: now)
    }

    /// Codex：重新读一遍本机日志（马上完成）。有读数就报读数是什么时候的
    public static func codexReloaded(officialAt: Date?, now: Date) -> RefreshNotice {
        guard let officialAt else {
            return RefreshNotice(entry: .codex, kind: .failed,
                                 text: tr("本机日志里还没有 Codex 的额度读数", "No Codex usage in the local logs yet"), at: now)
        }
        return RefreshNotice(entry: .codex, kind: .done,
                             text: tr("已刷新 · 读数是\(Fmt.ago(officialAt, now: now))的", "Refreshed · reading from \(Fmt.ago(officialAt, now: now))"),
                             at: now)
    }
}
