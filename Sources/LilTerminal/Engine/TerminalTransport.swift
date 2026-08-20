import Foundation
import TerminalCore

/// Where a terminal's bytes come from and go to.
///
/// Two implementations: a pty this process owns, and one owned by the session
/// daemon. The daemon version is what lets shells survive quitting the app, and
/// the view does not need to know which it has.
protocol TerminalTransport: AnyObject {
    var isRunning: Bool { get }
    var processID: pid_t { get }
    var onOutput: ((UnsafeRawBufferPointer) -> Void)? { get set }
    var onExit: ((Int32?) -> Void)? { get set }

    func start(executable: String, args: [String], environment: [String],
               execName: String?, directory: String?,
               columns: UInt16, rows: UInt16) throws
    func write(_ bytes: [UInt8])
    func resize(columns: UInt16, rows: UInt16)
    /// Ends the shell.
    func terminate()
    /// Leaves the shell running and stops listening. Only meaningful for the
    /// daemon transport; a locally owned pty dies with this process regardless.
    func detach()
}

extension PTY: TerminalTransport {
    var processID: pid_t { pid }
    func detach() { terminate() }
}

/// A session living in the daemon.
final class DaemonTransport: TerminalTransport {
    let id: String
    private(set) var isRunning = false
    private(set) var processID: pid_t = -1
    var onOutput: ((UnsafeRawBufferPointer) -> Void)?
    var onExit: ((Int32?) -> Void)?

    private weak var client: DaemonClient?

    /// - Parameter existing: true when reattaching a session that is already
    ///   running, which is the whole point of the daemon.
    init(id: String, client: DaemonClient, existing: Bool) {
        self.id = id
        self.client = client
        self.isRunning = existing
    }

    func start(executable: String, args: [String], environment: [String],
               execName: String?, directory: String?,
               columns: UInt16, rows: UInt16) throws {
        guard let client else { throw AIError.failed("daemon unavailable") }
        if isRunning {
            client.attach(id: id, transport: self)
            // The replayed bytes were written at whatever width the session had
            // before. Nudging the size afterwards raises SIGWINCH, and every
            // common shell redraws its prompt in response — without which the
            // reattached screen keeps the old wrapping.
            client.resize(id: id, columns: columns, rows: rows)
            // Ctrl-L: the universal "redraw". Replayed history keeps whatever
            // wrapping it was written with, but the live prompt comes back
            // correct at the current width.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak client, id] in
                client?.write(id: id, bytes: [0x0C])
            }
        } else {
            let spec = SessionSpec(id: id, executable: executable, args: args,
                                   environment: environment, execName: execName,
                                   directory: directory, columns: columns, rows: rows)
            client.create(spec, transport: self)
            isRunning = true
        }
    }

    func write(_ bytes: [UInt8]) { client?.write(id: id, bytes: bytes) }
    func resize(columns: UInt16, rows: UInt16) {
        client?.resize(id: id, columns: columns, rows: rows)
    }
    func terminate() {
        isRunning = false
        client?.kill(id: id)
    }
    func detach() {
        client?.detach(id: id)
    }

    func deliver(_ data: Data) {
        data.withUnsafeBytes { onOutput?($0) }
    }

    func deliverExit(_ code: Int32?) {
        isRunning = false
        onExit?(code)
    }

    func noteCreated(pid: Int32) { processID = pid }
}

/// One connection to the daemon, shared by every daemon-backed session.
final class DaemonClient {
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var framer = LineFramer()
    private let queue = DispatchQueue(label: "app.lilterminal.daemon")
    private var transports: [String: DaemonTransport] = [:]
    private(set) var isConnected = false

    /// Sessions the daemon already has, learned at connect time.
    private(set) var knownSessions: [SessionSummary] = []
    /// Signalled once the initial session list has arrived. Without waiting for
    /// it, `hasSession` answers "no" for every session and the app starts a
    /// second shell instead of reattaching to the one it just survived.
    private let listReady = DispatchSemaphore(value: 0)
    private var listArrived = false

    static let shared = DaemonClient()

    /// Starts the daemon if needed and connects. Returns false when the daemon
    /// could not be reached, so the caller can fall back to a local pty rather
    /// than leaving the user with a dead terminal.
    private static let debug = ProcessInfo.processInfo.environment["LILTERM_DEBUG"] != nil
    private func log(_ message: String) {
        guard Self.debug else { return }
        FileHandle.standardError.write("daemon: \(message)\n".data(using: .utf8)!)
    }

    @discardableResult
    func connectIfNeeded() -> Bool {
        if isConnected { return true }
        if connect() { log("connected to existing"); return true }
        guard launchDaemon() else { log("launch failed"); return false }
        log("launched, waiting for socket")
        // The daemon needs a moment to bind its socket.
        for _ in 0..<20 {
            usleep(100_000)
            if connect() { log("connected after launch"); return true }
        }
        log("timed out waiting for socket")
        return false
    }

    private func launchDaemon() -> Bool {
        // Ships beside the app binary inside the bundle.
        let helper = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/lilterm-sessiond")
        log("helper path \(helper.path)")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            log("helper not executable")
            return false
        }
        let process = Process()
        process.executableURL = helper
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            log("run failed: \(error)")
            return false
        }
        return true
    }

    private func connect() -> Bool {
        let handle = socket(AF_UNIX, SOCK_STREAM, 0)
        guard handle >= 0 else { return false }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        var bytes = [CChar](repeating: 0, count: capacity)
        SessionSocket.path.withCString { _ = strncpy(&bytes, $0, capacity - 1) }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: UnsafeRawBufferPointer(start: bytes, count: capacity))
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(handle, $0, size)
            }
        }
        guard connected == 0 else { close(handle); return false }

        fd = handle
        isConnected = true
        listen()
        send(.list)
        // Block briefly for the inventory. This runs on the main thread while
        // the reply is parsed on the client queue, so there is no deadlock, and
        // a daemon that cannot answer in a second is not one worth waiting for.
        _ = listReady.wait(timeout: .now() + 1.0)
        return true
    }

    private func listen() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 128 * 1024)
            let count = read(self.fd, &buffer, buffer.count)
            guard count > 0 else { self.disconnect(); return }
            for line in self.framer.append(Data(buffer.prefix(count))) {
                self.handle(line)
            }
        }
        source.resume()
        self.source = source
    }

    private func disconnect() {
        source?.cancel()
        if fd >= 0 { close(fd) }
        fd = -1
        isConnected = false
    }

    private func handle(_ line: Data) {
        guard let message = try? JSONDecoder().decode(ServerMessage.self, from: line) else { return }
        switch message {
        case .sessions(let list):
            knownSessions = list
            if !listArrived {
                listArrived = true
                listReady.signal()
            }
        case .created(let id, let pid):
            transports[id]?.noteCreated(pid: pid)
        case .output(let id, let base64):
            guard let data = Data(base64Encoded: base64) else { return }
            transports[id]?.deliver(data)
        case .exited(let id, let code):
            DispatchQueue.main.async { [weak self] in
                self?.transports[id]?.deliverExit(code)
            }
        case .failure:
            break
        }
    }

    private func send(_ message: ClientMessage) {
        guard isConnected, let data = encodeLine(message) else { return }
        queue.async { [fd] in
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.write(fd, base + offset, raw.count - offset)
                    if written <= 0 { break }
                    offset += written
                }
            }
        }
    }

    // MARK: - Session operations

    func create(_ spec: SessionSpec, transport: DaemonTransport) {
        transports[spec.id] = transport
        send(.create(spec))
    }

    func attach(id: String, transport: DaemonTransport) {
        transports[id] = transport
        send(.attach(id: id))
    }

    func detach(id: String) {
        send(.detach(id: id))
        transports[id] = nil
    }

    func write(id: String, bytes: [UInt8]) {
        send(.write(id: id, base64: Data(bytes).base64EncodedString()))
    }

    func resize(id: String, columns: UInt16, rows: UInt16) {
        send(.resize(id: id, columns: columns, rows: rows))
    }

    func kill(id: String) {
        send(.kill(id: id))
        transports[id] = nil
    }

    func hasSession(id: String) -> Bool {
        knownSessions.contains { $0.id == id && $0.isRunning }
    }
}
