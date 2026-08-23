import Foundation

/// The subset of preferences a theme is allowed to displace.
///
/// Only the effect settings — not the whole `Preferences` — because anything a
/// person changes while a flat theme is active (font size, density, which
/// buttons show) is theirs and must survive the switch back.
struct EffectsSnapshot: Codable, Equatable {
    var topBar: BarAppearance
    var sidebarBar: BarAppearance
    var inspectorBar: BarAppearance
    var statusBarAppearance: BarAppearance

    var terminalSurface: SurfaceStyle
    var terminalOpacity: Double
    var terminalBlurStrength: BlurStrength

    var backgroundMode: BackgroundMode
    var backgroundTint: Double
    var backgroundImageOpacity: Double
    var backgroundImageBlur: Double
    var blurStrength: BlurStrength
    var panelOpacity: Double

    var cornerRadius: Double
    var panelCornerRadius: Double
    var pillCornerRadius: Double
}

extension Preferences {
    /// What a theme with `disablesEffects` will displace.
    var effectsSnapshot: EffectsSnapshot {
        EffectsSnapshot(
            topBar: topBar, sidebarBar: sidebarBar,
            inspectorBar: inspectorBar, statusBarAppearance: statusBarAppearance,
            terminalSurface: terminalSurface, terminalOpacity: terminalOpacity,
            terminalBlurStrength: terminalBlurStrength,
            backgroundMode: backgroundMode, backgroundTint: backgroundTint,
            backgroundImageOpacity: backgroundImageOpacity,
            backgroundImageBlur: backgroundImageBlur,
            blurStrength: blurStrength, panelOpacity: panelOpacity,
            cornerRadius: cornerRadius, panelCornerRadius: panelCornerRadius,
            pillCornerRadius: pillCornerRadius)
    }

    mutating func restoreEffects(_ snapshot: EffectsSnapshot) {
        topBar = snapshot.topBar
        sidebarBar = snapshot.sidebarBar
        inspectorBar = snapshot.inspectorBar
        statusBarAppearance = snapshot.statusBarAppearance
        terminalSurface = snapshot.terminalSurface
        terminalOpacity = snapshot.terminalOpacity
        terminalBlurStrength = snapshot.terminalBlurStrength
        backgroundMode = snapshot.backgroundMode
        backgroundTint = snapshot.backgroundTint
        backgroundImageOpacity = snapshot.backgroundImageOpacity
        backgroundImageBlur = snapshot.backgroundImageBlur
        blurStrength = snapshot.blurStrength
        panelOpacity = snapshot.panelOpacity
        cornerRadius = snapshot.cornerRadius
        panelCornerRadius = snapshot.panelCornerRadius
        pillCornerRadius = snapshot.pillCornerRadius
    }

    /// Flat, opaque, square. Everything a machine with no compositor could do.
    mutating func applyFlatChrome() {
        for slot in BarSlot.allCases {
            var bar = self[bar: slot]
            bar.style = .solid
            bar.opacity = 1
            bar.blurBehindWindow = false
            bar.shadow = 0
            self[bar: slot] = bar
        }
        terminalSurface = .solid
        terminalOpacity = 1
        // An image or a blurred desktop behind the text is the single most
        // modern-looking thing in the window; the theme's own colour replaces it.
        backgroundMode = .solid
        backgroundTint = 0
        backgroundImageOpacity = 0
        backgroundImageBlur = 0
        panelOpacity = 1
        // Not quite zero: a 2pt radius still reads as square at this size but
        // keeps the corner pixels from looking chewed.
        cornerRadius = 2
        panelCornerRadius = 2
        pillCornerRadius = 2
    }
}
