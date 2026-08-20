import Foundation
import Darwin
import TerminalCore

/// A tiny daemon that owns pseudo-terminals so shells outlive the app.
///
/// The app cannot do this itself: a pty's child dies with the process that
/// owns it, so quitting LilTerminal would take every agent and build with it.
/// This process holds them instead and replays recent output when a client
/// reattaches.
///
/// Deliberately small — no dependencies beyond the shared pty code, one socket,
/// and newline-delimited JSON — because a daemon that outlives the app must be
/// the least surprising part of the system.
final class SessionDaemon {
    private struct Session {
        let pty: PTY
        let spec: SessionSpec
        let startedAt: Date
        /// Recent output, replayed on attach so a reattached tab is not blank.
        var scrollback = Data()
        var exitCode: Int32?
        var isRunning = true
    }

    private var sessions: [String: Session] = [:]
    private var clients: [Int32: Client] = [:]
    private let queue = DispatchQueue(label: "app.lilterminal.sessiond")
    private var listener: Int32 = -1
    private var listenSource: DispatchSourceRead?
    /// Bounded so a chatty session cannot grow the daemon without limit.
    private let scrollbackLimit = 256 * 1024
    /// Quit once nothing is attached and no session survives.
    private var idleTimer: DispatchSourceTimer?

    private final class Client {
        let fd: Int32
        var framer = LineFramer()
        var attached: Set<String> = []
        var source: DispatchSourceRead?
        init(fd: Int32) { self.fd = fd }
    }

    func run() {
        let path = SessionSocket.path
        unlink(path)

        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { fatalError("socket() failed") }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        // Copy the path in through a local buffer: writing into the tuple
        // while also reading its size counts as overlapping access.
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        var pathBytes = [CChar](repeating: 0, count: capacity)
        path.withCString { source in _ = strncpy(&pathBytes, source, capacity - 1) }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: UnsafeRawBufferPointer(start: pathBytes, count: capacity))
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, size) }
        }
        guard bound == 0, listen(listener, 8) == 0 else { fatalError("bind/listen failed") }
        // Only this user may talk to it.
        chmod(path, 0o600)

        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
        source.setEventHandler { [weak self] in self?.accept() }
        source.resume()
        listenSource = source

        scheduleIdleCheck()
        dispatchMain()
    }

    // MARK: - Connections

    private func accept() {
        let fd = Darwin.accept(listener, nil, nil)
        guard fd >= 0 else { return }
        let client = Client(fd: fd)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self, weak client] in
            guard let self, let client else { return }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { self.drop(client); return }
            for line in client.framer.append(Data(buffer.prefix(count))) {
                self.handle(line, from: client)
            }
        }
        source.resume()
        client.source = source
        clients[fd] = client
    }

    private func drop(_ client: Client) {
        client.source?.cancel()
        close(client.fd)
        clients[client.fd] = nil
    }

    private func send(_ message: ServerMessage, to client: Client) {
        guard let data = encodeLine(message) else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = write(client.fd, base + offset, raw.count - offset)
                if written <= 0 { break }
                offset += written
            }
        }
    }

    private func broadcast(_ message: ServerMessage, sessionID: String) {
        for client in clients.values where client.attached.contains(sessionID) {
            send(message, to: client)
        }
    }

    // MARK: - Messages

    private func handle(_ line: Data, from client: Client) {
        guard let message = try? JSONDecoder().decode(ClientMessage.self, from: line) else { return }

        switch message {
        case .list:
            send(.sessions(sessions.map { id, session in
                SessionSummary(id: id, pid: session.pty.pid,
                               isRunning: session.isRunning, startedAt: session.startedAt)
            }), to: client)

        case .create(let spec):
            create(spec, for: client)

        case .attach(let id):
            guard let session = sessions[id] else {
                send(.failure(id: id, message: "no such session"), to: client)
                return
            }
            client.attached.insert(id)
            // Replay first so the tab is not blank on reattach.
            if !session.scrollback.isEmpty {
                send(.output(id: id, base64: session.scrollback.base64EncodedString()), to: client)
            }
            if !session.isRunning {
                send(.exited(id: id, code: session.exitCode), to: client)
            }

        case .detach(let id):
            client.attached.remove(id)

        case .write(let id, let base64):
            guard let data = Data(base64Encoded: base64) else { return }
            sessions[id]?.pty.write([UInt8](data))

        case .resize(let id, let columns, let rows):
            sessions[id]?.pty.resize(columns: columns, rows: rows)

        case .kill(let id):
            sessions[id]?.pty.terminate()
            sessions[id] = nil

        case .shutdownIfIdle:
            shutdownIfIdle()
        }
    }

    private func create(_ spec: SessionSpec, for client: Client) {
        let pty = PTY()
        var session = Session(pty: pty, spec: spec, startedAt: Date())

        pty.onOutput = { [weak self] bytes in
            guard let self else { return }
            let data = Data(bytes)
            self.queue.async {
                guard var stored = self.sessions[spec.id] else { return }
                stored.scrollback.append(data)
                if stored.scrollback.count > self.scrollbackLimit {
                    // Trim at a line boundary. Cutting at an arbitrary byte can
                    // slice an escape sequence or a UTF-8 character in half, and
                    // the replay then feeds a malformed stream into a fresh
                    // parser — which shows up as a mangled first screen.
                    let excess = stored.scrollback.count - self.scrollbackLimit
                    let searchEnd = min(stored.scrollback.count, excess + 4096)
                    let window = stored.scrollback[stored.scrollback.startIndex..<(stored.scrollback.startIndex + searchEnd)]
                    let cut = window.lastIndex(of: UInt8(ascii: "\n")).map { $0 + 1 }
                        ?? (stored.scrollback.startIndex + excess)
                    stored.scrollback.removeSubrange(stored.scrollback.startIndex..<cut)
                }
                self.sessions[spec.id] = stored
                self.broadcast(.output(id: spec.id, base64: data.base64EncodedString()),
                               sessionID: spec.id)
            }
        }
        pty.onExit = { [weak self] code in
            guard let self else { return }
            self.queue.async {
                self.sessions[spec.id]?.isRunning = false
                self.sessions[spec.id]?.exitCode = code
                self.broadcast(.exited(id: spec.id, code: code), sessionID: spec.id)
            }
        }

        do {
            try pty.start(executable: spec.executable, args: spec.args,
                          environment: spec.environment, execName: spec.execName,
                          directory: spec.directory,
                          columns: spec.columns, rows: spec.rows)
        } catch {
            send(.failure(id: spec.id, message: "could not start \(spec.executable)"), to: client)
            return
        }

        sessions[spec.id] = session
        client.attached.insert(spec.id)
        send(.created(id: spec.id, pid: pty.pid), to: client)
    }

    // MARK: - Lifetime

    private func scheduleIdleCheck() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in self?.shutdownIfIdle() }
        timer.resume()
        idleTimer = timer
    }

    /// Exits when there is nothing left to hold on to, so an unused daemon does
    /// not linger forever after the app is gone.
    private func shutdownIfIdle() {
        sessions = sessions.filter { $0.value.isRunning }
        guard sessions.isEmpty, clients.isEmpty else { return }
        unlink(SessionSocket.path)
        exit(0)
    }
}

// Detach from the launching process so quitting the app cannot take this down.
setsid()
signal(SIGPIPE, SIG_IGN)
SessionDaemon().run()
