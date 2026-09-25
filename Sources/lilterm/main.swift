import Foundation
import Darwin
import TerminalCore

/// `lilterm` — reach LilTerminal's live tabs from anywhere you have a shell (SSH from a phone).
///
///   lilterm ls                     every live tab: number, name, id, pid, age
///   lilterm attach <tab>           join that tab: its recent output replays, your typing goes
///                                  into the same shell, the desktop window keeps showing it too.
///                                  <tab> = number from `ls`, a name (or part of it), or an id prefix.
///                                  Ctrl-] detaches (the tab keeps running).
///   lilterm attach <tab> --resize  also resize the tab to this terminal (the desktop view reflows)
///
/// It talks to `lilterm-sessiond` over its socket — the daemon already lets several clients attach
/// to one session and broadcasts output to all of them, so this is just another client.

let detachKey: UInt8 = 0x1D  // Ctrl-]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("lilterm: \(message)\n".data(using: .utf8)!)
    exit(1)
}

func connectDaemon() -> Int32 {
    let path = SessionSocket.path
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { fail("socket() failed") }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    var pathBytes = [CChar](repeating: 0, count: capacity)
    path.withCString { source in _ = strncpy(&pathBytes, source, capacity - 1) }
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        raw.copyBytes(from: UnsafeRawBufferPointer(start: pathBytes, count: capacity))
    }
    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    let ok = withUnsafePointer(to: &address) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, size) }
    }
    guard ok == 0 else {
        fail("LilTerminal's session daemon isn't running — open LilTerminal (with persistent sessions on) first")
    }
    return fd
}

func sendMessage(_ fd: Int32, _ message: ClientMessage) {
    guard let data = encodeLine(message) else { return }
    data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        var offset = 0
        while offset < raw.count {
            let n = write(fd, base + offset, raw.count - offset)
            if n <= 0 { break }
            offset += n
        }
    }
}

/// Reads server messages until [until] returns true.
func readMessages(_ fd: Int32, until: (ServerMessage) -> Bool) {
    var framer = LineFramer()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let n = read(fd, &buffer, buffer.count)
        if n <= 0 { return }
        for line in framer.append(Data(buffer.prefix(n))) {
            guard let m = try? JSONDecoder().decode(ServerMessage.self, from: line) else { continue }
            if until(m) { return }
        }
    }
}

func listSessions() -> [SessionSummary] {
    let fd = connectDaemon()
    defer { close(fd) }
    sendMessage(fd, .list)
    var result: [SessionSummary] = []
    readMessages(fd) { m in
        if case .sessions(let list) = m { result = list; return true }
        return false
    }
    return result.filter(\.isRunning).sorted { $0.startedAt < $1.startedAt }
}

func age(_ date: Date) -> String {
    let s = Int(Date().timeIntervalSince(date))
    if s < 3600 { return "\(s / 60)m" }
    if s < 86400 { return "\(s / 3600)h\(String(format: "%02d", (s % 3600) / 60))" }
    return "\(s / 86400)d"
}

func printList(_ sessions: [SessionSummary]) {
    if sessions.isEmpty { print("no live tabs"); return }
    for (i, s) in sessions.enumerated() {
        let name = (s.title?.isEmpty == false ? s.title! : "(unnamed)")
        print(String(format: "%2d  %-40@  %@  pid %d  %@", i + 1, String(name.prefix(40)) as NSString,
                     String(s.id.prefix(8)) as NSString, s.pid, age(s.startedAt) as NSString))
    }
}

func resolve(_ selector: String, in sessions: [SessionSummary]) -> SessionSummary {
    if let n = Int(selector), n >= 1, n <= sessions.count { return sessions[n - 1] }
    if let exact = sessions.first(where: { $0.id == selector }) { return exact }
    let byID = sessions.filter { $0.id.hasPrefix(selector) }
    if byID.count == 1 { return byID[0] }
    let byName = sessions.filter { ($0.title ?? "").localizedCaseInsensitiveContains(selector) }
    if byName.count == 1 { return byName[0] }
    if byName.count > 1 || byID.count > 1 {
        printList(byName.isEmpty ? byID : byName)
        fail("'\(selector)' matches several tabs — use the number or a longer name")
    }
    fail("no live tab matches '\(selector)' — see `lilterm ls`")
}

// MARK: - attach

var savedTermios = termios()
var rawMode = false

func enterRaw() {
    guard isatty(STDIN_FILENO) != 0 else { return }
    tcgetattr(STDIN_FILENO, &savedTermios)
    var raw = savedTermios
    cfmakeraw(&raw)
    tcsetattr(STDIN_FILENO, TCSANOW, &raw)
    rawMode = true
}

func restoreTerminal() {
    if rawMode { tcsetattr(STDIN_FILENO, TCSANOW, &savedTermios); rawMode = false }
}

func windowSize() -> (UInt16, UInt16)? {
    var w = winsize()
    guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &w) == 0, w.ws_col > 0, w.ws_row > 0 else { return nil }
    return (w.ws_col, w.ws_row)
}

func attach(_ session: SessionSummary, resize: Bool) -> Never {
    let fd = connectDaemon()
    let name = session.title ?? String(session.id.prefix(8))
    FileHandle.standardError.write("[attached to \(name) — Ctrl-] detaches; the tab keeps running]\r\n".data(using: .utf8)!)
    enterRaw()
    atexit { restoreTerminal() }
    sendMessage(fd, .attach(id: session.id))
    if resize, let (c, r) = windowSize() { sendMessage(fd, .resize(id: session.id, columns: c, rows: r)) }
    if resize {
        signal(SIGWINCH, SIG_IGN)  // delivered to the DispatchSource instead
        let winch = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .global())
        winch.setEventHandler {
            if let (c, r) = windowSize() { sendMessage(fd, .resize(id: session.id, columns: c, rows: r)) }
        }
        winch.resume()
        _winch = winch  // kept alive for the whole attach
    }

    // Daemon → screen.
    Thread.detachNewThread {
        readMessages(fd) { m in
            switch m {
            case .output(let id, let b64) where id == session.id:
                if let data = Data(base64Encoded: b64) {
                    data.withUnsafeBytes { raw in _ = write(STDOUT_FILENO, raw.baseAddress, raw.count) }
                }
            case .exited(let id, let code) where id == session.id:
                restoreTerminal()
                FileHandle.standardError.write("\r\n[the tab's shell exited (\(code.map(String.init) ?? "?"))]\r\n".data(using: .utf8)!)
                exit(0)
            case .failure(_, let message):
                restoreTerminal()
                fail(message)
            default: break
            }
            return false
        }
        restoreTerminal()
        FileHandle.standardError.write("\r\n[daemon closed the connection]\r\n".data(using: .utf8)!)
        exit(1)
    }

    // Keyboard → shell. Ctrl-] detaches.
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(STDIN_FILENO, &buffer, buffer.count)
        if n <= 0 { break }
        var chunk = Array(buffer.prefix(n))
        if let i = chunk.firstIndex(of: detachKey) {
            chunk = Array(chunk.prefix(i))
            if !chunk.isEmpty { sendMessage(fd, .write(id: session.id, base64: Data(chunk).base64EncodedString())) }
            break
        }
        sendMessage(fd, .write(id: session.id, base64: Data(chunk).base64EncodedString()))
    }
    sendMessage(fd, .detach(id: session.id))
    restoreTerminal()
    FileHandle.standardError.write("\r\n[detached — the tab keeps running]\r\n".data(using: .utf8)!)
    close(fd)
    exit(0)
}

var _winch: DispatchSourceSignal?

// MARK: - main

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "ls", "list", nil:
    printList(listSessions())
case "attach", "a":
    guard args.count >= 2 else { fail("usage: lilterm attach <tab> [--resize]   (see `lilterm ls`)") }
    let resize = args.contains("--resize")
    let selector = args.dropFirst().filter { $0 != "--resize" }.joined(separator: " ")
    attach(resolve(selector, in: listSessions()), resize: resize)
case "-h", "--help", "help":
    print("""
    lilterm ls                     list LilTerminal's live tabs
    lilterm attach <tab>           join a tab (number, name or id prefix); Ctrl-] detaches
    lilterm attach <tab> --resize  also resize the tab to this terminal
    """)
default:
    fail("unknown command '\(args[0])' — try `lilterm help`")
}
