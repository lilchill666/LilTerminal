import Foundation
import SwiftUI

/// How tightly the UI is packed. Density drives one spacing scale rather than
/// letting each view invent its own padding — that consistency is most of what
/// reads as "designed" versus "assembled".
enum Density: String, Codable, CaseIterable, Identifiable {
    case compact, comfortable, spacious
    var id: String { rawValue }

    var label: String { rawValue.capitalized }

    var rowPaddingV: CGFloat  { self == .compact ? 3.5 : self == .comfortable ? 5.5 : 8 }
    var rowPaddingH: CGFloat  { self == .compact ? 6 : self == .comfortable ? 7 : 9 }
    var rowSpacing: CGFloat   { self == .compact ? 1 : self == .comfortable ? 2 : 4 }
    var sectionGap: CGFloat   { self == .compact ? 6 : self == .comfortable ? 9 : 13 }
    var edgeInset: CGFloat    { self == .compact ? 6 : self == .comfortable ? 8 : 10 }
    var titleSize: CGFloat    { self == .compact ? 11.5 : self == .comfortable ? 12 : 12.5 }
    var subtitleSize: CGFloat { self == .compact ? 9 : self == .comfortable ? 9.5 : 10 }
}

/// Everything the user can turn on, off, or resize. Persisted whole, so the app
/// comes back exactly as they left it.
struct Preferences: Codable, Equatable {
    // Sidebar content
    var showStatusDot = true
    var showCPU = true
    var showMemory = true
    var showSubtitle = true
    var showSplitBadge = true
    var showGitBranch = true
    /// The sidebar filter appears once there are at least this many tabs.
    var tabFilterThreshold: Int = 6
    var showTabFilter = true
    var showGroupSummary = true
    var showSidebarFooter = true
    var showTabCount = true

    // Status bar content
    var showStatusBar = true
    var showStatusShell = true
    var showStatusMetrics = true
    var showThemeButton = true
    var showSnippetsButton = true

    // Background and surfaces
    var backgroundMode: BackgroundMode = .solid
    var backgroundImagePath: String?
    var backgroundImageOpacity: Double = 0.35
    var backgroundImageBlur: Double = 0
    /// Theme colour laid over a blur or image so text stays readable.
    var backgroundTint: Double = 0.35
    var blurStrength: BlurStrength = .medium
    var surfaceStyle: SurfaceStyle = .frosted
    var panelOpacity: Double = 0.55

    // Each bar is painted independently.
    var topBar = BarAppearance()
    var sidebarBar = BarAppearance()
    var inspectorBar = BarAppearance()
    var statusBarAppearance = BarAppearance()
    /// Alpha of the terminal's own background, letting the layer behind show through.
    var terminalOpacity: Double = 1.0
    /// How the terminal card itself is drawn behind the translucent text layer.
    var terminalSurface: SurfaceStyle = .solid
    /// Gap between the terminal text and the edge of its card.
    var terminalPadding: Double = 12
    var terminalBlurStrength: BlurStrength = .medium

    // Feel
    var density: Density = .comfortable
    var animationsEnabled = true
    var animationSpeed: Double = 1.0
    var cornerRadius: Double = 7
    /// Floating panels are much larger than a row, so they carry their own,
    /// bigger radius — reusing the row radius made them look square.
    var panelCornerRadius: Double = 13
    var pillCornerRadius: Double = 11
    var showPaneFocusRing = true
    var showPaneDividers = true

    // Terminal
    var restoreSessions = true
    /// Keep shells running in a helper when the app quits, and reattach on
    /// launch. Off by default: it changes where processes live.
    var persistentSessions = false
    /// Mirror settings into the keychain, so a reinstall can recover them even
    /// if the support folder was removed too.
    var keychainBackup = true
    // Paste guard.
    var pasteGuardEnabled = true
    /// Confirm a paste with at least this many lines.
    var pasteGuardLineThreshold: Int = 2
    /// Confirm a paste containing anything from the risky list.
    var pasteGuardRiskyCommands = true
    /// Announce commands that ran at least this long, in seconds.
    var notifyAfterSeconds: Double = 20
    var notifyOnlyWhenUnfocused = true
    var notificationsEnabled = true

    // AI. Off by default: it is opt-in, and every feature is separately
    // switchable so nothing runs that you did not ask for.
    var aiEnabled = false
    var aiBackend: AIBackendKind = .appleOnDevice
    var aiOllamaModel = "llama3.2:3b"
    var aiActivityEnabled = true
    var aiAutoNameEnabled = true
    var aiTriageEnabled = true
    var aiSearchEnabled = true
    /// Classify only tabs you are not currently looking at.
    var aiSkipFocusedTab = true
    /// Seconds between activity checks for a given tab.
    var aiActivityCooldown: Double = 25
    var fontName: String = "SF Mono"
    var fontSize: Double = 13
    var sidebarWidth: Double = 232
    var inspectorWidth: Double = 260

    static let key = "preferences"

    /// Decodes a saved blob over the defaults.
    ///
    /// Swift's synthesised Decodable throws on any missing key, so without this
    /// merge adding a single preference would invalidate the whole file and
    /// silently reset every choice the user had made.
    static func decodeMerging(_ data: Data) -> Preferences {
        if let direct = try? JSONDecoder().decode(Preferences.self, from: data) { return direct }
        guard let saved = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let defaultsData = try? JSONEncoder().encode(Preferences()),
              let defaults = (try? JSONSerialization.jsonObject(with: defaultsData)) as? [String: Any]
        else { return Preferences() }
        let merged = deepMerge(defaults, saved)
        guard let mergedData = try? JSONSerialization.data(withJSONObject: merged),
              let decoded = try? JSONDecoder().decode(Preferences.self, from: mergedData)
        else { return Preferences() }
        return decoded
    }
}

/// Merges saved values over defaults, recursing into nested objects.
///
/// A shallow merge is not enough: replacing a nested object wholesale
/// reintroduces the very problem it was meant to solve, because that object
/// then lacks any key added since it was written and fails to decode — taking
/// the whole file down with it.
func deepMerge(_ defaults: [String: Any], _ saved: [String: Any]) -> [String: Any] {
    var result = defaults
    for (key, value) in saved {
        if let nestedSaved = value as? [String: Any],
           let nestedDefaults = result[key] as? [String: Any] {
            result[key] = deepMerge(nestedDefaults, nestedSaved)
        } else {
            result[key] = value
        }
    }
    return result
}
