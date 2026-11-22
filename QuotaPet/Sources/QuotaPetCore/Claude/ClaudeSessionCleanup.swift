import Foundation

/// QuotaPet 用官方 Claude Code CLI 读 /usage 时，CLI 会在 ~/.claude/projects/<专用目录换算的文件夹>/ 下记一个会话。
/// 查询时用 --session-id 指定这次的会话 ID，清理时只删这个 ID 的会话文件（和同名的子目录）：
/// 同一文件夹里的其他会话（之前留下的、和这次同时开的）不论修改时间多近都保留。认不出归属的文件一律不删
public enum ClaudeSessionCleanup {
    /// 会话 ID 的写法（CLI 用小写 UUID 作文件名）
    public static func idString(_ id: UUID) -> String { id.uuidString.lowercased() }

    /// 删掉这次查询的会话，返回删掉的名字。文件夹名必须是 QuotaPet 专用目录换算出来的、不是符号链接。
    /// 文件夹本身是共享的（别的会话可能随时写进来）：只删这次的文件和同名子目录，文件夹留着，空了也不删——
    /// 「先判空再删」中间有人写进来就会连他的会话一起删掉
    @discardableResult
    public static func remove(sessionID: UUID, workingDirectory: URL, home: URL) -> [String] {
        let fm = FileManager.default
        let name = ClaudeCLILocator.sessionFolderName(for: workingDirectory)
        guard name.hasSuffix("-QuotaPet-ClaudeQuotaCheck") else { return [] }
        let folder = home.appendingPathComponent(".claude/projects/\(name)", isDirectory: true)
        guard folder.resolvingSymlinksInPath().path == folder.path else { return [] }
        let id = idString(sessionID)
        var removed: [String] = []
        for entry in [id + ".jsonl", id] {
            let url = folder.appendingPathComponent(entry)
            guard (try? fm.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType != .typeSymbolicLink,
                  fm.fileExists(atPath: url.path), (try? fm.removeItem(at: url)) != nil else { continue }
            removed.append(entry)
        }
        return removed
    }
}
