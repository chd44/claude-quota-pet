import Foundation

/// 增量读取一个只往后追加的日志文件（*.jsonl）：记住读到哪了，每次只读新追加的部分，一行一行交出去；
/// 最后一行还没写完就先留着，等下次写完再交。Claude Code 和 Codex 的日志扫描器共用。
///
/// 只比文件长度不够：同名文件被换掉（先写临时文件再改名、重新生成）、长度正好一样时，会接着旧的偏移读，
/// 新内容读不到。所以还要认文件本身：inode 对不上，或者开头那一段内容变了（原地改写，inode 不变），都算换了一个文件，从头读。
/// 超长的、一直没有换行的内容不能无限攒在内存里：超过 maxLineLength 就丢掉这一行，从下一处换行恢复；
/// 普通的半行（没超限）照旧留着、等后面补全。
struct LineCursor {
    /// 一行最多攒这么多字节。Claude Code 的一行可能带整张截图（几 MB），留足余量
    static let defaultMaxLineLength = 32 << 20
    /// 认「开头内容」看前这么多字节
    static let headLength = 128

    private(set) var offset: UInt64 = 0
    private var partial = Data()
    /// 正在丢弃一行超长的内容：一直丢到下一个换行
    private var skipping = false
    private var identity: FileIdentity?
    let maxLineLength: Int

    /// identityOf：从 offset 开始接着读（比如「只从末尾往后跟」）时，同时记下这个文件现在是哪一个，之后被换掉了才认得出
    init(offset: UInt64 = 0, identityOf url: URL? = nil, maxLineLength: Int = LineCursor.defaultMaxLineLength) {
        self.offset = offset
        self.maxLineLength = maxLineLength
        if let url, offset > 0, let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            identity = FileIdentity.of(handle, headLength: min(UInt64(Self.headLength), offset))
        }
    }

    /// 文件的身份：设备 + inode，加上开头那一段内容的指纹（长度按上次读到的位置算，文件长大不会改变它）
    struct FileIdentity: Equatable {
        var device: Int32
        var inode: UInt64
        var headLength: Int
        var headHash: UInt64

        static func of(_ handle: FileHandle, headLength: UInt64) -> FileIdentity? {
            var info = stat()
            guard fstat(handle.fileDescriptor, &info) == 0 else { return nil }
            let length = Int(headLength)
            guard let hash = headHash(handle, length: length) else { return nil }
            return FileIdentity(device: info.st_dev, inode: UInt64(info.st_ino), headLength: length, headHash: hash)
        }

        /// 文件开头 length 个字节的指纹（FNV-1a）；读不够 length 个字节（文件变短了）是 nil
        static func headHash(_ handle: FileHandle, length: Int) -> UInt64? {
            guard length > 0 else { return 0 }
            guard (try? handle.seek(toOffset: 0)) != nil, let data = try? handle.read(upToCount: length), data.count == length else { return nil }
            var hash: UInt64 = 0xcbf29ce484222325
            for byte in data { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
            return hash
        }
    }

    private mutating func reset() {
        offset = 0
        partial = Data()
        skipping = false
        identity = nil
    }

    /// size：文件现在的大小。文件变小了（被截断或重写），或者换成了另一个文件，就从头读。
    /// 分块读，每块读完马上释放：扫描是后台队列上的一个任务，不包 autoreleasepool 的话，
    /// 读过的块要等整个任务结束才一起释放，第一次扫几百 MB 日志时内存会跟着涨
    mutating func readAppended(from url: URL, size: UInt64, onLine: (Data) -> Void) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        // 先认文件：身份记着的话，按记着的长度重算开头指纹，对不上就是换了
        if let known = identity {
            let current = FileIdentity.of(handle, headLength: UInt64(known.headLength))
            if current != known { reset() }
        }
        if size < offset { reset() }
        guard size > offset else { return }
        guard (try? handle.seek(toOffset: offset)) != nil else { return }
        var more = true
        while more {
            more = autoreleasepool {
                guard let chunk = try? handle.read(upToCount: 8 << 20), !chunk.isEmpty else { return false }
                offset += UInt64(chunk.count)
                consume(chunk, onLine: onLine)
                return true
            }
        }
        // 记下读到现在这个位置时文件的身份（开头最多 headLength 个字节）
        identity = FileIdentity.of(handle, headLength: min(UInt64(Self.headLength), offset))
    }

    private mutating func consume(_ chunk: Data, onLine: (Data) -> Void) {
        var buffer = chunk
        if skipping {
            // 丢弃超长行的剩余部分，从下一个换行之后恢复
            guard let newline = buffer.firstIndex(of: 0x0A) else { return }
            buffer = Data(buffer[buffer.index(after: newline)...])
            skipping = false
        }
        if !partial.isEmpty {
            partial.append(buffer)
            buffer = partial
            partial = Data()
        }
        var start = buffer.startIndex
        while let newline = buffer[start...].firstIndex(of: 0x0A) {
            let line = buffer[start..<newline]
            if line.count <= maxLineLength { onLine(line) }  // 一整行超限（一块里就读全了）：丢掉
            start = buffer.index(after: newline)
        }
        let rest = buffer[start...]
        if rest.count > maxLineLength {
            skipping = true  // 还没写完的这一行已经超限：不再攒，丢到下一处换行
        } else {
            partial = Data(rest)
        }
    }
}
