import SwiftUI
import AppKit

/// How one bar is painted. Each bar carries its own copy so the top bar,
/// sidebar, inspector and status pill can differ.
struct BarAppearance: Codable, Equatable {
    var style: SurfaceStyle = .frosted
    var blurStrength: BlurStrength = .medium
    /// Theme tint laid over the blur. 0 is pure blur, 1 is opaque chrome.
    var opacity: Double = 0.55
    /// Sample the desktop rather than the window.
    ///
    /// This matters more than it sounds: a within-window effect view cannot
    /// sample a behind-window one underneath it, so with a blurred window
    /// background the bars come out flat and dark. Blurring behind the window
    /// instead gives them real depth.
    var blurBehindWindow = false
    /// Drop shadow strength, 0 for none.
    ///
    /// A heavy shadow is invisible over a dark background and reads as a black
    /// bar over a light one — it lands in the gap between the panel and the
    /// window edge, where there is nothing to soften it.
    var shadow: Double = 0.16
    /// Keep the blur alive when the window is not focused. AppKit dims these
    /// views by default, which reads as the app going grey the moment you look
    /// at something else.
    var stayActiveWhenUnfocused = true

    var blending: NSVisualEffectView.BlendingMode {
        blurBehindWindow ? .behindWindow : .withinWindow
    }

    /// Sensible starting point for a bar sitting over a blurred desktop.
    static func overBlurredDesktop() -> BarAppearance {
        BarAppearance(style: .frosted, blurStrength: .medium,
                      opacity: 0.4, blurBehindWindow: true)
    }
}

/// Identifies a bar in the settings UI.
enum BarSlot: String, CaseIterable, Identifiable {
    case top, sidebar, inspector, status
    var id: String { rawValue }

    var label: String {
        switch self {
        case .top:       return "Top"
        case .sidebar:   return "Sidebar"
        case .inspector: return "Inspector"
        case .status:    return "Status"
        }
    }

    var material: NSVisualEffectView.Material {
        switch self {
        case .top:       return .headerView
        case .sidebar:   return .sidebar
        case .inspector: return .sidebar
        case .status:    return .hudWindow
        }
    }
}

extension Preferences {
    subscript(bar slot: BarSlot) -> BarAppearance {
        get {
            switch slot {
            case .top:       return topBar
            case .sidebar:   return sidebarBar
            case .inspector: return inspectorBar
            case .status:    return statusBarAppearance
            }
        }
        set {
            switch slot {
            case .top:       topBar = newValue
            case .sidebar:   sidebarBar = newValue
            case .inspector: inspectorBar = newValue
            case .status:    statusBarAppearance = newValue
            }
        }
    }
}
