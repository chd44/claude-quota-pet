import Foundation

/// 等子进程结束，最多等一段时间。不用 `Process.waitUntilExit()`：它在后台线程上转 RunLoop 等结束通知，
/// 实测偶尔漏掉通知（进程早已退出并被回收）就永远不返回，查询卡死、之后再也不刷新。
/// 必须在 `process.run()` 之前创建（要先挂上 terminationHandler）。
public final class ProcessExit: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var exited = false

    public init(_ process: Process) {
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.exited = true
            self.lock.unlock()
            self.semaphore.signal()
        }
    }

    /// 已经结束了吗（结束回调已经来过）
    public var hasExited: Bool {
        lock.lock()
        defer { lock.unlock() }
        return exited
    }

    /// 等到结束或超时；返回是否已经结束。可以重复调用
    @discardableResult
    public func wait(timeout: TimeInterval) -> Bool {
        if hasExited { return true }
        if semaphore.wait(timeout: .now() + max(0, timeout)) == .success {
            semaphore.signal()  // 留给之后的调用
            return true
        }
        return hasExited
    }
}
