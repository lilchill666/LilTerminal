import Foundation
import AppKit

/// Everything the user configured, in one document.
struct SettingsDocument: Codable {
    var version = 1
    var preferences = Preferences()
    var themes: [AppTheme] = []
    var snippets: [Snippet] = Snippet.starterPack
    var groups: [TabGroup] = []
    var activeThemeID: String?
    var appIsLocked = false
    var savedAt = Date()
}

/// Owns where settings live and how they survive.
///
/// One JSON file rather than UserDefaults, because `~/Library/Preferences` is
/// the first thing an uninstaller clears and the last thing a person thinks to
/// back up. The keychain holds a mirror so a reinstall can recover even when
/// the support folder is gone too.
@MainActor
final class SettingsStore {
    static let shared = SettingsStore()

    private(set) var document = SettingsDocument()
    private var saveWorkItem: DispatchWorkItem?
    private var keychainWorkItem: DispatchWorkItem?

    nonisolated static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LilTerminal", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    nonisolated static var fileURL: URL { directory.appendingPathComponent("settings.json") }

    /// Where the settings came from this launch, for the UI to report honestly.
    private(set) var origin = "defaults"

    private init() {
        document = Self.loadDocument(reportingOriginTo: &origin)
        // Anything not already in the settings file gets written out at once —
        // a migration or a keychain restore that only persists on the next
        // change would be lost to a crash before then.
        if origin != "settings.json" { writeNow() }
    }

    // MARK: - Loading

    private static func loadDocument(reportingOriginTo origin: inout String) -> SettingsDocument {
        if let data = try? Data(contentsOf: fileURL), let decoded = decode(data) {
            origin = "settings.json"
            return decoded
        }
        // The file is gone — a reinstall, or a cleaner removed the folder.
        if let data = Keychain.load(), let decoded = decode(data) {
            origin = "keychain backup"
            return decoded
        }
        if let migrated = migrateFromLegacyStores() {
            origin = "migrated from previous version"
            return migrated
        }
        origin = "defaults"
        return SettingsDocument()
    }

    /// Merges over defaults so a document written by an older version, missing
    /// keys added since, still loads instead of throwing everything away.
    private static func decode(_ data: Data) -> SettingsDocument? {
        if let direct = try? JSONDecoder().decode(SettingsDocument.self, from: data) {
            return direct
        }
        guard let saved = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let defaultsData = try? JSONEncoder().encode(SettingsDocument()),
              let defaults = (try? JSONSerialization.jsonObject(with: defaultsData)) as? [String: Any]
        else { return nil }
        // Recursive: preferences contains four nested bar objects, each of which
        // can gain keys of its own.
        let merged = deepMerge(defaults, saved)
        guard let mergedData = try? JSONSerialization.data(withJSONObject: merged) else { return nil }
        return try? JSONDecoder().decode(SettingsDocument.self, from: mergedData)
    }

    /// Picks up settings written by the UserDefaults-and-loose-files era.
    private static func migrateFromLegacyStores() -> SettingsDocument? {
        var document = SettingsDocument()
        var found = false

        if let data = UserDefaults.standard.data(forKey: Preferences.key) {
            document.preferences = Preferences.decodeMerging(data)
            found = true
        }
        if let id = UserDefaults.standard.string(forKey: "activeThemeID") {
            document.activeThemeID = id
            found = true
        }
        document.appIsLocked = UserDefaults.standard.bool(forKey: "appIsLocked")

        func loadLegacy<T: Decodable>(_ name: String) -> T? {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
            return try? JSONDecoder().decode(T.self, from: data)
        }
        if let themes: [AppTheme] = loadLegacy("themes.json") { document.themes = themes; found = true }
        if let snippets: [Snippet] = loadLegacy("snippets.json") { document.snippets = snippets; found = true }
        if let groups: [TabGroup] = loadLegacy("groups.json") { document.groups = groups; found = true }

        return found ? document : nil
    }

    // MARK: - Saving

    func update(_ change: (inout SettingsDocument) -> Void) {
        change(&document)
        scheduleSave()
    }

    /// Coalesced: a slider drag would otherwise write the file on every frame.
    private func scheduleSave() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.writeNow() }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func writeNow() {
        document.savedAt = Date()
        guard let data = try? JSONEncoder().encode(document) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
        scheduleKeychainMirror(data)
    }

    /// The keychain mirror lags further behind: it is disaster recovery, not
    /// the working store, and writing it on every change is wasteful.
    private func scheduleKeychainMirror(_ data: Data) {
        guard document.preferences.keychainBackup else { return }
        keychainWorkItem?.cancel()
        let work = DispatchWorkItem { _ = Keychain.save(data) }
        keychainWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    // MARK: - Explicit backup and transfer

    @discardableResult
    func backupToKeychainNow() -> Bool {
        guard let data = try? JSONEncoder().encode(document) else { return false }
        return Keychain.save(data)
    }

    func restoreFromKeychain() -> Bool {
        guard let data = Keychain.load(), let decoded = Self.decode(data) else { return false }
        document = decoded
        writeNow()
        return true
    }

    func exportToFile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "LilTerminal Settings.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? JSONEncoder().encode(document) else { return }
        try? data.write(to: url, options: .atomic)
    }

    @discardableResult
    func importFromFile() -> Bool {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url),
              let decoded = Self.decode(data) else { return false }
        document = decoded
        writeNow()
        return true
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Self.fileURL])
    }
}
