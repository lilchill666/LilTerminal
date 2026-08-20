import Foundation

/// A shell we are willing to launch.
struct Shell: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let name: String

    /// Login-shell argv. `-l` gets the user's real environment (PATH from
    /// /etc/paths.d, Homebrew shellenv, nvm, etc.) instead of the sparse one a
    /// GUI app inherits from launchd.
    var loginArgs: [String] {
        switch name {
        case "fish": return ["-l"]
        default:     return ["-l"]
        }
    }
}

/// Discovers installed shells at runtime rather than hardcoding a list, so a
/// shell installed after the app was built (`brew install fish`) shows up on
/// next launch without a rebuild.
enum ShellCatalog {
    /// Ordered by preference: the user's login shell first, then fish, then the rest.
    static func discover() -> [Shell] {
        var seen = Set<String>()
        var found: [Shell] = []

        func consider(_ path: String) {
            let resolved = (path as NSString).resolvingSymlinksInPath
            guard !seen.contains(resolved),
                  FileManager.default.isExecutableFile(atPath: path) else { return }
            seen.insert(resolved)
            found.append(Shell(path: path, name: (path as NSString).lastPathComponent))
        }

        // Homebrew and other non-system prefixes are checked explicitly: a
        // freshly installed fish is not in /etc/shells until `add-shell` runs.
        let extraPaths = [
            "/opt/homebrew/bin/fish", "/usr/local/bin/fish",
            "/opt/homebrew/bin/zsh",  "/usr/local/bin/zsh",
            "/opt/homebrew/bin/bash", "/usr/local/bin/bash",
            "/opt/homebrew/bin/nu",   "/usr/local/bin/nu",
        ]

        for path in extraPaths { consider(path) }

        if let etc = try? String(contentsOfFile: "/etc/shells", encoding: .utf8) {
            for line in etc.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
                consider(trimmed)
            }
        }

        let login = loginShellPath()
        return found.sorted { a, b in
            func rank(_ s: Shell) -> Int {
                if s.path == login { return 0 }
                if s.name == "fish" { return 1 }
                if s.name == "zsh"  { return 2 }
                if s.name == "bash" { return 3 }
                return 4
            }
            let (ra, rb) = (rank(a), rank(b))
            return ra == rb ? a.path < b.path : ra < rb
        }
    }

    /// The user's configured login shell, via getpwuid rather than $SHELL —
    /// a GUI app launched from Finder does not reliably inherit $SHELL.
    static func loginShellPath() -> String {
        if let pw = getpwuid(getuid()), let sh = pw.pointee.pw_shell {
            return String(cString: sh)
        }
        return "/bin/zsh"
    }

    static var `default`: Shell {
        let path = loginShellPath()
        return Shell(path: path, name: (path as NSString).lastPathComponent)
    }
}
