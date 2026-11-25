import Foundation
import Darwin

public enum PTYProcessError: Error {
    case ptyCreationFailed(Int32)
    case spawnFailed(Int32)
}

/// Launches an interactive CLI attached to a dedicated PTY inside its own session
/// (`POSIX_SPAWN_SETSID`) so `/dev/tty` never touches or gets stopped by a parent terminal.
public final class PTYProcess: @unchecked Sendable {
    public let pid: pid_t

    private let ioLock = NSLock()
    private var masterFD: Int32

    private let stateLock = NSLock()
    private var exited = false
    private var rawWaitStatus: Int32?
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var exitSource: DispatchSourceProcess?

    public init(
        executableURL: URL,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String],
        rows: UInt16,
        columns: UInt16
    ) throws {
        // 同时启动多个子进程时 posix_openpt 偶尔失败（并发 20 个时约 8%），稍等重试几次就好
        var master = posix_openpt(O_RDWR | O_NOCTTY)
        for attempt in 1...5 where master < 0 {
            usleep(useconds_t(20_000 * attempt))
            master = posix_openpt(O_RDWR | O_NOCTTY)
        }
        guard master >= 0 else {
            throw PTYProcessError.ptyCreationFailed(errno)
        }
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        _ = fcntl(master, F_SETFL, O_NONBLOCK)
        _ = fcntl(master, F_SETNOSIGPIPE, 1)

        guard grantpt(master) == 0, unlockpt(master) == 0 else {
            let err = errno
            close(master)
            throw PTYProcessError.ptyCreationFailed(err)
        }

        var nameBuf = [CChar](repeating: 0, count: 1024)
        guard ptsname_r(master, &nameBuf, nameBuf.count) == 0 else {
            let err = errno
            close(master)
            throw PTYProcessError.ptyCreationFailed(err)
        }
        let slavePath = String(cString: nameBuf)

        // Open slave in the parent with O_NOCTTY so a LaunchServices app never acquires it as its own TTY,
        // and keep it open across posix_spawn so TIOCSWINSZ persists until the child opens slavePath.
        let slave = open(slavePath, O_RDWR | O_NOCTTY | O_CLOEXEC)
        guard slave >= 0 else {
            let err = errno
            close(master)
            throw PTYProcessError.ptyCreationFailed(err)
        }
        defer { close(slave) }

        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(slave, TIOCSWINSZ, &size)

        var actions: posix_spawn_file_actions_t?
        let initActionsRC = posix_spawn_file_actions_init(&actions)
        guard initActionsRC == 0 else {
            close(master)
            throw PTYProcessError.spawnFailed(initActionsRC)
        }
        defer { posix_spawn_file_actions_destroy(&actions) }

        // 只用 _np 版本：不带 _np 的新名字只在 macOS 26 的 SDK 里声明，旧 SDK（比如 CI）编译不过；
        // #available 只管运行时，挡不住编译期找不到符号。_np 从 10.15 起都有
        let chdirRC = posix_spawn_file_actions_addchdir_np(&actions, workingDirectory.path)
        guard chdirRC == 0 else {
            close(master)
            throw PTYProcessError.spawnFailed(chdirRC)
        }

        // Open slavePath on fd 0 without O_NOCTTY so the new session leader acquires it as /dev/tty.
        let openRC = posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, slavePath, O_RDWR, 0)
        let dupOutRC = posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDOUT_FILENO)
        let dupErrRC = posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDERR_FILENO)
        for rc in [openRC, dupOutRC, dupErrRC] where rc != 0 {
            close(master)
            throw PTYProcessError.spawnFailed(rc)
        }

        var attr: posix_spawnattr_t?
        let initAttrRC = posix_spawnattr_init(&attr)
        guard initAttrRC == 0 else {
            close(master)
            throw PTYProcessError.spawnFailed(initAttrRC)
        }
        defer { posix_spawnattr_destroy(&attr) }

        let flags = Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)
        let flagsRC = posix_spawnattr_setflags(&attr, flags)
        guard flagsRC == 0 else {
            close(master)
            throw PTYProcessError.spawnFailed(flagsRC)
        }

        // Swift Concurrency worker threads block SIGTERM/SIGINT/SIGHUP in their signal mask;
        // reset both mask and termination signals so the child can receive terminate() normally.
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        let maskRC = posix_spawnattr_setsigmask(&attr, &emptyMask)
        guard maskRC == 0 else {
            close(master)
            throw PTYProcessError.spawnFailed(maskRC)
        }

        var defaultSigs = sigset_t()
        sigemptyset(&defaultSigs)
        for sig in [SIGTERM, SIGINT, SIGHUP, SIGQUIT] {
            sigaddset(&defaultSigs, sig)
        }
        let sigdefRC = posix_spawnattr_setsigdefault(&attr, &defaultSigs)
        guard sigdefRC == 0 else {
            close(master)
            throw PTYProcessError.spawnFailed(sigdefRC)
        }

        var cArgs: [UnsafeMutablePointer<CChar>?] = ([executableURL.path] + arguments).map { strdup($0) }
        cArgs.append(nil)
        defer { for ptr in cArgs { free(ptr) } }

        var cEnv: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
        cEnv.append(nil)
        defer { for ptr in cEnv { free(ptr) } }

        var spawnedPID: pid_t = 0
        let spawnRC = posix_spawn(&spawnedPID, executableURL.path, &actions, &attr, cArgs, cEnv)
        guard spawnRC == 0 else {
            close(master)
            throw PTYProcessError.spawnFailed(spawnRC)
        }

        self.pid = spawnedPID
        self.masterFD = master

        let source = DispatchSource.makeProcessSource(
            identifier: spawnedPID,
            eventMask: .exit,
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            self?.pollExit()
        }
        stateLock.lock()
        self.exitSource = source
        stateLock.unlock()
        source.resume()
        pollExit()
    }

    deinit {
        exitSource?.cancel()
        exitSource = nil
        if masterFD >= 0 {
            close(masterFD)
            masterFD = -1
        }
        if !exited && pid > 0 {
            var status: Int32 = 0
            _ = waitpid(pid, &status, WNOHANG)
        }
    }

    public var hasExited: Bool {
        pollExit()
        stateLock.lock()
        defer { stateLock.unlock() }
        return exited
    }

    public var isRunning: Bool {
        !hasExited
    }

    public var waitStatus: Int32? {
        pollExit()
        stateLock.lock()
        defer { stateLock.unlock() }
        return exited ? rawWaitStatus : nil
    }

    public func read(into buffer: inout [UInt8]) -> Int {
        ioLock.lock()
        defer { ioLock.unlock() }
        guard masterFD >= 0, !buffer.isEmpty else { return -1 }
        while true {
            let n = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(masterFD, raw.baseAddress, raw.count)
            }
            if n < 0 && errno == EINTR { continue }
            return n
        }
    }

    public func write(_ text: String) {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty else { return }
        ioLock.lock()
        defer { ioLock.unlock() }
        guard masterFD >= 0 else { return }
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { raw in
                Darwin.write(masterFD, raw.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if written > 0 {
                offset += written
            } else if written < 0 && errno == EINTR {
                continue
            } else {
                break
            }
        }
    }

    public func closeMaster() {
        ioLock.lock()
        defer { ioLock.unlock() }
        if masterFD >= 0 {
            close(masterFD)
            masterFD = -1
        }
    }

    public func terminate() {
        sendSignal(SIGTERM)
    }

    public func forceKill() {
        sendSignal(SIGKILL)
    }

    @discardableResult
    public func waitAsync(timeout: TimeInterval) async -> Bool {
        let id = UUID()
        let duration = max(0, timeout)
        return await withCheckedContinuation { continuation in
            stateLock.lock()
            let reaped = tryReapLocked()
            if exited {
                stateLock.unlock()
                for item in reaped { item.resume(returning: true) }
                continuation.resume(returning: true)
                return
            }
            waiters[id] = continuation
            stateLock.unlock()
            for item in reaped { item.resume(returning: true) }

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + duration) { [weak self] in
                guard let self else { return }
                self.stateLock.lock()
                let timedReaped = self.tryReapLocked()
                let pending = self.waiters.removeValue(forKey: id)
                let done = self.exited
                self.stateLock.unlock()
                for item in timedReaped { item.resume(returning: true) }
                pending?.resume(returning: done)
            }
        }
    }

    @discardableResult
    public func drainWhileWaiting(timeout: TimeInterval) async -> Bool {
        var nowUptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
        let deadline = nowUptime + max(0, timeout)
        var scratch = [UInt8](repeating: 0, count: 4096)
        while !hasExited {
            while read(into: &scratch) > 0 {}
            let remaining = deadline - nowUptime
            if remaining <= 0 { return hasExited }
            if await waitAsync(timeout: min(0.1, remaining)) { return true }
        }
        while read(into: &scratch) > 0 {}
        return true
    }

    private func pollExit() {
        stateLock.lock()
        let pending = tryReapLocked()
        stateLock.unlock()
        for continuation in pending {
            continuation.resume(returning: true)
        }
    }

    private func sendSignal(_ sig: Int32) {
        stateLock.lock()
        let pending = tryReapLocked()
        if !exited && pid > 1 {
            _ = Darwin.kill(-pid, sig)
            _ = Darwin.kill(pid, sig)
        }
        stateLock.unlock()
        for continuation in pending {
            continuation.resume(returning: true)
        }
    }

    private func tryReapLocked() -> [CheckedContinuation<Bool, Never>] {
        if exited { return [] }
        var status: Int32 = 0
        let r = waitpid(pid, &status, WNOHANG)
        if r == pid || (r == -1 && errno == ECHILD) {
            exited = true
            if r == pid {
                rawWaitStatus = status
            }
            exitSource?.cancel()
            exitSource = nil
            let pending = Array(waiters.values)
            waiters.removeAll()
            return pending
        }
        return []
    }
}
