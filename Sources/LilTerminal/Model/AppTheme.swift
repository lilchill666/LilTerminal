import Foundation
import AppKit
import SwiftUI

/// A colour scheme, stored as hex strings so a theme file is human-readable,
/// diffable, and pasteable into a chat message — which is what makes sharing work.
struct AppTheme: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var isDark: Bool = true
    /// Built-ins cannot be edited in place; editing one forks a copy.
    var isBuiltIn: Bool = false

    var background: String
    var foreground: String
    var cursor: String
    var selection: String
    var accent: String
    /// Exactly 16 entries: ANSI 0-7 then their bright variants.
    var ansi: [String]

    /// Turns off blur, glass, transparency and rounded chrome while active.
    ///
    /// A period look falls apart the moment it is put behind frosted glass, so
    /// a theme is allowed to say "not on me". The settings it displaces are
    /// saved and handed back when another theme takes over.
    var disablesEffects: Bool = false
    /// Draws CRT scanlines over the terminal.
    var scanlines: Bool = false
    /// Blooms the glyphs into the background, the way phosphor does.
    var glow: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, name, isDark, background, foreground, cursor, selection, accent, ansi
        case disablesEffects, scanlines, glow
        // isBuiltIn is deliberately not encoded: an exported built-in becomes
        // an ordinary editable theme on the machine that imports it.
    }

    init(id: UUID = UUID(), name: String, isDark: Bool = true, isBuiltIn: Bool = false,
         background: String, foreground: String, cursor: String, selection: String,
         accent: String, ansi: [String],
         disablesEffects: Bool = false, scanlines: Bool = false, glow: Bool = false) {
        self.id = id
        self.name = name
        self.isDark = isDark
        self.isBuiltIn = isBuiltIn
        self.background = background
        self.foreground = foreground
        self.cursor = cursor
        self.selection = selection
        self.accent = accent
        self.ansi = ansi
        self.disablesEffects = disablesEffects
        self.scanlines = scanlines
        self.glow = glow
    }

    /// Written by hand so that a theme saved before a field existed still
    /// decodes. The synthesised version throws on a missing key, and one throw
    /// here fails the whole settings document and resets everything.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        isDark = try container.decodeIfPresent(Bool.self, forKey: .isDark) ?? true
        background = try container.decode(String.self, forKey: .background)
        foreground = try container.decode(String.self, forKey: .foreground)
        cursor = try container.decode(String.self, forKey: .cursor)
        selection = try container.decode(String.self, forKey: .selection)
        accent = try container.decode(String.self, forKey: .accent)
        ansi = try container.decode([String].self, forKey: .ansi)
        disablesEffects = try container.decodeIfPresent(Bool.self, forKey: .disablesEffects) ?? false
        scanlines = try container.decodeIfPresent(Bool.self, forKey: .scanlines) ?? false
        glow = try container.decodeIfPresent(Bool.self, forKey: .glow) ?? false
        isBuiltIn = false
    }

    var isValid: Bool {
        ansi.count == 16 && HexColor.parse(background) != nil && HexColor.parse(foreground) != nil
    }
}

/// Hex <-> colour conversion shared by the AppKit UI and the terminal palette.
enum HexColor {
    static func parse(_ hex: String) -> (r: Double, g: Double, b: Double)? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        // Accept the #rgb shorthand people hand-write in theme files.
        if s.count == 3 {
            s = s.map { "\($0)\($0)" }.joined()
        }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        return (Double((value >> 16) & 0xff) / 255,
                Double((value >> 8) & 0xff) / 255,
                Double(value & 0xff) / 255)
    }

    static func nsColor(_ hex: String, fallback: NSColor = .black) -> NSColor {
        guard let c = parse(hex) else { return fallback }
        return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
    }

    static func swiftUI(_ hex: String, fallback: SwiftUI.Color = .gray) -> SwiftUI.Color {
        guard let c = parse(hex) else { return fallback }
        return SwiftUI.Color(.sRGB, red: c.r, green: c.g, blue: c.b)
    }

    static func string(from color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        return String(format: "#%02X%02X%02X",
                      Int(round(c.redComponent * 255)),
                      Int(round(c.greenComponent * 255)),
                      Int(round(c.blueComponent * 255)))
    }
}

extension AppTheme {
    static let lilDark = AppTheme(
        id: UUID(uuidString: "11111111-0000-4000-A000-000000000001")!,
        name: "Lil Dark", isDark: true, isBuiltIn: true,
        background: "#121214", foreground: "#DEE0E6",
        cursor: "#6699FF", selection: "#3F4A66", accent: "#6699FF",
        ansi: ["#1A1A1E", "#E5686B", "#73B77F", "#D9B865",
               "#6699FF", "#B98BD9", "#63BFC4", "#C8CBD4",
               "#4A4A52", "#FF8A8D", "#8FD69B", "#F0D183",
               "#8FB3FF", "#D0A9F0", "#82DADF", "#F0F2F7"])

    static let tokyoNight = AppTheme(
        id: UUID(uuidString: "11111111-0000-4000-A000-000000000002")!,
        name: "Tokyo Night", isDark: true, isBuiltIn: true,
        background: "#1A1B26", foreground: "#C0CAF5",
        cursor: "#7AA2F7", selection: "#33467C", accent: "#7AA2F7",
        ansi: ["#15161E", "#F7768E", "#9ECE6A", "#E0AF68",
               "#7AA2F7", "#BB9AF7", "#7DCFFF", "#A9B1D6",
               "#414868", "#F7768E", "#9ECE6A", "#E0AF68",
               "#7AA2F7", "#BB9AF7", "#7DCFFF", "#C0CAF5"])

    static let nord = AppTheme(
        id: UUID(uuidString: "11111111-0000-4000-A000-000000000003")!,
        name: "Nord", isDark: true, isBuiltIn: true,
        background: "#2E3440", foreground: "#D8DEE9",
        cursor: "#88C0D0", selection: "#434C5E", accent: "#88C0D0",
        ansi: ["#3B4252", "#BF616A", "#A3BE8C", "#EBCB8B",
               "#81A1C1", "#B48EAD", "#88C0D0", "#E5E9F0",
               "#4C566A", "#BF616A", "#A3BE8C", "#EBCB8B",
               "#81A1C1", "#B48EAD", "#8FBCBB", "#ECEFF4"])

    static let solarizedDark = AppTheme(
        id: UUID(uuidString: "11111111-0000-4000-A000-000000000004")!,
        name: "Solarized Dark", isDark: true, isBuiltIn: true,
        background: "#002B36", foreground: "#93A1A1",
        cursor: "#93A1A1", selection: "#073642", accent: "#268BD2",
        ansi: ["#073642", "#DC322F", "#859900", "#B58900",
               "#268BD2", "#D33682", "#2AA198", "#EEE8D5",
               "#002B36", "#CB4B16", "#586E75", "#657B83",
               "#839496", "#6C71C4", "#93A1A1", "#FDF6E3"])

    static let paper = AppTheme(
        id: UUID(uuidString: "11111111-0000-4000-A000-000000000005")!,
        name: "Paper", isDark: false, isBuiltIn: true,
        background: "#FBFBFA", foreground: "#2A2A2E",
        cursor: "#2A6DD9", selection: "#CFE0F7", accent: "#2A6DD9",
        ansi: ["#2A2A2E", "#B32F2A", "#2F6B36", "#7D5600",
               "#2A6DD9", "#7B3FB0", "#0B7276", "#7A7A80",
               "#57575C", "#8F2420", "#245A2A", "#664600",
               "#1F55B0", "#5F2F8C", "#08595C", "#4A4A50"])

    /// A P1 phosphor monitor.
    ///
    /// P1 is zinc silicate and it is not the pure green people reach for — it
    /// sits noticeably yellow, around 525 nm. The glass is not black either: an
    /// unlit CRT is dark warm grey, and the faint green cast in the background
    /// here is the phosphor idling, not a tint. The ramp is monochrome because
    /// the tube had one phosphor — "red" and "blue" could only ever be brighter
    /// or dimmer green — and the whole thing glows, because that is most of the
    /// difference between a real green screen and green text on black.
    static let phosphor = AppTheme(
        id: UUID(uuidString: "11111111-0000-4000-A000-000000000006")!,
        name: "Phosphor", isDark: true, isBuiltIn: true,
        background: "#0B0F0A", foreground: "#4AFF52",
        cursor: "#B6FFB0", selection: "#1C4A1E", accent: "#7CFF6E",
        ansi: ["#111A10", "#2FA835", "#4AFF52", "#3FE045",
               "#289A2C", "#57FF5E", "#6BFF72", "#9BFF9E",
               "#1A3318", "#7CFF80", "#98FF9B", "#8AFF8D",
               "#66FF6C", "#A8FFAA", "#BEFFC0", "#E4FFE5"],
        disablesEffects: true, scanlines: true, glow: true)

    /// A RobCo terminal: the wasteland's idea of a computer.
    ///
    /// Deliberately not the same green as Phosphor. Where a P1 tube runs
    /// yellow, this one runs cold and toxic — a cyan-leaning green pushed far
    /// past anything a real monitor produced, over a green-black that is closer
    /// to bottle glass than to grey. Heavy bloom, because in that world every
    /// screen is overdriven.
    static let falloutTerminal = AppTheme(
        id: UUID(uuidString: "11111111-0000-4000-A000-000000000008")!,
        name: "RobCo", isDark: true, isBuiltIn: true,
        background: "#04140B", foreground: "#1AFF8C",
        cursor: "#8CFFC6", selection: "#0C4A2C", accent: "#22FFA0",
        ansi: ["#08210F", "#12B865", "#1AFF8C", "#16DC79",
               "#0FA35C", "#25FF97", "#3BFFA8", "#7FFFC8",
               "#0C3318", "#4BFFA6", "#6BFFBA", "#5AFFAF",
               "#33FF9E", "#8CFFCC", "#A6FFD8", "#DBFFEC"],
        disablesEffects: true, scanlines: true, glow: true)

    /// Miami, about 1985: a hot night, neon on wet tarmac.
    ///
    /// The one retro theme that keeps the effects on — chrome and glass are the
    /// point here, and neon over a blurred background is exactly the look.
    static let miami = AppTheme(
        id: UUID(uuidString: "11111111-0000-4000-A000-000000000009")!,
        name: "Miami", isDark: true, isBuiltIn: true,
        background: "#1B0B2E", foreground: "#F2E3FF",
        cursor: "#00E5FF", selection: "#57277A", accent: "#FF3D9A",
        ansi: ["#2A1245", "#FF3D9A", "#3DFFB8", "#FFB03D",
               "#5B8CFF", "#C46BFF", "#00E5FF", "#D9C6EE",
               "#4A2470", "#FF74B8", "#75FFD1", "#FFC978",
               "#8FB2FF", "#DA9DFF", "#6BF0FF", "#FFFFFF"])

    /// Coals in a stove: warm dark, everything lit from one source.
    static let ember = AppTheme(
        id: UUID(uuidString: "11111111-0000-4000-A000-00000000000A")!,
        name: "Ember", isDark: true, isBuiltIn: true,
        background: "#17110E", foreground: "#EDDCCB",
        cursor: "#FF9245", selection: "#4A3324", accent: "#FF9245",
        ansi: ["#241A15", "#E05A3C", "#9CA84E", "#E8A33D",
               "#C97B4A", "#C4707E", "#5FA394", "#C8B6A3",
               "#3A2A21", "#FF7A5C", "#BFCC6A", "#FFC463",
               "#E39A6B", "#E38FA0", "#7FC4B4", "#F7EADC"])

    /// Drafting paper: white ink on blue, and nothing else.
    ///
    /// Flat by design — a blueprint is a matte print, so glass and blur would be
    /// the one thing that breaks it. No glow: this is ink, not light.
    static let blueprint = AppTheme(
        id: UUID(uuidString: "11111111-0000-4000-A000-00000000000B")!,
        name: "Blueprint", isDark: true, isBuiltIn: true,
        background: "#0E2A4A", foreground: "#DCE9F7",
        cursor: "#FFFFFF", selection: "#1E4E7E", accent: "#7FC4FF",
        ansi: ["#16375C", "#FF9E9E", "#A8E6C0", "#FFE1A3",
               "#7FC4FF", "#C9B6FF", "#9FE8F0", "#C3D6E8",
               "#245380", "#FFBDBD", "#C6F2D8", "#FFEFC8",
               "#A9D8FF", "#DDD0FF", "#C4F2F7", "#FFFFFF"],
        disablesEffects: true)

    /// Late blossom under a grey sky: a light theme that is not white.
    static let sakura = AppTheme(
        id: UUID(uuidString: "11111111-0000-4000-A000-00000000000C")!,
        name: "Sakura", isDark: false, isBuiltIn: true,
        background: "#FBF2F4", foreground: "#4A3540",
        cursor: "#C2477A", selection: "#F2D3DE", accent: "#C2477A",
        // Same rule as Beige Box: the bright row darkens on a light background.
        ansi: ["#4A3540", "#B23A6E", "#4E7A52", "#96651F",
               "#42639C", "#7A4C98", "#357878", "#7A6A72",
               "#5B4450", "#C24A80", "#3F6B44", "#7E5518",
               "#37548A", "#684087", "#2C6666", "#2E2028"])

    /// The beige box: a plastic-cased machine under office light. Warm grey-white
    /// screen, ink-dark text, and a palette mixed from printer ribbon rather than
    /// from a phosphor — nothing saturated, because nothing on that hardware was.
    static let beigeBox = AppTheme(
        id: UUID(uuidString: "11111111-0000-4000-A000-000000000007")!,
        name: "Beige Box", isDark: false, isBuiltIn: true,
        background: "#D9D4C4", foreground: "#2B2822",
        cursor: "#2B2822", selection: "#B6AF98", accent: "#8A6F3C",
        // On a light screen the "bright" row has to go darker, not lighter: a
        // program printing bright white is printing body text, and #F2EEE2 on
        // beige is 1.3:1 — invisible.
        ansi: ["#2B2822", "#8E3327", "#3C5A2E", "#7A6032",
               "#35506B", "#5F3F63", "#35605D", "#6B6558",
               "#4A463C", "#A34433", "#476B38", "#8A6E30",
               "#3F5F85", "#734D77", "#3F736F", "#1F1C17"],
        disablesEffects: true, scanlines: false)

    /// Built-in IDs are fixed constants, not fresh UUIDs. A generated id would
    /// differ on every launch, so the saved "active theme" would never match
    /// and the app would silently reset to the default each time it started.
    static let builtIns: [AppTheme] = [
        lilDark, tokyoNight, nord, solarizedDark, paper,
        phosphor, falloutTerminal, beigeBox, blueprint,
        miami, ember, sakura,
    ]
}

/// Owns the theme list, the active selection, and import/export.
@MainActor
final class ThemeStore: ObservableObject {
    @Published private(set) var custom: [AppTheme] = []
    @Published var active: AppTheme = .lilDark

    var all: [AppTheme] { AppTheme.builtIns + custom }

    init() {
        custom = SettingsStore.shared.document.themes
        if let savedID = SettingsStore.shared.document.activeThemeID,
           let uuid = UUID(uuidString: savedID),
           let match = all.first(where: { $0.id == uuid }) {
            active = match
        }
    }

    func activate(_ theme: AppTheme) {
        active = theme
        SettingsStore.shared.update { $0.activeThemeID = theme.id.uuidString }
    }

    /// Editing a built-in forks it, so the shipped presets always stay intact.
    @discardableResult
    func makeEditableCopy(of theme: AppTheme) -> AppTheme {
        var copy = theme
        copy.id = UUID()
        copy.isBuiltIn = false
        copy.name = uniqueName(theme.isBuiltIn ? "\(theme.name) Copy" : "\(theme.name) Copy")
        custom.append(copy)
        save()
        return copy
    }

    func update(_ theme: AppTheme) {
        guard let index = custom.firstIndex(where: { $0.id == theme.id }) else { return }
        custom[index] = theme
        if active.id == theme.id { active = theme }
        save()
    }

    func delete(_ theme: AppTheme) {
        custom.removeAll { $0.id == theme.id }
        if active.id == theme.id { active = .lilDark }
        save()
    }

    func add(_ theme: AppTheme) {
        var incoming = theme
        incoming.isBuiltIn = false
        // A re-import of the same theme should replace, not accumulate duplicates.
        if let index = custom.firstIndex(where: { $0.id == incoming.id }) {
            custom[index] = incoming
        } else {
            if all.contains(where: { $0.name == incoming.name }) {
                incoming.name = uniqueName(incoming.name)
            }
            custom.append(incoming)
        }
        save()
    }

    private func uniqueName(_ base: String) -> String {
        var name = base
        var counter = 2
        while all.contains(where: { $0.name == name }) {
            name = "\(base) \(counter)"
            counter += 1
        }
        return name
    }

    private func save() { SettingsStore.shared.update { $0.themes = custom } }

    // MARK: - Sharing

    static func encode(_ theme: AppTheme) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(theme) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(_ json: String) -> AppTheme? {
        guard let data = json.data(using: .utf8),
              var theme = try? JSONDecoder().decode(AppTheme.self, from: data),
              theme.isValid else { return nil }
        theme.isBuiltIn = false
        return theme
    }

    func copyToPasteboard(_ theme: AppTheme) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.encode(theme), forType: .string)
    }

    /// Returns nil when the clipboard holds no valid theme, so the caller can
    /// tell the user rather than silently doing nothing.
    @discardableResult
    func importFromPasteboard() -> AppTheme? {
        guard let text = NSPasteboard.general.string(forType: .string),
              let theme = Self.decode(text) else { return nil }
        add(theme)
        return theme
    }

    func exportToFile(_ theme: AppTheme) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(theme.name).lilterminal-theme.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? Self.encode(theme).write(to: url, atomically: true, encoding: .utf8)
    }

    @discardableResult
    func importFromFile() -> AppTheme? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8),
              let theme = Self.decode(text) else { return nil }
        add(theme)
        return theme
    }
}

extension AppTheme {
    /// Window chrome: the background nudged toward the text colour. Deriving it
    /// from the theme is what keeps the sidebar and titlebar from looking like
    /// they belong to a different app than the terminal.
    var chrome: SwiftUI.Color { HexColor.blend(background, toward: foreground, amount: 0.06) }
    var chromeElevated: SwiftUI.Color { HexColor.blend(background, toward: foreground, amount: 0.10) }
    var hairline: SwiftUI.Color { HexColor.blend(background, toward: foreground, amount: 0.18) }
    var colorScheme: ColorScheme { isDark ? .dark : .light }

    // Text tiers are derived from the theme's own foreground rather than
    // SwiftUI's .primary/.secondary. Semantic colours track the system
    // appearance, not this palette, so on a custom background they can land at
    // unreadable contrast. Deriving them guarantees a known ratio.
    var textPrimary: SwiftUI.Color { HexColor.swiftUI(foreground) }
    var textSecondary: SwiftUI.Color { HexColor.swiftUI(foreground).opacity(0.74) }
    var textTertiary: SwiftUI.Color { HexColor.swiftUI(foreground).opacity(0.54) }

    var selectionFill: SwiftUI.Color { HexColor.swiftUI(accent).opacity(0.18) }
    var selectionStroke: SwiftUI.Color { HexColor.swiftUI(accent).opacity(0.38) }
    var hoverFill: SwiftUI.Color { HexColor.swiftUI(foreground).opacity(0.07) }
    var accentColor: SwiftUI.Color { HexColor.swiftUI(accent) }

    /// The window behind the floating panels. Deliberately a shade deeper than
    /// the terminal so the panels read as lifted off it rather than merging
    /// into one flat field.
    var windowBase: SwiftUI.Color {
        isDark ? HexColor.blend(background, toward: "#000000", amount: 0.45)
               : HexColor.blend(background, toward: "#000000", amount: 0.17)
    }
}

/// WCAG relative luminance and contrast, used by the theme contrast audit.
enum Contrast {
    static func luminance(_ hex: String) -> Double {
        guard let c = HexColor.parse(hex) else { return 0 }
        func channel(_ v: Double) -> Double {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
    }

    /// Contrast ratio between two hex colours, 1.0 (identical) to 21.0.
    static func ratio(_ a: String, _ b: String) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        let (hi, lo) = (max(la, lb), min(la, lb))
        return (hi + 0.05) / (lo + 0.05)
    }
}

extension HexColor {
    static func blend(_ base: String, toward other: String, amount: Double) -> SwiftUI.Color {
        guard let a = parse(base), let b = parse(other) else { return .gray }
        return SwiftUI.Color(.sRGB,
                             red: a.r + (b.r - a.r) * amount,
                             green: a.g + (b.g - a.g) * amount,
                             blue: a.b + (b.b - a.b) * amount)
    }
}
