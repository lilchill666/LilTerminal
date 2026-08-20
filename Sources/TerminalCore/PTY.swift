import Foundation
import Darwin

/// A pseudo-terminal running a child process.
///
/// SwiftTerm provided this; on the Ghostty engine it is ours. The contract is
/// deliberately small: bytes in, bytes out, plus resize and teardown.
public final class PTY {
    public private(set) var masterFD: Int32 = -1
    public private(set) var pid: pid_t = -1
    public private(set) var isRunning = false

    /// Called on a background queue with a chunk of child output. The handler
    /// must copy anything it needs — the buffer is reused between reads.
    public var onOutput: ((UnsafeRawBufferPointer) -> Void)?
    /// Called on the main queue when the child exits.
    public var onExit: ((Int32?) -> Void)?

    private var readSource: DispatchSourceRead?
    private var processSource: DispatchSourceProcess?
    private let queue = DispatchQueue(label: "app.lilterminal.pty", qos: .userInitiated)
    private var buffer = [UInt8](repeating: 0, count: 64 * 1024)

    public enum Failure: Error { case openFailed(Int32), spawnFailed(Int32) }

    public init() {}

    public func start(executable: String, args: [String], environment: [String],
               execName: String? = nil, directory: String?,
               columns: UInt16, rows: UInt16) throws {
        var master: Int32 = 0
        var slave: Int32 = 0
        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else {
            throw Failure.openFailed(errno)
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        // The child gets the slave side as its stdin/stdout/stderr.
        posix_spawn_file_actions_adddup2(&actions, slave, 0)
        posix_spawn_file_actions_adddup2(&actions, slave, 1)
        posix_spawn_file_actions_adddup2(&actions, slave, 2)
        posix_spawn_file_actions_addclose(&actions, slave)
        posix_spawn_file_actions_addclose(&actions, master)
        if let directory {
            posix_spawn_file_actions_addchdir_np(&actions, directory)
        }

        var attrs: posix_spawnattr_t?
        posix_spawnattr_init(&attrs)
        defer { posix_spawnattr_destroy(&attrs) }
        // SETSID makes the child a session leader so the pty becomes its
        // controlling terminal — without it job control and signals break.
        posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETSID))

        // argv[0] may differ from the path: a leading dash is how a shell is
        // told it is a login shell.
        let argv0 = execName ?? (executable as NSString).lastPathComponent
        var childPID: pid_t = 0
        let cArgs: [String] = [argv0] + args
        let status = withCStrings(cArgs) { argvPtrs in
            withCStrings(environment) { envPtrs in
                posix_spawn(&childPID, executable, &actions, &attrs, argvPtrs, envPtrs)
            }
        }

        close(slave)
        guard status == 0 else {
            close(master)
            throw Failure.spawnFailed(status)
        }

        masterFD = master
        pid = childPID
        isRunning = true

        // Non-blocking so a slow reader never stalls the source.
        let flags = fcntl(master, F_GETFL, 0)
        _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)

        startReading()
        watchForExit()
    }

    private func startReading() {
        let source = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self, self.masterFD >= 0 else { return }
            // Drain what is available; one read per event would leave the rest
            // buffered until the next wakeup and make output visibly chunky.
            while true {
                let count = self.buffer.withUnsafeMutableBytes { raw in
                    read(self.masterFD, raw.baseAddress, raw.count)
                }
                if count > 0 {
                    self.buffer.withUnsafeBytes { raw in
                        self.onOutput?(UnsafeRawBufferPointer(rebasing: raw.prefix(count)))
                    }
                    if count < self.buffer.count { break }
                } else {
                    break
                }
            }
        }
        source.resume()
        readSource = source
    }

    private func watchForExit() {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var status: Int32 = 0
            waitpid(self.pid, &status, WNOHANG)
            let code: Int32? = (status & 0x7f) == 0 ? (status >> 8) & 0xff : nil
            self.isRunning = false
            DispatchQueue.main.async { self.onExit?(code) }
        }
        source.resume()
        processSource = source
    }

    public func write(_ bytes: [UInt8]) {
        guard masterFD >= 0 else { return }
        queue.async { [masterFD] in
            var offset = 0
            bytes.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                // Short writes are normal on a pty; loop until drained.
                while offset < raw.count {
                    let written = Darwin.write(masterFD, base + offset, raw.count - offset)
                    if written <= 0 { break }
                    offset += written
                }
            }
        }
    }

    public func resize(columns: UInt16, rows: UInt16) {
        guard masterFD >= 0 else { return }
        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(masterFD, TIOCSWINSZ, &size)
    }

    public func terminate() {
        guard isRunning else { return }
        isRunning = false
        // SIGHUP to the process group is what closing a terminal window sends.
        if pid > 0 { kill(-pid, SIGHUP) }
        readSource?.cancel()
        processSource?.cancel()
        if masterFD >= 0 { close(masterFD); masterFD = -1 }
    }

    deinit { terminate() }
}

/// Bridges `[String]` to the null-terminated `char *[]` posix_spawn expects.
private func withCStrings<R>(_ strings: [String],
                             _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
    var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    pointers.append(nil)
    defer { for pointer in pointers where pointer != nil { free(pointer) } }
    return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
}
