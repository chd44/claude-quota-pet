import Foundation

/// 一个文件此刻的元数据：编号（inode）、大小、内容修改时间、内容代号、创建时间。用来判断「内容真的变了」「是不是新建的」，不读内容
public struct FileStamp: Equatable, Sendable {
    public var inode: UInt64
    public var size: UInt64
    public var modified: Date
    /// 系统给的内容代号（generation identifier，APFS 上有）：写入、替换内容时会变；只改修改时间（touch）、权限、扩展属性时不变。
    /// 取不到时 nil，退回按修改时间判断
    public var generation: Data?
    /// 文件的创建时间（判断「新开的会话」用）；取不到时 nil
    public var created: Date?

    public init(inode: UInt64, size: UInt64, modified: Date, generation: Data? = nil, created: Date? = nil) {
        self.inode = inode
        self.size = size
        self.modified = modified
        self.generation = generation
        self.created = created
    }

    /// 读真实文件的元数据（不跟符号链接）；不存在、不是普通文件时 nil
    public static func of(path: String) -> FileStamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        let generation = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.generationIdentifierKey]))?
            .generationIdentifier as? Data
        return FileStamp(inode: inode, size: size, modified: modified, generation: generation,
                         created: attributes[.creationDate] as? Date)
    }

    /// 内容变没变：编号（替换）或大小变了算变；两边都有内容代号时看代号；取不到代号时退回看修改时间
    public func contentDiffers(from old: FileStamp) -> Bool {
        if inode != old.inode || size != old.size { return true }
        if let generation, let previous = old.generation { return generation != previous }
        return modified != old.modified
    }

    /// 目录下面的全部普通文件（递归，最多 limit 个），只列路径
    public static func files(in directory: URL, limit: Int = 20_000) -> [String] {
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var result: [String] = []
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            result.append(url.path)
            if result.count >= limit { break }
        }
        return result
    }

    /// 目录下面 since 以后改过的普通文件和它们的元数据（递归，不设上限）。
    /// 先用目录枚举时预取的修改时间筛，只对筛出来的取完整元数据：大目录里也不会漏掉最新的文件，又不用逐个取元数据
    public static func recentFiles(in directory: URL, since: Date) -> [(path: String, stamp: FileStamp)] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return [] }
        var result: [(path: String, stamp: FileStamp)] = []
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let modified = values.contentModificationDate, modified >= since,
                  let stamp = of(path: url.path) else { continue }
            result.append((url.path, stamp))
        }
        return result
    }
}

/// 一家服务的会话文件在哪：监听哪些根目录、整体核对哪些目录、哪些路径算会话文件、哪些写入算「用户主动开始」（只看路径）
public struct ActivitySource: Sendable {
    /// 交给 FSEvents 的根目录（存在的才监听；后来才出现的，下次重试时接上）
    public var roots: [URL]
    /// 接上监听、或者事件丢了要重新核对时，列出来比对元数据的目录
    public var scanDirectories: [URL]
    public var isSessionFile: @Sendable (String) -> Bool
    /// 这个文件有新内容 = 用户主动开始了一轮（Claude Code 每次提交提示词都追加的 ~/.claude/history.jsonl）
    public var isStartFile: @Sendable (String) -> Bool
    /// 这个路径上新建出来的文件 = 用户开了一个新会话（子任务、子代理的文件不算）
    public var isNewSessionCandidate: @Sendable (String) -> Bool
    /// 整体核对时除了目录，还要单独核对的文件（Claude 的 history.jsonl 不在 projects 里）
    public var scanFiles: [URL]
    /// agy：读步骤记录（transcript.jsonl）认用户自己发的消息的根目录；其他家为空
    public var transcriptRoots: [URL] = []

    public init(roots: [URL], scanDirectories: [URL], isSessionFile: @escaping @Sendable (String) -> Bool,
                isStartFile: @escaping @Sendable (String) -> Bool = { _ in false },
                isNewSessionCandidate: @escaping @Sendable (String) -> Bool = { _ in false }, scanFiles: [URL] = []) {
        self.roots = roots
        self.scanDirectories = scanDirectories
        self.isSessionFile = isSessionFile
        self.isStartFile = isStartFile
        self.isNewSessionCandidate = isNewSessionCandidate
        self.scanFiles = scanFiles
    }

    /// 此刻要交给 FSEvents 的路径：存在的根目录；会话目录是指向根目录外面的符号链接时，再加上它此刻指向的目录
    /// （FSEvents 不跟着符号链接走）。只加会话目录本身指向的地方，不扩大到别的目录
    public func watchPaths() -> [String] {
        let fm = FileManager.default
        var paths = roots.map(\.path).filter { fm.fileExists(atPath: $0) }
        for directory in scanDirectories {
            let target = directory.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard comparablePath(target.path) != comparablePath(directory.path),
                  fm.fileExists(atPath: target.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  !paths.contains(where: { comparablePath(target.path) == comparablePath($0) || isPath(target.path, inside: URL(fileURLWithPath: $0)) })
            else { continue }
            paths.append(target.path)
        }
        return paths
    }

    /// 整体核对时实际列的目录和文件：会话目录是符号链接时列它指向的地方；再加上单独核对的文件（Claude 的 history.jsonl）
    public var scanTargets: [URL] { scanDirectories.map { $0.resolvingSymlinksInPath() } + scanFiles }

    /// Claude Code：~/.claude/projects 里的 .jsonl，加上 ~/.claude/history.jsonl（每次提交提示词追加一行，只看它变没变，不读内容）。
    /// QuotaPet 自己查额度用的专用目录不算：按完整的文件夹名比（ownFolders 是专用目录换算出的名字，解析符号链接前后各一个）。
    /// 主动开始：history.jsonl 有新内容，或者 projects/<项目>/ 下直接新建了一个会话 .jsonl（更深的 subagents 等子任务文件不算）
    public static func claude(home: URL, ownFolder: String) -> ActivitySource {
        claude(home: home, ownFolders: [ownFolder])
    }

    public static func claude(home: URL, ownFolders: [String]) -> ActivitySource {
        let root = home.appendingPathComponent(".claude", isDirectory: true)
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        let historyURL = root.appendingPathComponent("history.jsonl")
        let history = comparablePath(historyURL.path)
        let own = Set(ownFolders)
        let sessionParts: @Sendable (String) -> [Substring]? = { file in
            guard file.hasSuffix(".jsonl"), let relative = relativePath(file, inside: projects) else { return nil }
            let parts = relative.split(separator: "/")
            return own.contains(String(parts.first ?? "")) ? nil : parts
        }
        return ActivitySource(roots: [root], scanDirectories: [projects],
                              isSessionFile: { comparablePath($0) == history || sessionParts($0) != nil },
                              isStartFile: { comparablePath($0) == history },
                              isNewSessionCandidate: { sessionParts($0)?.count == 2 }, scanFiles: [historyURL])
    }

    /// agy：CLI 和桌面端各自的 conversations 目录里的文件（没有扩展名的也算）。
    /// 插件、技能、缓存、bin、日志等维护目录不算；conversations 里名字以 . 开头的（.DS_Store 这类系统文件、隐藏的临时文件）也不算。
    /// 监听两个数据目录本身，conversations 后来才建也收得到。主动开始：conversations 里新建了文件（新会话），
    /// 或者会话步骤记录里出现了用户自己发的消息（AgyTranscript，回到原会话续聊靠它认出来；会话文件本身的变化和后台回复一样）
    public static func agy(home: URL) -> ActivitySource {
        let roots = [home.appendingPathComponent(".gemini/antigravity-cli", isDirectory: true),
                     home.appendingPathComponent(".gemini/antigravity", isDirectory: true)]
        let conversations = roots.map { $0.appendingPathComponent("conversations", isDirectory: true) }
        let session: @Sendable (String) -> Bool = { file in
            conversations.contains { directory in
                guard let relative = relativePath(file, inside: directory) else { return false }
                return !relative.split(separator: "/").contains { $0.hasPrefix(".") }
            }
        }
        var source = ActivitySource(roots: roots, scanDirectories: conversations, isSessionFile: session, isNewSessionCandidate: session)
        source.transcriptRoots = roots
        return source
    }
}

/// 一次核对找到的真实写入：time 是最近一次写入的时间；start 是其中最近一次「用户主动开始」的时间（没有就 nil）
public struct ActivityFinding: Equatable, Sendable {
    public var time: Date
    public var start: Date?

    public init(time: Date, start: Date? = nil) {
        self.time = time
        self.start = start
    }

    static func merge(_ items: [ActivityFinding?]) -> ActivityFinding? {
        let found = items.compactMap { $0 }
        guard let time = found.map(\.time).max() else { return nil }
        return ActivityFinding(time: time, start: found.compactMap(\.start).max())
    }
}

/// 后台核对的结果：列出来的会话文件和元数据，以及开始核对时账本的版本号（提交时丢掉这期间已经被实时更新过的文件）。
/// 路径的统一写法、是不是会话开头这些要碰文件系统的判断都在后台算好，主线程提交时只做字典操作
public struct ActivityScan: RandomAccessCollection, Sendable {
    public struct Entry: Sendable {
        public var path: String
        public var stamp: FileStamp
        let key: String
        let startFile: Bool
        let newCandidate: Bool
    }
    public let entries: [Entry]
    let epoch: UInt64
    /// 基线核对用：在这之后出生的文件不进基线
    var bornAfter: Date?

    public var startIndex: Int { entries.startIndex }
    public var endIndex: Int { entries.endIndex }
    public subscript(position: Int) -> Entry { entries[position] }
}

/// 判断文件事件是不是一次真实写入：只认会话文件，而且这个文件的内容此刻和上次见到的不一样
/// （编号、大小、内容代号；取不到内容代号时看修改时间）。不读内容。
/// - 改权限、改扩展属性、只改修改时间（touch，有内容代号时）、建子目录、删除、移走、重复送来的同一批通知：不算
/// - 第一次见到的文件只收到「属性变了」的通知（touch、chmod）：记下来当基线，不算
/// - 同一个文件只改名字（编号和内容都没变）：不算
/// - 新建、追加、等长改写、原子替换：算；整个目录移进来时核对里面的文件
/// 活动时间用文件的内容修改时间（写入真正发生的时间），不用收到通知的时间。
/// 太旧（早于 now − window）或在未来（晚于 now，复制、还原、时钟偏差留下的）的不算现在在用，也不会等时间追上后再冒出来。
/// 目录核对（collect、baseline）只读元数据，可以在后台线程跑；账本本身（apply、observe）只在一个线程上用
public final class ActivityLedger: @unchecked Sendable {
    /// 修改时间比现在晚多少以内还算正常：只留文件系统时间精度的余量。再晚的当成时钟偏差，不算
    public static let futureTolerance: TimeInterval = 0.01
    /// 核对「最近一次主动开始」往回看多久。和「现在是否在用」（window）分开：QuotaPet 没运行时提交的提示词
    /// 可能早于 window，这家却一直在用，开始时间仍要恢复（只在同一次核对里这家确实在用时才算）
    public static let startLookback: TimeInterval = 24 * 3600

    public let source: ActivitySource
    public let window: TimeInterval
    /// nil = 读真实文件（目录核对走预取修改时间的快速路径）
    let customStamp: ((String) -> FileStamp?)?
    let customList: ((URL) -> [String])?

    private struct Known { var stamp: FileStamp; var epoch: UInt64 }
    /// 见过的会话文件（键是统一写法的路径）、按编号反查的路径（认改名）、刚消失的文件（改名时新旧通知谁先到都不一定）
    private var known: [String: Known] = [:]
    private var byInode: [UInt64: String] = [:]
    private var departed: [UInt64: FileStamp] = [:]
    /// 删掉或移走时的版本号：比这更早开始的后台核对不能把它加回来
    private var removedAt: [String: UInt64] = [:]
    /// 账本的版本号：每改一次加一。后台核对开始时记下它
    private var epoch: UInt64 = 0
    private let epochLock = NSLock()
    /// 第一次核对（开始监听）的时间：在这之后才出生的文件不进基线，留给实时事件或补扫报一次「新建」
    private var watchingSince: Date?
    /// 最近一次 applyFinding / observeFinding 里，有没有会话文件（不算 history.jsonl 这类开始记录文件）的真实写入。
    /// QuotaPet 自己查额度时 CLI 只会动开始记录文件：它不能当成「这家确实在用」的证据（只在账本所在的线程上读）
    public private(set) var lastFindingHadSessionWrite = false

    public init(source: ActivitySource, window: TimeInterval,
                stamp: ((String) -> FileStamp?)? = nil, list: ((URL) -> [String])? = nil) {
        self.source = source
        self.window = window
        customStamp = stamp
        customList = list
    }

    private func stamp(_ path: String) -> FileStamp? { customStamp.map { $0(path) } ?? FileStamp.of(path: path) }

    /// 开始记录文件（history.jsonl）此刻的内容修改时间：启动时、QuotaPet 第一次自己查额度之前取一次，
    /// 那次查询改写它之前，离线期间用户最后一次提交提示词的时间还在。只读元数据，不动账本
    public func startFileTimes() -> [Date] {
        source.scanFiles.filter { source.isStartFile($0.path) }.compactMap { stamp($0.path)?.modified }
    }

    private var currentEpoch: UInt64 {
        epochLock.lock(); defer { epochLock.unlock() }
        return epoch
    }

    /// 记下第一次核对的时间（后台线程也可能调用），返回它
    private func markWatching(_ now: Date) -> Date {
        epochLock.lock(); defer { epochLock.unlock() }
        if watchingSince == nil { watchingSince = now }
        return watchingSince!
    }

    private func bump() -> UInt64 {
        epochLock.lock(); defer { epochLock.unlock() }
        epoch += 1
        return epoch
    }

    /// 把一批事件分成：要直接核对的文件（带着事件标志）、要整棵核对的目录（新建或改名移进来的子目录）、要不要把会话目录整体重新核对一遍
    public func split(_ events: [FileEvent]) -> (files: [FileEvent], trees: [URL], full: Bool) {
        var files: [FileEvent] = [], trees: [URL] = [], full = false
        for event in events {
            if event.flags.needsRescan { full = true; continue }
            // 先看是不是会话目录里的子目录（新建或整个移进来）：Claude 的会话文件要求 .jsonl 结尾，目录本身过不了那一关。
            // 子目录里的文件在核对时再按会话文件筛（QuotaPet 自己的专用目录、隐藏文件照样排除）
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: event.path, isDirectory: &isDirectory), isDirectory.boolValue {
                if source.scanDirectories.contains(where: { isPath(event.path, inside: $0) }) {
                    trees.append(URL(fileURLWithPath: event.path, isDirectory: true))
                }
                continue
            }
            guard source.isSessionFile(event.path) else { continue }
            files.append(event)
        }
        return (files, trees, full)
    }

    /// 列出这些目录里 now − window 以后改过的会话文件和元数据。只读元数据、不动账本，可以在后台线程调用
    public func collect(_ directories: [URL], now: Date) -> ActivityScan {
        let epoch = currentEpoch
        _ = markWatching(now)
        let since = now.addingTimeInterval(-window)
        let (folders, files) = splitTargets(directories)
        var found: [(path: String, stamp: FileStamp)]
        if customStamp == nil, customList == nil {
            found = folders.flatMap { FileStamp.recentFiles(in: $0, since: since) }
        } else {
            let list = customList ?? { FileStamp.files(in: $0, limit: .max) }
            found = folders.flatMap(list).compactMap { path in stamp(path).map { (path, $0) } }
        }
        let startSince = now.addingTimeInterval(-Self.startLookback)
        found += files.compactMap { file in
            stamp(file.path).flatMap { $0.modified >= (source.isStartFile(file.path) ? startSince : since) ? (file.path, $0) : nil }
        }
        return scan(found, epoch: epoch)
    }

    /// 列出会话目录里的全部会话文件（不论新旧，最多 limit 个）当基线：之后第一次见到的旧文件只改了属性也认得出。只读元数据，可以在后台调用
    public func collectBaseline(now: Date, limit: Int = 50_000) -> ActivityScan {
        let epoch = currentEpoch
        let since = markWatching(now)
        let (folders, files) = splitTargets(source.scanTargets)
        let paths = (customList.map { list in folders.flatMap(list) } ?? folders.flatMap { FileStamp.files(in: $0, limit: limit) })
            + files.map(\.path)
        var result = scan(paths.prefix(limit).compactMap { path in stamp(path).map { (path, $0) } }, epoch: epoch)
        result.bornAfter = since
        return result
    }

    /// 核对目标分成目录和单个文件（单个文件不存在时也算文件）
    private func splitTargets(_ targets: [URL]) -> (folders: [URL], files: [URL]) {
        var folders: [URL] = [], files: [URL] = []
        for target in targets {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory), isDirectory.boolValue {
                folders.append(target)
            } else if customList != nil, source.scanFiles.isEmpty || !source.scanFiles.contains(target) {
                folders.append(target)  // 自检里编的目录：交给注入的列表
            } else {
                files.append(target)
            }
        }
        return (folders, files)
    }

    private func scan(_ found: [(path: String, stamp: FileStamp)], epoch: UInt64) -> ActivityScan {
        ActivityScan(entries: found.filter { source.isSessionFile($0.path) }.map {
            ActivityScan.Entry(path: $0.path, stamp: $0.stamp, key: comparablePath($0.path),
                               startFile: source.isStartFile($0.path), newCandidate: source.isNewSessionCandidate($0.path))
        }, epoch: epoch)
    }

    /// 把 collect 的结果记进账本，返回其中最近一次真实写入的时间（没见过、或者内容变了的文件）。
    /// 核对开始以后已经被实时事件更新过（或删掉）的文件跳过：后台的旧版本不能盖掉新版本，也不再报一次活动
    public func apply(_ scan: ActivityScan, now: Date) -> Date? { applyFinding(scan, now: now)?.time }

    public func applyFinding(_ scan: ActivityScan, now: Date) -> ActivityFinding? {
        // 早于 window 的开始记录（history.jsonl 第一次见到、或内容变了）：不算「现在在用」，
        // 但这一家在这次核对里确实在用时，它就是这家最近一次主动开始
        var lateStarts: [Date] = []
        var sessionWrite = false
        let found = ActivityFinding.merge(scan.entries.map { entry in
            guard !updatedSince(entry.key, scan.epoch) else { return nil }
            let changed = entry.startFile && (known[entry.key].map { entry.stamp.contentDiffers(from: $0.stamp) } ?? true)
            let result = check(key: entry.key, path: entry.path, current: entry.stamp, flags: [], now: now,
                               startFile: entry.startFile, newCandidate: entry.newCandidate)
            if result == nil, changed, entry.stamp.modified < now.addingTimeInterval(-window),
               entry.stamp.modified >= now.addingTimeInterval(-Self.startLookback) {
                lateStarts.append(entry.stamp.modified)
            }
            if result != nil, !entry.startFile { sessionWrite = true }
            return result
        })
        lastFindingHadSessionWrite = sessionWrite
        guard var found else { return nil }
        if let late = lateStarts.max(), found.start.map({ late > $0 }) ?? true { found.start = late }
        return found
    }

    /// 只记基线：没见过的文件记下来，不算活动；已经见过、或核对开始后被实时更新过的不动
    public func applyBaseline(_ scan: ActivityScan) {
        for entry in scan.entries where known[entry.key] == nil && !updatedSince(entry.key, scan.epoch) {
            // 开始监听以后才出生的文件（新会话）：不当基线吞掉，留给它的新建通知或补扫报一次
            if let born = entry.stamp.created, let since = scan.bornAfter, born >= since { continue }
            remember(entry.key, entry.stamp)
        }
    }

    private func updatedSince(_ key: String, _ epoch: UInt64) -> Bool {
        if let entry = known[key], entry.epoch > epoch { return true }
        if let removed = removedAt[key], removed > epoch { return true }
        return false
    }

    /// 刚接上（或重新接上）监听：把会话目录整体比一遍。没见过、内容又在 window 以内改过的文件算补记，
    /// 返回其中最近的内容时间（接上之前那段空档里的写入不会丢）
    public func reconcile(now: Date) -> Date? {
        apply(collect(source.scanTargets, now: now), now: now)
    }

    /// 只核对这几个文件（真实写入的时间，没有就 nil）。不知道事件标志，按「标志不明」处理
    public func observe(files: [String], now: Date) -> Date? {
        observeFinding(files.map { FileEvent(path: $0) }, now: now)?.time
    }

    /// 核对这几个文件事件（带着事件标志）：最近一次真实写入，以及其中的「主动开始」
    public func observeFinding(_ files: [FileEvent], now: Date) -> ActivityFinding? {
        let current = files.map { ($0, stamp($0.path)) }
        var sessionWrite = false
        let found = ActivityFinding.merge(current.map { event, stamp in
            guard source.isSessionFile(event.path) else { return nil }
            let startFile = source.isStartFile(event.path)
            let result = check(key: comparablePath(event.path), path: event.path, current: stamp, flags: event.flags, now: now,
                               startFile: startFile, newCandidate: source.isNewSessionCandidate(event.path), live: true)
            if result != nil, !startFile { sessionWrite = true }
            return result
        })
        lastFindingHadSessionWrite = sessionWrite
        return found
    }

    /// 一批文件事件里最近一次真实写入的内容时间；没有真实写入时 nil。
    /// 同一批里有几个「要重扫」的信号也只整体核对一轮。（App 里目录核对放到后台跑，见 ActivityWatch）
    public func observe(_ events: [FileEvent], now: Date) -> Date? {
        let parts = split(events)
        var found = [observeFinding(parts.files, now: now)]
        if parts.full {
            found.append(applyFinding(collect(source.scanTargets, now: now), now: now))
        } else if !parts.trees.isEmpty {
            found.append(applyFinding(collect(parts.trees, now: now), now: now))
        }
        return ActivityFinding.merge(found)?.time
    }

    private func check(key: String, path: String, current: FileStamp?, flags: FileEventFlags, now: Date,
                       startFile: Bool, newCandidate: Bool, live: Bool = false) -> ActivityFinding? {
        guard let current else {
            forget(key)  // 删了或移走了：忘掉，不算活动
            return nil
        }
        if let old = known[key]?.stamp {
            remember(key, current)
            guard current.contentDiffers(from: old) else { return nil }
            return finding(current, start: startFile ? current.modified : nil, now: now)
        }
        if let moved = byInode[current.inode].flatMap({ $0 == key ? nil : known[$0]?.stamp }) ?? departed[current.inode],
           !current.contentDiffers(from: moved) {
            // 同一个文件改了名（编号、内容都没变）：搬到新名字下，不算新写入
            if let other = byInode[current.inode], other != key { forget(other) }
            departed[current.inode] = nil
            remember(key, current)
            return nil
        }
        remember(key, current)
        // 第一次见到、通知里只说属性变了（touch、chmod、扩展属性）：内容没变过，记下当基线
        if flags.isMetadataOnly { return nil }
        // 实时通知里第一次见到一个早就出生的会话文件（开始监听时还没来得及记基线）：没有旧版本可比，
        // 分不出是 touch 还是追加，记下当基线、不算活动。history.jsonl 例外：它只在提交提示词时变
        if live, !startFile, let born = current.created, born < now.addingTimeInterval(-window) { return nil }
        // 新建出来的会话文件 = 用户开了新会话；主动开始的时间是它出生的时间，不是最后一次写入的时间
        // （早就开好的旧会话晚被看见时，最后那笔后台输出不能冒充主动开始）
        let born = newCandidate ? current.created.flatMap { valid($0, now: now) ? $0 : nil } : nil
        return finding(current, start: startFile ? current.modified : born, now: now)
    }

    private func valid(_ time: Date, now: Date) -> Bool {
        time >= now.addingTimeInterval(-window) && time <= now.addingTimeInterval(Self.futureTolerance)
    }

    private func finding(_ stamp: FileStamp, start: Date?, now: Date) -> ActivityFinding? {
        guard valid(stamp.modified, now: now) else { return nil }
        return ActivityFinding(time: stamp.modified, start: start)
    }

    private func remember(_ key: String, _ stamp: FileStamp) {
        if let old = known[key]?.stamp, old.inode != stamp.inode, byInode[old.inode] == key { byInode[old.inode] = nil }
        known[key] = Known(stamp: stamp, epoch: bump())
        byInode[stamp.inode] = key
        removedAt[key] = nil
    }

    private func forget(_ key: String) {
        // 没入过账的路径也要记下删除：更早开始的后台核对收集到它的话，提交时不能让它复活
        if removedAt.count >= 4096 { removedAt.removeAll() }
        removedAt[key] = bump()
        guard let old = known.removeValue(forKey: key)?.stamp else { return }
        if byInode[old.inode] == key { byInode[old.inode] = nil }
        if departed.count >= 1024 { departed.removeAll() }
        departed[old.inode] = old
    }
}

extension FileEventFlags {
    /// 只说属性变了（权限、属主、扩展属性、修改时间这类元数据），没有新建、删除、改名、写内容
    public var isMetadataOnly: Bool {
        let content: FileEventFlags = [.itemCreated, .itemRemoved, .itemRenamed, .itemModified]
        let metadata: FileEventFlags = [.itemInodeMetaMod, .itemXattrMod, FileEventFlags(rawValue: 0x2000), FileEventFlags(rawValue: 0x4000)]
        return !needsRescan && isDisjoint(with: content) && !isDisjoint(with: metadata)
    }
}

/// 一次「主动开始」是谁的：用户的、QuotaPet 自己查额度时 CLI 留下的，还是查询还在跑、暂时判不了（查询结束后再判，不丢）
public enum StartVerdict: Equatable, Sendable {
    case user, own, undecided

    /// 写入时间落在 QuotaPet 自己查询进程运行期间（started…ended，前后各留 0.5 秒）：自己的；查询还在跑：先挂起；其余：用户的。
    /// 查询运行期间用户恰好也提交了提示词时分不出来，按自己的算（查询进程只跑几秒）
    public static func judge(_ time: Date, querying: Bool, started: Date?, ended: Date?) -> StartVerdict {
        let slack: TimeInterval = 0.5
        if querying, started.map({ time >= $0.addingTimeInterval(-slack) }) ?? true { return .undecided }
        if let started, let ended, ended >= started,
           time >= started.addingTimeInterval(-slack), time <= ended.addingTimeInterval(slack) { return .own }
        return .user
    }

    /// 同上，再对照 QuotaPet 自己更早的几次查询时段（本次运行的、和启动时固定下来的上一次运行的）：落在其中任何一段里都是自己的
    public static func judge(_ time: Date, querying: Bool, started: Date?, ended: Date?,
                             earlier: [(started: Date, ended: Date)]) -> StartVerdict {
        let verdict = judge(time, querying: querying, started: started, ended: ended)
        guard verdict == .user else { return verdict }
        return earlier.contains { judge(time, querying: false, started: $0.started, ended: $0.ended) == .own } ? .own : .user
    }
}

/// agy 每个会话的步骤记录 brain/<会话>/.system_generated/logs/transcript.jsonl：一步一行，开头标着来源和类型，
/// 用户自己发的消息是 "source":"USER_EXPLICIT"、"type":"USER_INPUT"，模型回复、系统通知、后台步骤都不是这个来源。
/// 这是能分出「用户回到原会话续聊」和「后台回复」的信号（两者在会话数据库上的文件变化一样）。
/// 只看每行里 "content" 之前那一段的来源、类型和 created_at，正文不看、不保存
public enum AgyTranscript {
    static let suffix = "/.system_generated/logs/transcript.jsonl"
    private static let contentKey = Data("\"content\"".utf8)
    private static let source = try! NSRegularExpression(pattern: #""source"\s*:\s*"USER_EXPLICIT""#)
    private static let type = try! NSRegularExpression(pattern: #""type"\s*:\s*"USER_INPUT""#)
    private static let created = try! NSRegularExpression(pattern: #""created_at"\s*:\s*"([^"]+)""#)

    /// 是不是某个 agy 根目录下 brain/<会话>/ 里的步骤记录
    public static func isTranscript(_ path: String, roots: [URL]) -> Bool {
        guard path.hasSuffix(suffix) else { return false }
        return roots.contains { root in
            guard let relative = relativePath(path, inside: root.appendingPathComponent("brain", isDirectory: true)) else { return false }
            return relative.split(separator: "/").count == 4  // <会话>/.system_generated/logs/transcript.jsonl
        }
    }

    /// 这一行是用户自己发的消息时，返回它的时间（只看 "content" 之前的部分）
    public static func userInputTime(line: Data) -> Date? {
        let end = line.range(of: contentKey)?.lowerBound ?? line.index(line.startIndex, offsetBy: min(line.count, 1024))
        guard let head = String(data: line[line.startIndex..<end], encoding: .utf8) else { return nil }
        let range = NSRange(head.startIndex..., in: head)
        guard source.firstMatch(in: head, range: range) != nil, type.firstMatch(in: head, range: range) != nil,
              let match = created.firstMatch(in: head, range: range), let stamp = Range(match.range(at: 1), in: head) else { return nil }
        return ClaudeTranscriptScanner.parseDate(String(head[stamp]))
    }
}

/// 增量读 agy 的步骤记录，找用户自己发的消息。第一次见到某个文件时只核对末尾一段（最多 tailCheck 字节）里 window 以内的，
/// 之后只读新追加的行。可以从主线程和后台线程调用（内部加锁），同一行只会读到一次
public final class AgyTranscriptReader: @unchecked Sendable {
    public static let tailCheck = 256 << 10
    private var cursors: [String: LineCursor] = [:]
    private let lock = NSLock()
    /// 「在未来」只按实际读到这一行时的时钟判断，不按调用方早先取的 now：后台核对排队以后用户才发的消息，
    /// 读到时已经不在未来，不能因为排队时的时间较早就被当成未来记录跳过（游标会越过它，之后再也读不到）；
    /// 读的过程中时钟往回拨了，也按回拨后的时钟判断，同一批里按新时钟合法的那条保得住
    let clock: () -> Date

    public init(clock: @escaping () -> Date = { Date() }) {
        self.clock = clock
    }

    /// 这个文件里新出现的用户消息里最近的一条（window 以内、不在未来）；没有就 nil。
    /// firstReadLookback：第一次见到这个文件、读末尾一段时往回看多久（默认同 window）
    public func read(_ path: String, now: Date, window: TimeInterval, firstReadLookback: TimeInterval? = nil) -> Date? {
        lock.lock(); defer { lock.unlock() }
        // 同一个文件可能以不同写法到达（实时通知、列目录得到的 /private/var 与 /var、经过符号链接，
        // 包括文件本身就是链接）：先解析一次，游标的键、取大小、打开文件都用解析后的同一个路径
        let key = Self.canonical(path)
        let url = URL(fileURLWithPath: key)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: key))?[.size] as? NSNumber else {
            cursors[key] = nil
            return nil
        }
        var candidates: [Date] = []
        // 每读一行取一次时钟：读到的每一行都早于这一刻（除非真的写着未来的时间）
        var limit: Date { clock().addingTimeInterval(ActivityLedger.futureTolerance) }
        let earliest = now.addingTimeInterval(-(cursors[key] == nil ? max(window, firstReadLookback ?? window) : window))
        func take(_ line: Data) {
            guard let time = AgyTranscript.userInputTime(line: line), time >= earliest, time <= limit else { return }
            candidates.append(time)
        }
        // 读完整批再按最后的时钟复核一遍：读的过程中时钟往回拨了，先读到、当时合法的那条现在已在未来，
        // 不能让它顶掉同一批里按新时钟合法的那条（游标已经越过这一批，之后不会再读）
        var latest: Date? {
            let final = limit
            return candidates.filter { $0 <= final }.max()
        }
        if cursors[key] == nil {
            // 第一次见到：只看末尾一段，从第一个完整行开始；游标停在最后一个完整行之后，
            // 还没写完的那一行留给下次读（不然写完时只读到后半截，这条用户消息就漏了）
            let total = size.uint64Value
            let start = total > UInt64(Self.tailCheck) ? total - UInt64(Self.tailCheck) : 0
            var resume = start
            if let handle = try? FileHandle(forReadingFrom: url) {
                defer { try? handle.close() }
                if (try? handle.seek(toOffset: start)) != nil, let data = try? handle.read(upToCount: Int(total - start)) {
                    var lineStart = data.startIndex
                    if start > 0, let newline = data.firstIndex(of: 0x0A) { lineStart = data.index(after: newline) }
                    while let newline = data[lineStart...].firstIndex(of: 0x0A) {
                        take(Data(data[lineStart..<newline]))
                        lineStart = data.index(after: newline)
                    }
                    resume = start + UInt64(data.distance(from: data.startIndex, to: lineStart))
                }
            }
            cursors[key] = LineCursor(offset: resume, identityOf: url)
            return latest
        }
        var cursor = cursors[key]!
        cursor.readAppended(from: url, size: size.uint64Value) { take($0) }
        cursors[key] = cursor
        return latest
    }

    static func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// 整体核对时要读哪些步骤记录：平时是 window 以内改过的。还没按「主动开始」的回看窗口找过（lookbackPending）、
    /// 这次核对又有会话写入的证据（会话文件 window 以内改过）时，24 小时以内改过的都读：用户消息可能早于 window，
    /// 之后那个会话只有会话文件在写、步骤记录没再动过。返回要读的路径和这次是不是按回看窗口找的
    public static func transcriptsToRead(roots: [URL], scan: ActivityScan, now: Date, window: TimeInterval,
                                         lookbackPending: Bool) -> (paths: [String], lookback: Bool) {
        guard !roots.isEmpty else { return ([], false) }
        let lookback = lookbackPending && scan.entries.contains { $0.stamp.modified >= now.addingTimeInterval(-window) }
        let since = now.addingTimeInterval(-(lookback ? ActivityLedger.startLookback : window))
        return (recentTranscripts(roots: roots, since: since), lookback)
    }

    /// 这些 agy 根目录下 window 以内改过的步骤记录（整体核对、晚接上监听时用）
    public static func recentTranscripts(roots: [URL], since: Date) -> [String] {
        roots.flatMap { root -> [String] in
            let brain = root.appendingPathComponent("brain", isDirectory: true)
            guard let sessions = try? FileManager.default.contentsOfDirectory(at: brain, includingPropertiesForKeys: nil) else { return [] }
            return sessions.compactMap { session in
                let file = session.appendingPathComponent(".system_generated/logs/transcript.jsonl")
                guard let modified = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date,
                      modified >= since else { return nil }
                return file.path
            }
        }
    }
}
