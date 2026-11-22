import Foundation

/// FSEvents 事件的标志（原始数值，和 CoreServices 里的 kFSEventStreamEventFlag* 一致；放在 Core 里是为了路由规则能进自检）
public struct FileEventFlags: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    /// 这个目录里的事件合并了，要自己把整个目录重新看一遍
    public static let mustScanSubDirs = FileEventFlags(rawValue: 0x1)
    /// 事件太多、用户态没来得及收，丢了
    public static let userDropped = FileEventFlags(rawValue: 0x2)
    /// 事件太多、内核丢了
    public static let kernelDropped = FileEventFlags(rawValue: 0x4)
    /// 被监听的目录本身被移走、改名或删了
    public static let rootChanged = FileEventFlags(rawValue: 0x20)
    /// 文件级事件（FileEvents 模式）：新建、删除、改名、内容改了
    public static let itemCreated = FileEventFlags(rawValue: 0x100)
    public static let itemRemoved = FileEventFlags(rawValue: 0x200)
    public static let itemRenamed = FileEventFlags(rawValue: 0x800)
    public static let itemInodeMetaMod = FileEventFlags(rawValue: 0x400)
    public static let itemModified = FileEventFlags(rawValue: 0x1000)
    public static let itemXattrMod = FileEventFlags(rawValue: 0x8000)
    public static let itemIsFile = FileEventFlags(rawValue: 0x10000)
    public static let itemIsDir = FileEventFlags(rawValue: 0x20000)
    public static let itemIsSymlink = FileEventFlags(rawValue: 0x40000)

    /// 不知道具体哪个文件变了，要把这个路径下的东西全当成可能变了
    public var needsRescan: Bool {
        !isDisjoint(with: [.mustScanSubDirs, .userDropped, .kernelDropped, .rootChanged])
    }
}

public struct FileEvent: Equatable, Sendable {
    public var path: String
    public var flags: FileEventFlags
    public init(path: String, flags: FileEventFlags = []) {
        self.path = path
        self.flags = flags
    }
}

public enum WatchRouting {
    /// 哪几家的文件变了。普通事件：路径在它监听的目录下、它也认这个文件（路径对不上任何一家的目录时，交给所有认这个文件的）。
    /// 需要重新扫描的事件（事件合并了、丢了、监听的目录被动过）：不知道是哪个文件，不再看 isRelevantChange，
    /// 路径下面（或者路径正好是上一级目录）有它监听的目录的那几家都算；对不上任何一家时所有家都算
    public static func providersAffected(by events: [FileEvent], providers: [UsageProvider]) -> Set<ProviderID> {
        var ids = Set<ProviderID>()
        for event in events {
            let owners = providers.filter { provider in
                provider.watchPaths.contains { root in
                    event.path == root || event.path.hasPrefix(root + "/")
                        || (event.flags.needsRescan && root.hasPrefix(event.path + "/"))
                }
            }
            let candidates = owners.isEmpty ? providers : owners
            if event.flags.needsRescan {
                ids.formUnion(candidates.map(\.id))
            } else {
                for provider in candidates where provider.isRelevantChange(path: event.path) { ids.insert(provider.id) }
            }
        }
        return ids
    }
}

/// 路径统一写法：去掉 ..、多余的斜杠，/private/var 和 /var 当成同一个（FSEvents 给的是真实路径）
public func comparablePath(_ path: String) -> String {
    let standard = URL(fileURLWithPath: path).standardizedFileURL.path
    return standard.hasPrefix("/private/") ? String(standard.dropFirst("/private".count)) : standard
}

/// path 在 directory 里面（不含目录本身）。directory 是符号链接时，解析后的写法也认
public func isPath(_ path: String, inside directory: URL) -> Bool {
    relativePath(path, inside: directory) != nil
}

/// path 在 directory 里面时，返回它相对 directory 的那一段（不含目录本身）；不在里面时 nil。directory 是符号链接时，解析后的写法也认
public func relativePath(_ path: String, inside directory: URL) -> String? {
    let target = comparablePath(path)
    for base in [directory.path, directory.resolvingSymlinksInPath().path] {
        let prefix = comparablePath(base) + "/"
        if target.hasPrefix(prefix), target.count > prefix.count { return String(target.dropFirst(prefix.count)) }
    }
    return nil
}
