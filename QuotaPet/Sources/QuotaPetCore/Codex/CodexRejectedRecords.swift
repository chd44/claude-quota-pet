import Foundation

/// Codex 日志里已经判定无效的「未来」记录（系统时间往回拨之前、或时钟偏差写下的）：按「会话文件名的指纹 + 记录时间」逐条记住，
/// 同一文件重扫（改了修改时间、原子替换）、QuotaPet 重启后冷扫描都不再把同一条读回来。
/// 只存指纹和时间，不存路径、不存内容。逐条记而不是按文件记一个时间阈值：回拨后这个会话真正新写的记录照常算。
/// 有上限：最多 limit 条；记录时间早于现在 retention 以上的丢掉（真实时间早已越过它）
public final class CodexRejectedRecords: @unchecked Sendable {
    public static let limit = 512
    public static let retention: TimeInterval = 7 * 86400

    private let lock = NSLock()
    private var entries: [String: Double]
    /// 写回在加锁之外调用；App 里写 UserDefaults（它本身可以跨线程用）
    private let save: ([String: Double]) -> Void

    /// stored：上次存下的（键是指纹和时间，值是记录时间）；save：有变化时写回（App 里写进本机设置）
    public init(stored: [String: Double] = [:], save: @escaping ([String: Double]) -> Void = { _ in }) {
        entries = stored.filter { $0.value.isFinite }
        self.save = save
    }

    /// 会话文件名的指纹（FNV-1a，跨进程稳定）：会话从 sessions 挪到 archived_sessions 文件名不变，仍认得出
    static func fileKey(_ path: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in (path as NSString).lastPathComponent.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return String(hash, radix: 16)
    }

    private static func key(_ file: String, _ time: Date) -> String {
        "\(fileKey(file))|\(Int64((time.timeIntervalSince1970 * 1000).rounded()))"
    }

    public func contains(file: String, time: Date) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return entries[Self.key(file, time)] != nil
    }

    public func insert(file: String, time: Date, now: Date) {
        lock.lock()
        let key = Self.key(file, time)
        guard entries[key] == nil else { lock.unlock(); return }
        entries[key] = time.timeIntervalSince1970
        let floor = now.addingTimeInterval(-Self.retention).timeIntervalSince1970
        entries = entries.filter { $0.value >= floor }
        if entries.count > Self.limit {
            // 超出上限：先丢记录时间最早的（真实时间最先越过它们）
            for (old, _) in entries.sorted(by: { $0.value < $1.value }).prefix(entries.count - Self.limit) { entries[old] = nil }
        }
        let snapshot = entries
        lock.unlock()
        save(snapshot)
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }
}
