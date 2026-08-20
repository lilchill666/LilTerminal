import Foundation

struct GitInfo: Equatable {
    var branch: String
    var isDirty: Bool
}

/// Resolves the git branch for a directory, off the main thread and cached.
///
/// Every tab asking git about the same repo on every metrics tick would be
/// wasteful, so results are cached per directory and refreshed on an interval.
/// Directories with no repo are cached as misses too — that is the common case
/// for a home-directory shell and should cost nothing to repeat.
actor GitStatusCache {
    static let shared = GitStatusCache()

    private struct Entry {
        var info: GitInfo?
        var checkedAt: Date
    }

    private var cache: [String: Entry] = [:]
    private let ttl: TimeInterval = 5

    func status(for directory: String) -> GitInfo? {
        if let entry = cache[directory], Date().timeIntervalSince(entry.checkedAt) < ttl {
            return entry.info
        }
        let info = Self.read(directory)
        cache[directory] = Entry(info: info, checkedAt: Date())
        return info
    }

    private static func read(_ directory: String) -> GitInfo? {
        guard FileManager.default.fileExists(atPath: directory) else { return nil }
        // --porcelain=v2 --branch gives branch and dirtiness in one invocation.
        guard let output = run(["-C", directory, "status", "--porcelain=v2", "--branch"]) else {
            return nil
        }
        var branch: String?
        var dirty = false
        for line in output.split(separator: "\n") {
            if line.hasPrefix("# branch.head ") {
                branch = String(line.dropFirst("# branch.head ".count))
            } else if !line.hasPrefix("#") {
                dirty = true
            }
        }
        guard let branch, branch != "(detached)" else {
            return branch.map { GitInfo(branch: $0, isDirty: dirty) }
        }
        return GitInfo(branch: branch, isDirty: dirty)
    }

    private static func run(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        // A hung git would otherwise stall the caller; the environment is
        // trimmed so it cannot pick up a pager or prompt for credentials.
        process.environment = ["PATH": "/usr/bin:/bin", "GIT_OPTIONAL_LOCKS": "0",
                               "GIT_TERMINAL_PROMPT": "0"]
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
