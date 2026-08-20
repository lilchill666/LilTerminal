import Foundation

/// Wire protocol between the app and the session daemon.
///
/// Newline-delimited JSON in both directions. Terminal output is base64 inside
/// those frames: less efficient than a binary channel, but it keeps the whole
/// protocol inspectable with `nc`, which matters a great deal when debugging a
/// daemon that is meant to outlive the app.
public enum SessionSocket {
    public static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LilTerminal", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    public static var path: String {
        directory.appendingPathComponent("sessiond.sock").path
    }
}

public struct SessionSpec: Codable, Sendable {
    public var id: String
    public var executable: String
    public var args: [String]
    public var environment: [String]
    public var execName: String?
    public var directory: String?
    public var columns: UInt16
    public var rows: UInt16

    public init(id: String, executable: String, args: [String], environment: [String],
                execName: String?, directory: String?, columns: UInt16, rows: UInt16) {
        self.id = id
        self.executable = executable
        self.args = args
        self.environment = environment
        self.execName = execName
        self.directory = directory
        self.columns = columns
        self.rows = rows
    }
}

public struct SessionSummary: Codable, Sendable {
    public var id: String
    public var pid: Int32
    public var isRunning: Bool
    public var startedAt: Date

    public init(id: String, pid: Int32, isRunning: Bool, startedAt: Date) {
        self.id = id
        self.pid = pid
        self.isRunning = isRunning
        self.startedAt = startedAt
    }
}

/// App to daemon.
public enum ClientMessage: Codable, Sendable {
    case list
    case create(SessionSpec)
    /// Attach and replay the buffered scrollback for this session.
    case attach(id: String)
    case detach(id: String)
    case write(id: String, base64: String)
    case resize(id: String, columns: UInt16, rows: UInt16)
    case kill(id: String)
    case shutdownIfIdle
}

/// Daemon to app.
public enum ServerMessage: Codable, Sendable {
    case sessions([SessionSummary])
    case created(id: String, pid: Int32)
    case output(id: String, base64: String)
    case exited(id: String, code: Int32?)
    case failure(id: String?, message: String)
}

/// Reads newline-delimited JSON from a file descriptor.
public struct LineFramer {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        while let index = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<index]
            if !line.isEmpty { lines.append(Data(line)) }
            buffer.removeSubrange(buffer.startIndex...index)
        }
        return lines
    }
}

public func encodeLine<T: Encodable>(_ value: T) -> Data? {
    guard var data = try? JSONEncoder().encode(value) else { return nil }
    data.append(UInt8(ascii: "\n"))
    return data
}
