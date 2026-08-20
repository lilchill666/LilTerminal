import SwiftUI
import AppKit

/// What sits behind the terminal text.
enum BackgroundMode: String, Codable, CaseIterable, Identifiable {
    case solid      // the theme's background colour
    case blur       // the desktop, blurred through the window
    case image      // a picture the user chose
    var id: String { rawValue }

    var label: String {
        switch self {
        case .solid: return "Solid"
        case .blur:  return "Blur"
        case .image: return "Image"
        }
    }

    var help: String {
        switch self {
        case .solid: return "The theme's background colour."
        case .blur:  return "Your desktop, blurred behind the window."
        case .image: return "A picture of your own."
        }
    }
}

/// NSVisualEffectView has no blur-radius knob — its materials are fixed recipes.
/// Exposing them as a strength scale is the honest way to offer "blur level"
/// for the desktop-blur mode; only image backgrounds get a real radius.
enum BlurStrength: String, Codable, CaseIterable, Identifiable {
    case subtle, medium, strong, ultra
    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    var material: NSVisualEffectView.Material {
        switch self {
        case .subtle: return .titlebar
        case .medium: return .sidebar
        case .strong: return .hudWindow
        case .ultra:  return .underWindowBackground
        }
    }
}

/// How the floating panels are drawn.
enum SurfaceStyle: String, Codable, CaseIterable, Identifiable {
    case solid, frosted, liquidGlass
    var id: String { rawValue }

    var label: String {
        switch self {
        case .solid:       return "Solid"
        case .frosted:     return "Frosted"
        case .liquidGlass: return "Liquid Glass"
        }
    }

    /// Liquid Glass is a macOS 26 API; on anything older the option is unusable.
    var isAvailable: Bool {
        guard self == .liquidGlass else { return true }
        if #available(macOS 26.0, *) { return true }
        return false
    }
}

/// Paints whatever sits behind everything else in the window.
struct BackgroundLayer: View {
    @ObservedObject var workspace: Workspace

    private var prefs: Preferences { workspace.prefs }
    private var theme: AppTheme { workspace.themes.active }

    var body: some View {
        Group {
            switch prefs.backgroundMode {
            case .solid:
                theme.windowBase

            case .blur:
                // Behind-window blending is what samples the desktop; the tint
                // on top keeps text legible over an arbitrary wallpaper.
                ZStack {
                    VisualEffect(material: prefs.blurStrength.material,
                                 blending: .behindWindow,
                                 alwaysActive: prefs.topBar.stayActiveWhenUnfocused)
                    HexColor.swiftUI(theme.background).opacity(prefs.backgroundTint)
                }

            case .image:
                ZStack {
                    theme.windowBase
                    if let image = workspace.backgroundImage {
                        // GeometryReader is load-bearing: a resizable Image
                        // propagates its intrinsic size (often thousands of
                        // points) to the enclosing stack, which blows the whole
                        // window layout out and pushes the UI off screen.
                        GeometryReader { geo in
                            let bleed = CGFloat(prefs.backgroundImageBlur) * 3
                            ZStack {
                                Image(nsImage: image)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    // Oversized before blurring so the softened
                                    // edges fall outside the visible area
                                    // instead of fading to transparent.
                                    .frame(width: geo.size.width + bleed,
                                           height: geo.size.height + bleed)
                                    .blur(radius: prefs.backgroundImageBlur, opaque: true)
                            }
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                        }
                        // The GeometryReader is measured before the safe-area
                        // extension, so without this the image stops short of
                        // the window edge and the darker base shows as a band
                        // along the bottom.
                        .ignoresSafeArea()
                        .opacity(prefs.backgroundImageOpacity)
                        .allowsHitTesting(false)
                    }
                    HexColor.swiftUI(theme.background).opacity(prefs.backgroundTint)
                }
            }
        }
        .ignoresSafeArea()
    }
}

extension View {
    /// Paints one bar according to its own settings.
    @ViewBuilder
    func surface(_ appearance: BarAppearance, slot: BarSlot,
                 theme: AppTheme, cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        switch appearance.style {
        case .liquidGlass:
            if #available(macOS 26.0, *) {
                // glassEffect only draws the material in `shape`; it does not
                // clip what it is applied to. Without this the bar's own inner
                // fills — a sidebar footer, an inspector header — run square
                // past the glass and every corner reads as a hard-edged slab.
                self.clipShape(shape)
                    .glassEffect(.regular, in: shape)
                    .barShadow(appearance.shadow)
            } else {
                self.barFrosted(appearance, slot: slot, theme: theme, shape: shape, radius: cornerRadius)
            }
        case .frosted:
            self.barFrosted(appearance, slot: slot, theme: theme, shape: shape, radius: cornerRadius)
        case .solid:
            self
                .background(theme.chrome)
                .clipShape(shape)
                .overlay { shape.strokeBorder(theme.hairline, lineWidth: 0.5) }
                .barShadow(appearance.shadow)
        }
    }

    fileprivate func barFrosted(_ appearance: BarAppearance, slot: BarSlot,
                                theme: AppTheme, shape: RoundedRectangle,
                                radius: CGFloat) -> some View {
        self
            .background {
                ZStack {
                    VisualEffect(material: appearance.blurStrength.material,
                                 blending: appearance.blending,
                                 alwaysActive: appearance.stayActiveWhenUnfocused,
                                 cornerRadius: radius)
                    theme.chrome.opacity(appearance.opacity)
                }
            }
            .clipShape(shape)
            .overlay { shape.strokeBorder(theme.hairline.opacity(0.9), lineWidth: 0.5) }
            .barShadow(appearance.shadow)
    }

    @ViewBuilder
    fileprivate func barShadow(_ strength: Double) -> some View {
        if strength <= 0.001 {
            self
        } else {
            // Small offset and radius: enough to lift the panel, not enough to
            // pool in the gap at the window edge.
            self.shadow(color: .black.opacity(strength), radius: 8, y: 2)
        }
    }

    /// Legacy single-surface entry point, still used by sheets and popovers.
    @ViewBuilder
    func surface(style: SurfaceStyle, theme: AppTheme, opacity: Double,
                 material: NSVisualEffectView.Material, cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        switch style {
        case .liquidGlass:
            if #available(macOS 26.0, *) {
                // Liquid Glass brings its own lensing, shadow, and border, so it
                // gets none of the hand-rolled ones the other styles need — but
                // it still does not clip its content, so that part stays.
                self.clipShape(shape)
                    .glassEffect(.regular, in: shape)
            } else {
                self.frostedSurface(theme: theme, opacity: opacity,
                                    material: material, shape: shape,
                                    radius: cornerRadius)
            }

        case .frosted:
            self.frostedSurface(theme: theme, opacity: opacity,
                                material: material, shape: shape,
                                radius: cornerRadius)

        case .solid:
            self
                .background(theme.chrome)
                .clipShape(shape)
                .overlay { shape.strokeBorder(theme.hairline, lineWidth: 0.5) }
                .shadow(color: .black.opacity(theme.isDark ? 0.34 : 0.14), radius: 12, y: 4)
        }
    }

    fileprivate func frostedSurface(theme: AppTheme, opacity: Double,
                                    material: NSVisualEffectView.Material,
                                    shape: RoundedRectangle,
                                    radius: CGFloat) -> some View {
        self
            .background {
                ZStack {
                    VisualEffect(material: material, blending: .withinWindow,
                                 cornerRadius: radius)
                    theme.chrome.opacity(opacity)
                }
            }
            .clipShape(shape)
            .overlay {
                // A hairline stops the panel dissolving into a background of
                // similar luminance.
                shape.strokeBorder(theme.hairline.opacity(0.9), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(theme.isDark ? 0.34 : 0.14), radius: 12, y: 4)
    }
}
