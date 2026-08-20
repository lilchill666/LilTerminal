import SwiftUI
import AppKit

enum Theme {
    static let defaultFontSize: CGFloat = 13

    /// SF Mono is what the system ships for code; Menlo is the guaranteed floor.
    static func monoFont(size: CGFloat, name: String = "SF Mono") -> NSFont {
        NSFont(name: name, size: size)
            ?? NSFont(name: "SF Mono", size: size)
            ?? NSFont(name: "Menlo", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Monospaced faces installed on this machine, for the font picker.
    static func availableMonoFonts() -> [String] {
        let all = NSFontManager.shared.availableFontFamilies.filter { family in
            guard let font = NSFont(name: family, size: 12) else { return false }
            return font.isFixedPitch
        }
        return Array(Set(all + ["SF Mono", "Menlo"])).sorted()
    }

    static func apply(_ theme: AppTheme, to view: GhosttyTerminalView, fontSize: CGFloat,
                      fontName: String = "SF Mono", opacity: Double = 1.0,
                      inset: CGFloat = 12) {
        view.backgroundColor = HexColor.nsColor(theme.background, fallback: .black)
        view.foregroundColor = HexColor.nsColor(theme.foreground, fallback: .white)
        view.cursorColor = HexColor.nsColor(theme.cursor, fallback: .white)
        view.selectionColor = HexColor.nsColor(theme.selection, fallback: .darkGray)
        // The renderer leaves default-background cells unpainted, so this alone
        // makes the terminal translucent — no engine cooperation required.
        view.backgroundOpacity = max(0.05, min(1, opacity))
        view.padding = inset
        view.font = monoFont(size: fontSize, name: fontName)
        view.needsDisplay = true
    }

    /// Green through red by load. Deliberately desaturated: these are ambient
    /// readouts sitting in a sidebar, not alerts.
    static func loadColor(_ cpuPercent: Double) -> SwiftUI.Color {
        switch cpuPercent {
        case ..<25:  return SwiftUI.Color(red: 0.45, green: 0.72, blue: 0.52)
        case ..<100: return SwiftUI.Color(red: 0.85, green: 0.72, blue: 0.40)
        default:     return SwiftUI.Color(red: 0.90, green: 0.50, blue: 0.45)
        }
    }
}
